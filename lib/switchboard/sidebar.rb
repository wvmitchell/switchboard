# frozen_string_literal: true

require "io/console"
require "set"

module Switchboard
  # The persistent, rendered tree sidebar (no fzf). Lives in a narrow tmux
  # pane, repaints on a short interval to keep agent-activity dots live, and
  # navigates with ↑/↓ (or ^N/^P — j/k are NOT movers, so they're free to type
  # into the filter). ↵ opens a workspace's session (or collapses a project);
  # / filters the tree by name for a direct jump (in-sidebar, not the old fzf
  # popup — see "/ filter mode" below); a adds a project (register a local repo,
  # or clone one); n creates a worktree inline then drops you in; d removes the
  # highlighted row — a workspace's worktree, or a whole project from the
  # registry. The legend tracks the row.
  #
  # One class in several files (#57) — this file is the run-loop core (state,
  # tick/visibility, warm gates, reload orchestration, width pin); the concern
  # files under sidebar/ own the rest and are required at the BOTTOM (see the
  # note there). How a scan flows through them:
  #
  #   stdin ─▶ run ─▶ IO.select ─┬─ bytes ──▶ Input (tokenize → dispatch) ─▶ Actions
  #                              │              (input.rb)          (actions.rb, via
  #                              │                                   Prompt, prompt.rb)
  #                              └─ timeout ─▶ tick ─▶ reload / warm gate (HERE)
  #                                             │
  #        rebuild ─▶ Rows (rows.rb: fold/filter rows + @diffs cache)
  #        refresh_agents ─▶ AgentState.scan ─▶ @edges.on_scan (edges.rb:
  #             │               completion edges ─▶ bold/sound/sparkle/PR-spawn)
  #             └─▶ returned edges ─▶ refresh_diffs
  #        render ─▶ Render (render.rb: frame/columns/glyphs/header/footer) ─▶ pane
  class Sidebar
    REFRESH = 3    # seconds between agent re-scans (while visible)
    IDLE = 8       # seconds between wakes while OFF screen — a backstop only: a
                   # switch-in pokes us awake instantly (C-l), so this just bounds
                   # the lag for the rare un-poked path (bare attach, a tmux server
                   # that hasn't reloaded the new window-switch hook yet, a zoomed
                   # pane). Long enough that a dormant pane costs ~one tmux call/8s,
                   # short enough that an uncovered switch-in still self-heals fast.
    TREE_TICKS = 5 # rebuild the whole tree every Nth tick (~15s) while visible
    PULSE = 0.12   # animation frame cadence while a dot is on screen (drives the spinner/blink)
    VIS_POLL = 2   # while pulsing, re-check visibility this often (s) so a pane that
                   # went off-screen stops fast-spinning within ~VIS_POLL instead of
                   # waiting the full REFRESH — see recheck_visibility.
    POKE_TTL = 2   # min seconds between full reloads a session-switch poke triggers
                   # (rapid switching used to fire a git+capture-pane scan per
                   #  switch — a burst that froze the animation and hammered tmux)
    WARM_TTL = 12  # min seconds between OFF-SCREEN warm reloads (prewarm). Bounds
                   # the cost of a churning off-screen agent (its state file rewrites
                   # every turn would otherwise dirty the warm fingerprint on every
                   # ~IDLE wake). The lost freshness is invisible (you're not looking)
                   # and the switch-in poke catches the residual.

    # Background PR-badge refresh (issue #19): event-driven, never blocks the UI.
    # The debounce/backstop cadences live with the spawn logic in Edges (#57);
    # only the navigation trigger's gate stays here — reload_and_refresh (T2) is
    # the poke handler, and it doesn't move.
    NAV_TTL = 45             # refresh-on-switch only if the cache is older than this

    def self.run
      new.run
    end

    # The / filter match: a case-insensitive subsequence (fzf-style fuzzy) — every
    # character of `query` appears in `text` in order, not necessarily adjacent, so
    # "afb" finds "app-feat-branch". An empty query matches everything, so entering
    # filter mode shows the full switch-target list before you type. Pure, so the
    # match logic is unit-testable without a tree (issue #60).
    def self.fuzzy_match?(text, query)
      text = text.downcase
      i = 0
      query.downcase.each_char do |c|
        return false unless (i = text.index(c, i))

        i += 1
      end
      true
    end

    def initialize
      @config = Config.new
      @config_mtime = config_mtime # config file's mtime at load; refresh_config re-reads on change
      resolve_keymap      # @keymap (key->action) + @bindings (action->key); re-run each rebuild (#108)
      @cursor = 0
      @offset = 0
      @nodes = []          # full tree
      @rows = []           # visible rows (collapsed projects hide their children)
      @visible_rows = []   # the on-screen slice of @rows (set in render; gates pulsing?)
      @agents = {}         # worktree path => :thinking | :done | :waiting
      @attention = Set.new # worktree paths with an unviewed completion (rendered bold)
      @monitoring = Set.new # worktree paths with a live background-monitor marker (∞)
      @pending_delete = Set.new # worktree paths being deleted right now — hidden from the
                           # tree while a detached daemon runs `git worktree remove` off the
                           # input loop (shared PendingDelete marker, hydrated every rebuild)
      @agent_state = AgentState.new
      @collapsed = Set.new # collapsed project names; hydrated from the shared
                           # on-disk store (Collapse) on every rebuild, so all
                           # windows' sidebars fold the same and a respawn keeps it
      @filter = nil        # / filter mode: nil = off, else a (possibly empty) query
                           # string. Pure per-process UI state — not shared on disk
                           # like @collapsed, because a search is a transient act, not
                           # a view preference (issue #60).
      @help = false        # ? help overlay: when set, render paints the full key map
                           # over the tree and the next real keystroke dismisses it
                           # (issue #62). Per-process + transient, like @filter.
      @full_header = false # H: seat the full home-style header on EVERY session.
                           # Hydrated from the shared on-disk store (FullHeader) on
                           # every rebuild, so all windows agree and a respawn keeps it
      @fold_branches = false # z: fold EVERY workspace's branch-history rows tree-wide
                           # (issue #107). A single global flag (BranchFold), hydrated on
                           # every rebuild like @full_header, so all windows fold alike and
                           # a respawn keeps it; off ⇒ branches show, as before #107
      @ticks = 0
      @pulse = 0           # animation frame counter (spinner cycle + blink phase)
      @last_scan = nil     # monotonic time of the last agent re-scan
      @last_reload = nil   # monotonic of the last full reload (throttles switch pokes)
      @last_warm = nil     # monotonic of the last OFF-SCREEN warm reload (throttles by WARM_TTL)
      @warm_fp = nil       # warm_fingerprint at the last reload — the warm change-gate baseline
      @last_vis = nil      # monotonic of the last mid-pulse visibility re-check
      @geom = nil          # winsize at the last successful width-pin (skip no-op pins)
      @width = Width.resolved # pane width in cols; ←/→ step it. Hydrated from the shared
                           # on-disk store (Width) here and on every rebuild, so all
                           # windows size alike and a respawn keeps it. Seeded now (before
                           # the first reload) so run's opening pin matches the spawn -l.
      @resized = false     # a ←/→ press is pending: commit_resize pins + persists ONCE
                           # after the input burst drains, so a held key stays smooth
      @visible = false     # is this pane currently on screen? gates render + pulse;
                           # the single source of truth, mutated only via set_visible
      @pane_tty = nil      # our pane's pty, captured at startup — the durable pane
                           # identity (tmux recycles %ids); owns_pane? exits if it drifts
      @focused = false     # is the sidebar the active pane? (cursor bar only then)
      @current_path = nil # worktree this sidebar's session is in (shown bold)
      @home = false        # is this the persistent home session? (settings base)
      @edges = Edges.new   # the agent-edge fanout (#57): owns the sticky hook-state
                           # baseline, the sparkle deadlines, and the PR-spawn debounce;
                           # fed per scan by refresh_agents (config passed per call,
                           # never captured — reload_config reassigns @config)
      @branch_cache = {}   # worktree path => [gitdir, logs/HEAD mtime, limit, branches],
                           # so a reload skips the per-ws rev-parse when the reflog is
                           # unchanged. Bounded by worktrees seen this process; never pruned.
      @diffs = {}          # [path, branch, kind] => [logs/HEAD mtime, resting?, adds, dels]:
                           # the row's branch-vs-base diff count (issue #79), refreshed off the
                           # paint loop and gated on the worktree's reflog mtime (+ the PR
                           # resting flag, so a merged row recomputes once). Like
                           # @branch_cache, bounded by rows seen this process; never pruned.
      @operator = false    # home greeting's first name; resolved lazily on the first
                           # home render (git shell-out) so non-home sidebars never pay
      @pane_switch_keys = nil # the user's tmux select-pane keys, shown in the ? overlay;
                           # resolved once lazily on first help open (a tmux shell-out),
                           # then memoized so the paint loop never re-queries (issue #62)
      @pending = +""       # an incomplete escape sequence split across reads, carried
                           # to the next one and reassembled by tokenize (see handle) —
                           # so a sequence's final byte is never read alone as a key
    end

    def run
      return warn("no config — run `switchboard init`") unless Config.exist?

      setup
      Tmux.enable_focus_events # so focus in/out reaches us for an instant dim
      @home = Tmux.session_of == Tmux::HOME # stable for this pane's lifetime
      pane = ENV["TMUX_PANE"]
      @pane_tty = Tmux.pane_tty(pane) # capture our pty now — the pane identity owns_pane? guards
      # Sample visibility — don't assume on. A sidebar spawned with split-window -d
      # (after-new-window sync, reconcile into a non-active window) lands OFF screen;
      # warming + painting it then is exactly the off-screen work we're cutting. When
      # it first comes on screen, the switch-in poke or the tick catch-up reloads it.
      set_visible(Tmux.visible?(pane))
      @focused = @visible && Tmux.focused?(pane)
      if @visible
        pin_if_resized # pins + seeds @geom so the first tick won't re-pin
        render # clear + show the pane instantly (empty)
        reload # rebuild + agents + locate "you are here"
        cursor_to_current # a freshly summoned sidebar starts on the workspace it's in
      end
      reconcile_on_launch if @home && @config.prune_on_launch?
      @last_scan = monotonic
      loop do
        render if @visible # never paint a hidden pane
        # Wake often enough to animate the spinner/blink, but only while a dot is
        # on screen; otherwise sit on the slow REFRESH/IDLE interval. State scans
        # stay gated to REFRESH (scan_due?) so the fast frames don't hammer tmux.
        if IO.select([$stdin], nil, nil, frame_timeout)
          key = read_key
          break if key == :eof # our pane's pty hit EOF (closed) — exit, don't spin as an orphan
          break unless handle(key)
          commit_resize if @resized # ←/→ pinned + persisted ONCE per burst, post-drain
        else
          @pulse += 1
          # While pulsing we wake ~8x/s; re-check visibility a little faster than a
          # full scan so a pane that just went off-screen stops fast-spinning (and
          # painting) promptly, rather than after the next REFRESH tick.
          recheck_visibility if pulsing? && vis_poll_due?
          break if scan_due? && !tick # tick returns false once we no longer own our pane
        end
      end
    ensure
      teardown
    end

    def frame_timeout
      return PULSE if pulsing?

      @visible ? REFRESH : IDLE # off screen: sleep long, a poke wakes us instantly
    end

    # A thinking/waiting dot is actually on screen and worth animating. Gated on
    # @visible (off screen never animates) AND the rendered slice (not all @agents)
    # so a collapsed or scrolled-off agent never drives repaints; :done is steady
    # and never pulses — except for the brief twinkle right after it lands (sparkling?).
    def pulsing?
      return false unless @visible
      return false if @help # the static overlay has no animation — don't ride the PULSE cadence (#62)

      @visible_rows.any? { |n| %i[thinking waiting].include?(@agents[n.path]) || sparkling?(n.path) }
    end

    # Is `path` mid-twinkle? The edge collaborator owns the sparkle deadlines
    # (#57); this thin delegator is the seam pulsing? and both render paths read
    # through — the glyph choice (@pulse-indexed) stays render-side.
    def sparkling?(path)
      @edges.sparkling?(path)
    end

    # Pure: has `window` seconds elapsed since `last` (nil = never)? The shared
    # comparison behind the scan / reload / visibility throttles. (Edges.spawn_due?
    # is the same idea with an explicit `now`, kept separate so it stays unit-testable.)
    def elapsed?(last, window)
      last.nil? || monotonic - last >= window
    end

    # True at most once per REFRESH seconds — throttles the actual agent scan
    # even when the loop is spinning fast to drive the pulse. Stamps on a hit.
    def scan_due?
      return false unless elapsed?(@last_scan, REFRESH)

      @last_scan = monotonic
      true
    end

    # True at most once per VIS_POLL seconds — throttles the mid-pulse visibility
    # re-check so the fast frames don't fire a tmux call every 0.12s. Stamps on a hit.
    def vis_poll_due?
      return false unless elapsed?(@last_vis, VIS_POLL)

      @last_vis = monotonic
      true
    end

    # The single mutator for "am I on screen?" — every transition routes through
    # here so no caller can forget it and strand a frozen spinner or a blank paint.
    # Plain writer by design: the off->on CATCH-UP reload lives in tick (the poll
    # path) and in reload_and_refresh (the poke path), each of which already knows
    # whether it has reloaded — so set_visible never reloads and can't double-fire.
    def set_visible(on)
      @visible = on
    end

    # Mid-pulse visibility re-check (loop, while pulsing only): one tmux call/VIS_POLL
    # so a pane that went off-screen flips @visible false within ~VIS_POLL — which
    # makes pulsing? false (fast frames stop) and gates render off (no more painting
    # a hidden pane), instead of waiting the full REFRESH for the next tick to notice.
    def recheck_visibility
      set_visible(Tmux.visible?(ENV["TMUX_PANE"]))
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Idle tick. When this sidebar comes back on screen (off -> on, i.e. you
    # navigated back) refresh the tree. While it stays on screen, keep agent dots
    # live and rebuild every TREE_TICKS. Off screen: nothing but the visibility
    # sample (one tmux call) — no focused? call, no scan, no paint. Returns false
    # to ask the loop to exit (we no longer own our pane), true otherwise.
    def tick
      return false unless owns_pane? # disowned -> stop ticking; the loop exits us
      return false if lone_pane_handled # #64: work sibling died -> don't wedge (workspace exits, home self-heals)

      visible = Tmux.visible?(ENV["TMUX_PANE"])
      # Off screen we're never focused, so skip the focused? shell-out entirely —
      # that's half the per-tick tmux cost of a dormant pane.
      @focused = visible && Tmux.focused?(ENV["TMUX_PANE"]) # authoritative if focus-events are off
      reappeared = visible && !@visible
      set_visible(visible)
      if reappeared
        # Catch-up: off-screen -> on-screen via an UN-poked path (a same-session
        # window switch the poke hooks don't cover). Re-baseline SILENTLY:
        # completions that landed while we slept were already rung by whichever
        # sidebar was on screen then, so replaying them is the duplicate-sound bug.
        # A poke switch-in never reaches here — it already set @visible=true in
        # reload_and_refresh, so `reappeared` is false and we don't reload twice.
        reload(announce_sounds: false)
      elsif visible
        pin_if_resized
        @ticks += 1
        if @ticks >= TREE_TICKS
          @ticks = 0
          reload
        else
          refresh_agents
        end
      elsif @config.prewarm? && elapsed?(@last_warm, WARM_TTL) && (fp = warm_fingerprint) != @warm_fp
        # Off screen and something we draw changed: keep this hidden pane's buffer
        # warm (warm_reload + render) so a later switch-in shows fresh content with
        # no flash. Gates are cheapest-first — prewarm? (config), then WARM_TTL
        # (a monotonic compare), then warm_fingerprint (disk stats) — so a fully
        # idle pane still costs ~one Tmux.visible? call per IDLE wake (today's
        # dormancy). warm_reload is the visibility-safe path (no locate, no
        # @last_reload stamp, no PR-spawn, hooks-only); see its comment. Pass the
        # fingerprint we measured HERE so the gate baseline can't outrun the scan
        # (a change landing between the scan and a fresh stamp would otherwise stick
        # the dot stale). Repaint only when warm_reload refreshed cleanly.
        render if warm_reload(fp)
      end
      true
    end

    # True while this process still owns its tmux pane. tmux gives each pane a stable
    # pty for its whole life but RECYCLES %ids, so when a pane is closed our
    # ENV["TMUX_PANE"] can later name a brand-new pane owned by another sidebar.
    # Left running, such an orphan would read THAT pane's visibility and ring its
    # completion sounds in parallel with the real owner — the duplicate-sound bug.
    # The pty captured at startup is the durable identity, and we disown ONLY on a
    # CONFIRMED recycle: a non-empty tty that differs from ours. A nil reply is NOT
    # proof — it means the pane is gone OR a `display-message` transiently failed
    # (EINTR, busy server), indistinguishable here — so we keep running rather than
    # self-terminate a healthy sidebar on a flaky shell-out (every other tmux call
    # in this file degrades, not acts, on a transient miss). A genuinely dead pane
    # reads visible?=false (so it's silent, never rings) and gets reaped the instant
    # its id is recycled onto a live pane — exactly when it could turn harmful. No
    # startup tty (run outside tmux / in tests) ⇒ never self-exit.
    def owns_pane?
      return true unless @pane_tty

      now = Tmux.pane_tty(ENV["TMUX_PANE"])
      now.nil? || now == @pane_tty
    end

    # #64: a window is work-pane + sidebar (a split). Close the work pane and the
    # sidebar is the SOLE pane — tmux forces it full-width and it stays open, wedging
    # the window. Neither existing exit path covers "alive but my sibling died" (:eof is
    # our OWN pty; owns_pane? is a recycled %id). On a CONFIRMED lone pane: from a
    # workspace, fall home (go_home — consistent with the delete/remove flows) and ask
    # the loop to EXIT so the wedged window closes; from HOME, self-heal in place (spawn
    # a fresh work shell) and KEEP running, since exiting would kill the anchor and a
    # full-width home sidebar messes up the UI. Acts ONLY on a confirmed count of 1 — a
    # nil/!=1 reply keeps us running (the file's degrade-never-self-terminate-on-a-flaky-
    # shell-out house rule, like owns_pane?). Returns true when it asked the loop to exit.
    # Polled by tick (backstop, within REFRESH) and run on focus-in for a within-a-frame reap.
    def lone_pane_handled
      return false unless Tmux.window_panes(ENV["TMUX_PANE"]) == 1 # confirmed sole pane (rare; the common path stops here)

      if @home
        # Self-heal THIS window in place: split a fresh work shell beside OUR pane (NOT the
        # session's active window — a lone home sidebar can be in an inactive window, which
        # ensure_work_pane(HOME) would heal wrong / loop on). Non-disruptive (no client
        # switch), so it's safe to run off-screen too.
        Tmux.ensure_work_pane(ENV["TMUX_PANE"])
        false # keep running — the anchor survives
      elsif Tmux.visible?(ENV["TMUX_PANE"])
        # Only the ON-SCREEN workspace sidebar falls home: go_home switch-clients the whole
        # client, so doing it from an off-screen pane would yank you off the window you're
        # actually working in. Sampled live (not @visible, which is stale here in tick).
        Tmux.go_home # land on the navigator (go_home guarantees home has a work pane)
        true         # -> tick/dispatch exits the loop -> our pane closes -> the wedged window closes
      else
        false # off-screen lone workspace sidebar: leave it; focus-in reaps it when you return
      end
    end

    private

    def pin_width
      Tmux.pin(ENV["TMUX_PANE"], @width)
    end

    # ←/→ step the pane width (issue #78). Flag-only, no I/O: handle drains a whole
    # read burst (a held key autorepeats), calling this per token, and run commits
    # ONCE afterward — one resize-pane + one disk write for the burst, so holding the
    # key resizes smoothly instead of flooding subprocesses. A press at a bound is a
    # silent no-op (the held key just rests there).
    def resize(delta)
      new = (@width + delta).clamp(Width::MIN, Width::MAX)
      return if new == @width

      @width = new
      @resized = true
    end

    # Apply a pending ←/→ resize: persist the chosen width (shared on disk) and pin
    # the pane to it. Coalesced — called once per input burst from run, not per key.
    # Nil @geom so the next pin_if_resized re-pins: a no-op if this direct pin took,
    # but a retry if tmux refused it (e.g. the width didn't fit) — without it a failed
    # pin would short-circuit forever on the unchanged geometry. render reflows to the
    # new winsize next iteration.
    def commit_resize
      Width.set(@width)
      pin_width
      @geom = nil
      @resized = false
    end

    # Re-assert the fixed width only when the pane geometry actually changed. tmux
    # reflows panes on a client resize; absent one the width is stable and the
    # per-tick resize-pane was a pure no-op subprocess. winsize is a local ioctl
    # (no subprocess), so gating on it is free. Cache the POST-pin size, and only on
    # success: a failed pin (or one tmux can't satisfy) must NOT poison the cache,
    # or we'd record the drifted size and never retry.
    def pin_if_resized
      return if winsize == @geom

      @geom = winsize if pin_width
    end

    # refresh_prs/hooks_only default to the full behavior; only the off-screen warm
    # path (warm_reload) passes them false/true to stay quiet (no PR-spawn fan-out)
    # and cheap (hooks-only scan, skipping the tmux/pgrep/lsof activity fallback).
    # Returns true on a clean scan, false if it rescued — the warm path uses that to
    # decide whether to advance its change-gate baseline (a failed scan must NOT, or
    # the gate would suppress every retry and the dot would stick stale). Other
    # callers ignore the return.
    def refresh_agents(announce_sounds: true, refresh_prs: true, hooks_only: false)
      ws_paths = @nodes.select { |n| n.kind == "ws" }.map(&:path)
      @agents = @agent_state.scan(ws_paths, hooks_only: hooks_only)
      @monitoring = Monitoring.monitored(ws_paths)     # BEFORE on_scan: gates the :done suppression
      notify_pending = Notify.pending(ws_paths)        # declared "come look" alerts (mtime per path)
      # T1: the edge fanout (marks, sounds, sparkles, PR spawns) lives in Edges;
      # it returns the edge list so the diff-count refresh can ride the same edge.
      edges = @edges.on_scan(@agent_state.last_hook_states,
                             monitoring: @monitoring, nodes: @nodes, config: @config,
                             current_path: @current_path, notify_pending: notify_pending,
                             announce_sounds: announce_sounds, refresh_prs: refresh_prs)
      refresh_diffs if edges.any? # a finished turn likely just committed — repaint its count
      @attention = Attention.marked(ws_paths)          # load for render, after the marks land
      true
    rescue StandardError
      @agents = {}
      false
    end

    # announce_sounds: false on a catch-up scan (a sidebar waking from off-screen,
    # or the session-switch poke) — re-baseline + refresh PRs without ringing for
    # completions another sidebar already announced. Defaults true: continuous
    # while-visible scans ring as they always have.
    # hooks_only: true skips the tmux/pgrep/lsof process fallback in the agent scan —
    # passed by the post-delete reload (a delete doesn't need the coarse fallback to
    # refine other workspaces' dots; they refresh on the next tick). Defaults false so
    # every other caller is unchanged.
    def reload(announce_sounds: true, hooks_only: false)
      rebuild
      locate # before refresh_agents: marks below skip the workspace you're in, and viewing it clears its bold
      # Capture the warm-gate fingerprint BEFORE the scan, so @warm_fp can never
      # outrun what this reload actually rendered (the same stale-stuck race
      # warm_reload guards against): a change landing mid-reload leaves fp behind, so
      # the next off-screen warm re-fires instead of suppressing forever.
      fp = warm_fingerprint
      refresh_agents(announce_sounds: announce_sounds, hooks_only: hooks_only)
      refresh_diffs # branch-vs-base counts, gated on each worktree's reflog mtime
      @edges.refresh_stale_prs(@config) # T3 idle backstop (the cadence lives with the spawn logic)
      # Stamp BOTH clocks: @last_reload throttles the next switch poke (reload_due?),
      # and @last_scan stops the next loop timeout from firing a redundant agent scan
      # right after this reload already scanned — the poke path runs outside scan_due?.
      @last_reload = @last_scan = monotonic
      # Re-baseline the off-screen warm gate (see fp above). Stamped only on a full
      # reload — a visible refresh_agents doesn't, so the first warm after a visible
      # spell may fire one spurious extra time. Harmless: it re-paints a correct buffer.
      @warm_fp = fp
    end

    # A cheap "has anything the pane draws changed?" signal for the off-screen warm
    # gate — stats only, no git/process shell-outs. Covers the dynamic content:
    # agent dots (state-dir file mtimes), bold (attention markers), diff counts
    # (each tracked worktree's logs/HEAD mtime), PR badges (the PR cache), and the
    # project registry (config mtime — a project added/removed in ANOTHER session,
    # so its off-screen panes pre-warm the new tree instead of flashing it on the
    # next switch-in; rebuild's refresh_config is what actually re-reads it).
    # Deliberately NOT covered (they refresh on the switch-in reload, as before):
    # a WORKTREE added/removed in another session, and shared view-state
    # (collapse/full-header/branch-fold/width). Fully rescued — a stat fault yields
    # a value that just triggers one harmless warm, never crashes the loop.
    def warm_fingerprint
      reflogs = @branch_cache.values.filter_map do |gitdir,|
        head = File.join(gitdir.to_s, "logs", "HEAD")
        [head, File.mtime(head).to_f] if gitdir && File.exist?(head)
      end
      [dir_fingerprint(AgentState.state_dir),  # agent dots
       dir_fingerprint(Attention.state_dir),   # bold markers
       dir_fingerprint(Monitoring.state_dir),  # background-monitor ∞ markers
       dir_fingerprint(PendingDelete.state_dir), # being-deleted row-hides (so off-screen panes hide too)
       dir_fingerprint(Pr.cache_dir),          # PR badges
       dir_fingerprint(Collapse.state_dir),    # shared project folds (the originally-missed case)
       file_fingerprint(FullHeader.marker),    # full-header toggle
       file_fingerprint(BranchFold.marker),    # branch-fold toggle
       file_fingerprint(Width.state_file),     # sidebar width
       file_fingerprint(Config.path),          # project registry (add/remove project elsewhere)
       reflogs.sort]                           # diff counts (commits)
    rescue StandardError
      nil
    end

    # mtime of a single shared-state marker file (nil if absent) — captures both a
    # toggle-on (file appears) and toggle-off (file removed) of an existence-flag
    # store, and a value change of the width file.
    def file_fingerprint(path)
      File.mtime(path).to_f
    rescue SystemCallError
      nil
    end

    # Each entry in `dir` as [name, mtime], sorted — a cheap directory change
    # signal (a file added, rewritten in place, or removed all change it). Stats
    # only; the per-file rescue tolerates a file vanishing between glob and stat.
    def dir_fingerprint(dir)
      Dir.glob(File.join(dir, "*")).sort.filter_map do |f|
        [File.basename(f), File.mtime(f).to_f]
      rescue SystemCallError
        nil
      end
    end

    # Off-screen warm reload (prewarm): paint this hidden pane's buffer with EXACTLY
    # the frame a switch-in would produce, so arriving shows no flash. It must match
    # `reload`'s output, which is why it calls `locate` — the warm frame has to carry
    # the » "you are here" marker, or every switch-in would add it and flash (the bug
    # this fixes). locate's attention-CLEAR is gated on @visible, so calling it off
    # screen sets @current_path (for the marker) without erasing bold you haven't seen.
    # Still deliberately NOT plain `reload`:
    #   - stamps @last_warm, never @last_reload — so the switch-in reload_and_refresh
    #     still passes reload_due? and runs its full reload + PR refresh.
    #   - refresh_prs:false — no off-screen PR-spawn fan-out (N sidebars, one each).
    #   - hooks_only:true — skip the tmux/pgrep/lsof activity scan; stay cheap.
    #   - announce_sounds:false — never ring off screen.
    # The edge fanout (Edges#on_scan) still runs (marks + baseline advance), just
    # without the spawn.
    # `fp` is the fingerprint the caller measured BEFORE this scan (the value that
    # tripped the gate). Stamping it — not a fresh one taken after the scan — keeps
    # @warm_fp from ever outrunning what the scan actually saw: a state change that
    # lands between the scan and the stamp leaves fp behind the new reality, so the
    # next tick re-warms (converges) instead of marking the gate satisfied for a dot
    # the render missed (the stale-stuck race). Returns true when it refreshed
    # cleanly (caller repaints + baseline advances); false when the scan rescued, so
    # the next off-screen tick retries rather than sticking a stale buffer.
    def warm_reload(fp)
      rebuild
      locate # so the warm frame carries the » marker and matches the switch-in frame
      ok = refresh_agents(announce_sounds: false, refresh_prs: false, hooks_only: true)
      refresh_diffs
      return false unless ok # leave @last_warm + @warm_fp stale so the next tick retries promptly

      @last_warm = monotonic
      @warm_fp = fp
      true
    end

    # C-w broadcast handler: a peer sidebar changed shared view-state (collapse /
    # branch-fold / full-header) and pinged us to repaint NOW, so a switch right
    # after the toggle shows it with no flash — instead of us lagging until our next
    # warm tick. On screen: a silent reload + render shows it immediately. Off
    # screen: warm_reload paints the new view-state into the buffer (gated on
    # prewarm? — a user who opted out of off-screen work gets none). Either way it's
    # cheap and event-driven (fires only on the rare toggle, not on a poll), so it
    # keeps the off-screen dormancy.
    def warm_poke
      if @visible
        reload(announce_sounds: false)
        render
      elsif @config.prewarm?
        render if warm_reload(warm_fingerprint)
      end
    end

    # May a session-switch poke run a full (git + capture-pane) reload now? Only
    # if we haven't within POKE_TTL — so resuming several sessions at once
    # coalesces into one rescan instead of a per-switch shell-out storm. Any
    # reload (run/tick/poke) stamps @last_reload, so a poke right after a tick
    # rebuild is suppressed too.
    def reload_due?
      elapsed?(@last_reload, POKE_TTL)
    end

    # Once, when the HOME sidebar starts (the relaunch anchor): prune orphaned
    # sb/ sessions a deleted/moved/crashed worktree left behind, so they don't
    # silently survive a relaunch. Home is always valid, so this can't kill our
    # own pane; orphans don't affect the git-built tree, so no re-render needed.
    # Best-effort and silent — we're mid-render, and a tmux/git hiccup must never
    # stop the sidebar from drawing.
    def reconcile_on_launch
      Reconcile.prune(@config)
    rescue StandardError
      nil
    end

    # Which workspace is this sidebar's session in? Matched by the sidebar's
    # working directory, so it covers any session in a worktree (switchboard,
    # emdash, conductor). Marked with the » pointer + a cyan name (CURRENT_MARK);
    # independent of the navigation cursor.
    def locate
      here = Tmux.pane_path(ENV["TMUX_PANE"])
      @current_path = here && @nodes.select { |n| n.kind == "ws" }
                                    .map(&:path)
                                    .select { |p| here == p || here.start_with?("#{p}/") }
                                    .max_by(&:length)
      return unless @current_path
      # Clearing bold means "I'm viewing this" — only true when on screen. The
      # off-screen warm path calls locate too (so the warm frame carries the »
      # current-workspace marker and matches the switch-in frame — no flash), but it
      # must NOT clear bold for a completion you haven't actually seen yet. Setting
      # @current_path above is always safe; the clear is the viewing side effect.
      return unless @visible

      # Viewing a workspace clears its bold — even with no input submitted. Drop it
      # from the in-memory set too, so the un-bold shows this frame, not next scan.
      Attention.clear(@current_path)
      @attention.delete(@current_path)
    end

    # Land the selection bar on the workspace this session is in, so summoning or
    # refocusing the sidebar starts on "here" rather than wherever the cursor last
    # sat. Edge-triggered (focus-in / first paint), NOT on every reload — running
    # it in locate would yank the cursor back every TREE_TICKS while you navigate.
    # No-op at home (@current_path nil) or when the row is hidden (collapsed
    # project) / absent, leaving the cursor untouched rather than jumping it away.
    def cursor_to_current
      return unless @current_path

      i = @rows.index { |n| n.kind == "ws" && n.path == @current_path }
      @cursor = i if i
    end

    def current
      @rows[@cursor]
    end

    # --- PR badge refresh (issue #19) ----------------------------------------
    #
    # Badges are cached on disk and read instantly; the triggers keep that cache
    # fresh in the background, never blocking the paint loop. All of them funnel
    # into Edges#maybe_refresh_prs, which debounces per project then detaches a
    # `switchboard refresh` child that rewrites the cache and pokes us to redraw.
    # Post-#57 only T2 lives HERE: T1 (the edge fanout) and T3 (the idle
    # backstop) are in Edges (sidebar/edges.rb); T4 (R) is in Actions
    # (sidebar/actions.rb).

    # T2 — the session-change poke (\f). "You are here" stays correct on every
    # switch (cheap locate), but the heavy git+agent rescan is throttled: rapid
    # switching — resuming several sessions at once — used to fire a full reload
    # per switch, a burst of git/capture-pane shell-outs that froze the animation
    # and pounded the tmux server. The throttled switches just relocate; the next
    # tick (<= REFRESH) brings the tree current. PR refresh only when reloaded and
    # the cache is older than NAV_TTL, catching changes no local agent made.
    def reload_and_refresh
      # C-l is overloaded: the session-switch hook pokes us (we're now ON screen),
      # but a background PR-refresh child also pokes its explicit pane — which may be
      # OFF screen, since that poke is built to survive us navigating away. So SAMPLE
      # visibility; don't assume the poke means visible, or we'd re-wake a hidden pane
      # (paint + reload) and reintroduce the off-screen work this change removes.
      set_visible(Tmux.visible?(ENV["TMUX_PANE"]))
      return locate unless @visible    # hidden background poke: badges are cached, nothing to paint
      return locate unless reload_due? # coalesce a rapid switch storm into one heavy reload

      # Marking @visible=true above also consumes the off->on edge: the next tick sees
      # @visible already true, so its catch-up branch won't reload a second time.
      # A switch-in is a catch-up: ring nothing for completions that finished before we
      # arrived (the next genuine completion, scanned while we're here, still rings).
      reload(announce_sounds: false)
      project = @current_path && project_for_path(@current_path)
      maybe_refresh_prs(project) if project && Pr.stale?(project, NAV_TTL)
    end

    # The debounced background-refresh spawn lives in Edges; this thin delegator
    # is the deliberate seam (#57) for the SIDEBAR-side triggers: T2
    # (reload_and_refresh above) and T4 (refresh_prs_now, actions.rb) route
    # here, so a test stub on the sidebar intercepts those two. T1/T3 spawn
    # inside Edges itself (refresh_prs_for / refresh_stale_prs) — stub the
    # Edges instance to intercept them.
    def maybe_refresh_prs(project)
      @edges.maybe_refresh_prs(project)
    end

    # The project owning a worktree path (over the ws nodes), or nil. Edges
    # keeps its own private param-threaded twin — change the matching rule in
    # both or they drift.
    def project_for_path(path)
      @nodes.find { |n| n.kind == "ws" && n.path == path }&.project
    end

    # --- terminal session lifecycle (the render paths live in Render, #57) ---

    def setup
      $stdin.raw!
      # ?1004h opts this pane into focus reporting — without it tmux won't send
      # the focus in/out escapes (\e[I / \e[O) we use to dim instantly.
      print "\e[?25l\e[?1004h\e[2J" # hide cursor, request focus events, clear
    end

    def teardown
      $stdin.cooked!
      print "\e[?1004l\e[?25h" # stop focus events, show cursor
    rescue StandardError
      nil
    end

  end
end

# The sidebar's concern files (#57), required at the BOTTOM on purpose: a
# require here can never evaluate a part's constant initializer against a core
# constant that doesn't exist yet (the rule that keeps the split safe: a file's
# constant initializers only reference same-file constants). Each part reopens
# class Sidebar.
require_relative "sidebar/edges"
require_relative "sidebar/render"
require_relative "sidebar/input"
require_relative "sidebar/actions"
require_relative "sidebar/prompt"
require_relative "sidebar/rows"
