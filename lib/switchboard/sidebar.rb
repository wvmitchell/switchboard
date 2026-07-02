# frozen_string_literal: true

require "io/console"
require "set"
require "shellwords"

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
    PR_DEBOUNCE = 5          # min seconds between background refreshes per project
    NAV_TTL = 45             # refresh-on-switch only if the cache is older than this
    BACKSTOP_TTL = 120       # idle fallback: refresh a project staler than this. Kept
                             # short (2 min) because a PR merged/closed *on GitHub* fires
                             # no local trigger — this backstop, riding the ~15s visible
                             # reloads, is what eventually catches it (R forces it now).
    MAX_SPAWN_PER_RELOAD = 3 # cap backstop spawns per reload (cold-home fan-out)

    # Agent-state icons. Idle (no agent) draws a blank slot, so the column only
    # lights up when something's there. Motion lives in the GLYPH (the spinner
    # cycles, the diamond blinks) — driven by @pulse on the PULSE repaint — so
    # each state needs only a single palette ANSI color that follows the
    # terminal's light/dark theme for free. No 256-color ramp, no bg detection.
    #
    # Two forms per animated state: a bare glyph (`glyph_for`, used on the
    # reverse-video selected row where color is stripped but shape survives) and
    # a pre-built colored string (`dot_for`, normal rows — built once, no
    # per-frame allocation). Thinking cycles a braille spinner; waiting blinks a
    # filled/hollow diamond; done is a steady dot.
    SPIN_FRAMES  = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze              # thinking: bare spinner glyphs
    SPIN_COLORED = SPIN_FRAMES.map { |g| "\e[1;34m#{g}\e[0m" }.freeze # ...pre-built in blue
    WANTS_ON  = "\e[1;35m◆\e[0m"  # input needed: magenta diamond, lit
    WANTS_OFF = "\e[1;35m◇\e[0m"  # ...and hollow, the blink's off-beat
    DONE      = "\e[1;32m●\e[0m"  # green: replied, ready for you (not blocked)
    BLINK_PERIOD = 4             # @pulse ticks per blink half-cycle (~0.5s at PULSE)

    # Completion twinkle — the visual twin of the sound: a brief ✦/✧ shimmer when a
    # hooked agent's turn lands (:done), settling to the steady DONE dot. Bright
    # green so it reads a touch louder than DONE for the moment it lasts. Two forms,
    # like the spinner: a bare glyph for the reverse-video selected row (shape
    # survives, color is stripped) and a pre-built colored string for normal rows.
    SPARKLE_GLYPHS  = %w[✦ ✧].freeze
    SPARKLE_COLORED = SPARKLE_GLYPHS.map { |g| "\e[1;92m#{g}\e[0m" }.freeze
    SPARKLE_SECS    = 3.0        # wall-clock lifetime of a twinkle before it settles to DONE

    # The "you are here" pointer: marks the session's current workspace with SHAPE,
    # not just the cyan name, so it reads without relying on color. One column,
    # dropped into the otherwise-blank ws gutter, so the 4-col prefix — and name
    # alignment, and the badge math off it — is unchanged; blank on every other row.
    CURRENT_MARK = "»"

    BRANCH_FG = "\e[90m"         # branch rows: bright-black, a theme-relative dim (#23)
    RELOAD_CONFIG_BYTE = "\x12"  # C-r: the dedicated post-edit "re-read config" poke (Tmux.poke_sidebar_of)
    WARM_POKE_BYTE = "\x17"      # C-w: "shared view-state changed elsewhere — repaint NOW" broadcast
                                 # (Tmux.broadcast_warm). Lets a collapse/fold/header toggle in one
                                 # sidebar reach every other (off-screen) sidebar's buffer instantly,
                                 # instead of waiting for its lazy warm tick — so a switch right after
                                 # a toggle shows the new view-state with no flash.
    WIDTH_STEP = 2               # cols per ←/→ press; bounds live in Width (issue #78)
    READ_BYTES = 1024            # per read: large enough that a normal input burst (a held
                                 # key-repeat, a switch's focus-event flurry) is never capped
                                 # mid-sequence — so the tokenizer only ever carries a genuine
                                 # producer-fragmented tail, not one we sliced ourselves
    CSI_MAX = 32                 # longest partial CSI tokenize will carry across reads; real
                                 # CSIs are short, so a longer param run is garbage — drop it
                                 # rather than let @pending grow unbounded on a junk byte stream
    MIN_NAME_COLS = 3            # below this many cols left for the name, drop the diff
                                 # badge so a row never overruns the pane (issue #79)

    # Key-hint legend, built by `footer` (below) and kept within the pin width.
    # Reload isn't shown — it's automatic; Ctrl-L triggers it internally (the
    # session-switch hook poke). The first line is the session label: in the home
    # session it's the "you are at the base" title (HOME_TITLE), otherwise the
    # navigation keys, which differ by row kind (a project opens/collapses).
    HOME_TITLE = "switchboard · home"
    # The home sidebar's brand header (crafted, home-only — see `header`). The
    # wordmark gives the name presence beyond the footer; the ◖═◗ motif reads as a
    # patch cable plugged between two jacks — the telephone switchboard the tool is
    # named for. Bold cyan is switchboard's signature accent (the "you are here" hue).
    BRAND    = "\e[1;36m"
    WORDMARK = "◖═◗ Switchboard"

    NAV_PROJ   = "↑↓ move · ↵ open/collapse"
    NAV_WS     = "↑↓ move · ↵ open"
    # No NAV_BR: a branch row's ↵ opens its workspace's session — the SAME session
    # as the ws row (one session per worktree, keyed on path not branch), never a
    # branch checkout (swapping branches under a working agent is a footgun). So it
    # shares NAV_WS's honest "open"; a "switch" label would imply a checkout it
    # never does — and shouldn't.

    # The `?` overlay's key map is built at render time from the resolved bindings
    # (Keymap.help_rows, issue #108) so the shown keys can never drift from what
    # dispatch honors — [key, description] rows, a blank key marking a section
    # heading. Top-loaded with navigation, so a short pane drops the tail, not the
    # top. The tmux-layer keys that operate the sidebar (prefix-toggle/home) are
    # appended from config (tmux_help_rows), resolved, not static.
    HELP_KEY_COLS = 6 # key column width; longer combos (move/prefix rows) overflow it

    # Synthetic byte sequences that arrive on stdin without a keypress — the C-l
    # switch/background-refresh poke, the C-r config poke, and tmux focus in/out.
    # While the ? overlay is open these are IGNORED (a background poke must not dismiss
    # it); every other byte is a real keystroke that closes it. Dropping their side
    # effects is safe here: C-l's reload/visibility self-heals via the tick backstop
    # within REFRESH (tick runs while help is open); C-r can't coincide with help (you
    # can't open the editor while help is up — `e` dismisses it first — and C-r isn't
    # broadcast, it targets the just-focused pane); focus is cosmetic under the overlay.
    # If C-r ever becomes broadcast, revisit this (it'd then need honoring). (issue #62)
    HELP_IGNORED_BYTES = ["\f", RELOAD_CONFIG_BYTE, WARM_POKE_BYTE, "\e[I", "\e[O"].freeze

    def self.run
      new.run
    end

    # Paths whose agent state newly entered a resting state (:done/:waiting) since
    # the previous scan — i.e. a hooked agent just finished a turn. A path we've
    # never seen before (prev has no key for it) is the agent *announcing
    # presence*, not completing: SessionStart reports :done the instant a
    # freshly-created workspace's Claude is ready, and that must NOT ring the
    # completion sound (or spawn a PR refresh for a branch that has no PR yet). So
    # a first appearance only seeds the baseline; the next real Stop is the edge.
    # The caller keeps `prev` sticky across scans (on_agent_edges merges), so
    # "first appearance" means truly never-seen this process — a worktree that
    # merely aged out of the live scan keeps its baseline and still fires on
    # completion. Steady resting states and transitions back to :thinking don't
    # count either. Pure, so the edge logic is unit-testable. (Drives the sound +
    # PR-refresh triggers; issue #19.)
    def self.completion_edges(prev, now)
      now.keys.select do |path|
        %i[done waiting].include?(now[path]) && prev.key?(path) && prev[path] != now[path]
      end
    end

    # Debounce predicate: may we spawn a refresh for this project now? Yes if we
    # never have, or the last spawn is at least `window` seconds old. Pure so the
    # window logic is unit-testable without launching a process.
    def self.spawn_due?(last, now, window = PR_DEBOUNCE)
      last.nil? || now - last >= window
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
      resolve_keymap      # @keymap (key->action) + @bindings (action->key); re-run each rebuild (#108)
      @cursor = 0
      @offset = 0
      @nodes = []          # full tree
      @rows = []           # visible rows (collapsed projects hide their children)
      @visible_rows = []   # the on-screen slice of @rows (set in render; gates pulsing?)
      @agents = {}         # worktree path => :thinking | :done | :waiting
      @attention = Set.new # worktree paths with an unviewed completion (rendered bold)
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
      @sparkles = {}       # worktree path => @pulse deadline of an active completion
                           # twinkle; pulsing? keeps animating until it lapses (sparkling?)
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
      @pr_spawned = {}     # project => monotonic of its last background PR refresh
      @prev_hook_states = nil # last scan's hook states; nil until the first scan
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

    # Is `path` mid-twinkle? Deadlines are wall-clock (monotonic), NOT @pulse units —
    # @pulse only crawls while a pane is off-screen, so a pulse-denominated deadline
    # would survive ~48s hidden and replay the twinkle on switch-back. Once passed,
    # drop the entry so @sparkles stays bounded and the dot settles. Self-GCing.
    def sparkling?(path)
      deadline = @sparkles[path]
      return false unless deadline
      return true if deadline > monotonic

      @sparkles.delete(path)
      false
    end

    # Pure: has `window` seconds elapsed since `last` (nil = never)? The shared
    # comparison behind the scan / reload / visibility throttles. (spawn_due? is the
    # same idea with an explicit `now`, kept separate so it stays unit-testable.)
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

    # Structure + PR badges, NOT per-worktree dirty (16 git-status calls would
    # stall the paint). Fast.
    def rebuild
      @model = Model.new(@config, with_dirty: false)
      @nodes = Tree.nodes(@model, branch_cache: @branch_cache)
      resolve_keymap # re-read sidebar_keys so an `e` config edit re-binds the tree keys (#108)
      # Hydrate folds from the shared on-disk store so every window's sidebar
      # agrees and a respawned pane keeps them. GC against the configured project
      # names (the stable registry, not the git-built tree, so a project that
      # momentarily fails to build doesn't lose its fold).
      @collapsed = Collapse.collapsed(@config.projects.map { |p| p["name"] })
      @full_header = FullHeader.enabled? # shared toggle: full header on every session
      @fold_branches = BranchFold.folded? # shared toggle: fold every workspace's branches (#107)
      # Shared pane width: a ←/→ resize in any window lands here. Skip the hydrate
      # while a local resize is pending uncommitted (@resized): a rebuild triggered
      # mid-burst (a C-l/C-r token following a ←/→ in the same read) would otherwise
      # rehydrate the OLD on-disk width over the value commit_resize is about to
      # persist, silently dropping the resize. When the width changed elsewhere, nil
      # @geom so the next pin_if_resized actually re-pins — else it short-circuits on
      # our unchanged pane geometry and a peer window stays stuck at the old width
      # until a cross-session re-pin.
      unless @resized
        new_width = Width.resolved
        @geom = nil if new_width != @width
        @width = new_width
      end
      recompute_rows
    end

    # Resolve the configurable in-sidebar keys (issue #108) from @config into the
    # two views the rest of the sidebar reads: @keymap (key -> action, what
    # dispatch keys off) and @bindings (action -> key, what the ? overlay and
    # footer show). Re-run on every rebuild so an `e` config edit re-binds live.
    def resolve_keymap
      @keymap, @bindings = Keymap.resolve(@config) # single pass: key->action + action->key
    end

    # Visible rows. Normally: all nodes, minus the children of collapsed projects.
    # In / filter mode: each project's matching workspaces, kept UNDER their
    # project header so the grouping stays visible. Collapse is ignored (the point
    # is reaching any workspace fast, even a folded one). Headers ARE selectable
    # here — ↵ on a header creates a new workspace in that project, ↵ on a workspace
    # switches to it (see switch_to_filtered).
    def recompute_rows
      @rows = @filter ? filtered_rows : visible_tree
      @cursor = @cursor.clamp(0, [@rows.size - 1, 0].max)
    end

    # The normal (non-filter) rows: the full tree, minus the children of collapsed
    # projects, and — when the global `z` branch-fold is on (issue #107) — minus
    # every workspace's branch-history rows, each multi-branch workspace folded down
    # to a single row. Folding is a cheap row transform (like project collapse), NOT
    # a rebuild, so `z` is instant and the careful Tree / #90 diff-suppression logic
    # is untouched: a folded ws row is a shallow clone marked NOT expanded (so its own
    # diff/PR badge shows again — #90's suppression only bites while the branches are
    # visible) carrying the active branch's PR and the hidden-branch count for the cue.
    def visible_tree
      active_pr, counts = fold_lookup
      rows = []
      @nodes.each do |n|
        next if n.kind != "proj" && @collapsed.include?(n.project) # collapsed project hides its children
        next if n.kind == "br" && @fold_branches                   # folded: hide every branch row
        rows << (foldable_ws?(n) ? fold_ws(n, active_pr[n.path], counts[n.path]) : n)
      end
      rows
    end

    # Per-workspace [active-branch PR, branch-row count], precomputed once from the
    # branch nodes we're about to hide — what a folded ws row needs to stand in for
    # its active branch (the restored badge) and to show the `▸N` cue. Empty unless
    # folding, so the expanded tree pays nothing.
    def fold_lookup
      active_pr = {}
      counts = Hash.new(0)
      if @fold_branches
        @nodes.each do |n|
          next unless n.kind == "br"

          counts[n.path] += 1
          active_pr[n.path] = n.pr if n.active
        end
      end
      [active_pr, counts]
    end

    # A ws row whose branch rows are currently folded away (global `z` on AND it has
    # more than one branch). foldable_ws? gates the clone; fold_ws builds it.
    def foldable_ws?(node)
      @fold_branches && node.kind == "ws" && node.expanded
    end

    # A shallow clone of a folded multi-branch ws row: NOT expanded (so the render
    # gates show its own diff/PR badge again), carrying its active branch's PR and the
    # hidden-branch count (`folded`) for the dim `▸N` cue. A copy so @nodes is left
    # intact (rebuild reuses it; the @diffs cache keys on path/branch/kind, unchanged).
    def fold_ws(node, pr, count)
      node.class.new(**node.to_h.merge(expanded: false, pr: pr, folded: count))
    end

    # Filter rows: walk the tree and, per project, emit its header plus its matching
    # workspaces. A header shows when its OWN name matches — so a project with no
    # (matching) workspaces still appears, and you can ↵ to create its first one — OR
    # when it has matching workspaces (grouping context). Neither ⇒ dropped. Branch-
    # history rows are deliberately skipped: switching to one is identical to
    # switching to its workspace, so a lone branch match would just orphan under a
    # header with no workspace above it.
    def filtered_rows
      rows = []
      header = nil
      keep_header = false
      matches = []
      @nodes.each do |n|
        if n.kind == "proj"
          rows.push(header, *matches) if header && (keep_header || matches.any?)
          header = n
          keep_header = self.class.fuzzy_match?(n.project, @filter)
          matches = []
        elsif n.kind == "ws" && self.class.fuzzy_match?(filter_text(n), @filter)
          matches << n
        end
      end
      rows.push(header, *matches) if header && (keep_header || matches.any?)
      rows
    end

    # Where the cursor lands after a query keystroke: the first workspace match (so
    # type-then-↵ jumps), not the leading project header. Entry (start_filter) lands
    # on the first row instead; you can arrow up onto a header to create. 0 when
    # there's no match.
    def first_selectable
      @rows.index { |n| n.kind != "proj" } || 0
    end

    # The text a workspace is matched against in filter mode: project + its name +
    # its current branch, so typing a project name narrows to its workspaces and
    # typing a workspace (or current-branch) name jumps straight to it.
    def filter_text(node)
      [node.project, node.name, node.branch].compact.join(" ")
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
      on_agent_edges(announce_sounds: announce_sounds, refresh_prs: refresh_prs) # may mark new completions
      @attention = Attention.marked(ws_paths)          # load for render, after the marks land
      true
    rescue StandardError
      @agents = {}
      false
    end

    # Per-worktree diff counts (issue #79): "+adds −dels" of each row's branch vs
    # its base, cached off the paint loop like the agent dots and PR badges — a git
    # diff per worktree is the same cost as the git status the model skips with
    # with_dirty:false, so it can't ride the synchronous paint. Keyed [path, branch]
    # so a workspace's inline branch rows each carry their own count.
    #
    # The gate is the worktree's logs/HEAD mtime — read FRESH here, not from
    # @branch_cache[path][1], because that cached mtime only refreshes on rebuild;
    # the on_agent_edges caller runs WITHOUT a rebuild, so a just-landed commit would
    # otherwise compare stale-to-stale and skip. Only the gitdir ([0], stable and
    # already absolute) is safe to reuse from @branch_cache. A MERGED/CLOSED PR row
    # bypasses the gate: origin fast-forwarding past the branch zeros the base...HEAD
    # diff without moving logs/HEAD (the same blind spot the PR badge has, healed by
    # R). Compute value-or-nil; nil DELETES the entry, so a row that loses its cache
    # slot, base, or diffability clears instead of painting a ghost count. Fully
    # rescued — a diff fault never disturbs the dots or the paint.
    def refresh_diffs
      # #88: counts off ⇒ no git diff shell-outs at all (not just a hidden label).
      # clear (not a bare return) so a live flip to diff_counts:false drops any
      # counts already cached, instead of leaving stale numbers until a respawn.
      return @diffs.clear unless @config.diff_counts?

      @nodes.each do |n|
        next unless %w[ws br].include?(n.kind)

        # Key on kind too: an expanded workspace emits a ws row AND a br row for the
        # SAME current branch — they'd share [path, branch] but carry different prs
        # (the ws drops its badge when expanded, so pr nil ⇒ resting false; the br
        # keeps it), and the disagreeing resting flag would ping-pong the one entry
        # and recompute forever. Separate keys, separate (identical) entries.
        key = [n.path, n.branch, n.kind]
        gitdir = @branch_cache.dig(n.path, 0)
        head_log = gitdir && File.join(gitdir, "logs", "HEAD")
        mtime = head_log && File.exist?(head_log) ? File.mtime(head_log) : nil
        # Recompute when the reflog moved (fresh mtime) OR the PR just entered/left a
        # resting state (MERGED/CLOSED) — that flip is when origin may have
        # fast-forwarded past the branch and zeroed base...HEAD without touching
        # logs/HEAD. The resting flag is stored, so a merged row recomputes ONCE on
        # the transition, not every reload (which would re-run a synchronous git diff
        # forever — the cost with_dirty:false exists to avoid). R clears @diffs for
        # the rare lag where the fetch trails the badge flip.
        # Gate on (mtime, resting) — and skip on entry presence alone, NOT `mtime &&`:
        # a worktree with a cached gitdir but a vanished logs/HEAD reads mtime nil, and
        # requiring a non-nil mtime to skip would recompute it every reload. With this,
        # a nil-mtime row computes ONCE (nil == nil holds next pass) and self-heals to
        # the normal gate the moment logs/HEAD returns (its real mtime != the stored nil).
        resting = %w[MERGED CLOSED].include?(View.pr_state(n.pr))
        entry = @diffs[key]
        next if entry && entry[0] == mtime && entry[1] == resting

        counts = (Git.diff_counts(n.path, n.base, n.branch) if gitdir && n.base)
        if counts
          @diffs[key] = [mtime, resting, *counts]
        else
          @diffs.delete(key)
        end
      end
    rescue StandardError
      nil
    end

    # The cached [adds, dels] for a row, or nil. Drops the leading [mtime, resting?]
    # the gate keys on. ws/br only — projects never have a diff.
    #
    # A folded multi-branch ws (the fold_ws clone, marked by `folded`) stands in for
    # its active branch, so it reads that branch's cached diff (keyed "br"), NOT its
    # own "ws" entry. The values are identical (base...HEAD == base...active-branch),
    # but only the "br" entry takes the #90 MERGED/CLOSED bypass: refresh_diffs derives
    # the "ws" entry's resting flag from the expanded ws node, whose pr is nil, so it
    # misses the bypass that zeros a merged branch when origin fast-forwards past it
    # without moving logs/HEAD. Reading "br" makes a folded ws self-heal on merge
    # exactly like the unfolded branch row does (R is still the manual catch-all).
    def diff_for(node)
      kind = node.folded ? "br" : node.kind
      entry = @diffs[[node.path, node.branch, kind]]
      entry && entry.drop(2)
    end

    # The single place that decides whether a row shows a diff count. Folds in both
    # the #88 global toggle and the #90 expanded-ws suppression: an expanded
    # workspace's name row diffs HEAD (== its active branch), so the count would
    # duplicate the active branch row right below it — show it on the branch rows
    # only. Re-checks @config here (not just at refresh_diffs) so render hides the
    # count the instant the toggle flips, before the next reload clears @diffs.
    def diff_visible?(node)
      return false unless @config.diff_counts?
      return false unless %w[ws br].include?(node.kind)

      !(node.kind == "ws" && node.expanded)
    end

    # announce_sounds: false on a catch-up scan (a sidebar waking from off-screen,
    # or the session-switch poke) — re-baseline + refresh PRs without ringing for
    # completions another sidebar already announced. Defaults true: continuous
    # while-visible scans ring as they always have.
    def reload(announce_sounds: true)
      rebuild
      locate # before refresh_agents: marks below skip the workspace you're in, and viewing it clears its bold
      # Capture the warm-gate fingerprint BEFORE the scan, so @warm_fp can never
      # outrun what this reload actually rendered (the same stale-stuck race
      # warm_reload guards against): a change landing mid-reload leaves fp behind, so
      # the next off-screen warm re-fires instead of suppressing forever.
      fp = warm_fingerprint
      refresh_agents(announce_sounds: announce_sounds)
      refresh_diffs # branch-vs-base counts, gated on each worktree's reflog mtime
      refresh_stale_prs
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
    # (each tracked worktree's logs/HEAD mtime), and PR badges (the PR cache).
    # Deliberately NOT covered (they refresh on the switch-in reload, as before):
    # a worktree added/removed in ANOTHER session, and shared view-state
    # (collapse/full-header/branch-fold/width). Fully rescued — a stat fault yields
    # a value that just triggers one harmless warm, never crashes the loop.
    def warm_fingerprint
      reflogs = @branch_cache.values.filter_map do |gitdir,|
        head = File.join(gitdir.to_s, "logs", "HEAD")
        [head, File.mtime(head).to_f] if gitdir && File.exist?(head)
      end
      [dir_fingerprint(AgentState.state_dir),  # agent dots
       dir_fingerprint(Attention.state_dir),   # bold markers
       dir_fingerprint(Pr.cache_dir),          # PR badges
       dir_fingerprint(Collapse.state_dir),    # shared project folds (the originally-missed case)
       file_fingerprint(FullHeader.marker),    # full-header toggle
       file_fingerprint(BranchFold.marker),    # branch-fold toggle
       file_fingerprint(Width.state_file),     # sidebar width
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
    # on_agent_edges still runs (marks + baseline advance), just without the spawn.
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
    # Badges are cached on disk and read instantly; these triggers keep that
    # cache fresh in the background, never blocking the paint loop. Three triggers
    # funnel into maybe_refresh_prs, which debounces per project then detaches a
    # `switchboard refresh` child that rewrites the cache and pokes us to redraw.

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

    # T1 — a hooked agent just reached a resting state (finished a turn / asked
    # for input). Four consumers ride the same edge: a bold "needs attention"
    # marker (the visual twin of the dot, persisted so it survives until viewed), a
    # background PR refresh (it may have pushed a branch / opened a PR), a
    # completion sound (the audible twin), and a brief on-row twinkle (its visual
    # twin — same announce_sounds gate as the sound). Uses the hook-only states
    # (never the activity fallback, which flips every 3s and would fire on noise).
    # Skips the first scan — no baseline to diff.
    #
    # Ordering + isolation are load-bearing: the mark and PR refresh run first,
    # each fully rescued so its fault can't starve the others, and @prev_hook_states
    # ALWAYS advances (ensure) so a raise here can't corrupt the next edge diff — or
    # trip refresh_agents' broad rescue into blanking the dots.
    #
    # announce_sounds gates the sound and its twinkle, not the mark, the PR refresh,
    # or the baseline advance. A catch-up scan (switch-in / reappear) passes false: each sidebar
    # is its own process with its own baseline, frozen while off-screen, so without
    # this it would re-ring every completion that finished while it slept (already
    # heard from the sidebar that was on screen then). PRs still refresh — debounced
    # and idempotent — and the baseline still advances, so the next real completion
    # scanned while we're here rings normally.
    def on_agent_edges(announce_sounds: true, refresh_prs: true)
      now = @agent_state.last_hook_states
      if @prev_hook_states
        edges = self.class.completion_edges(@prev_hook_states, now)
        mark_attention_for(edges)
        refresh_prs_for(edges) if refresh_prs # warm suppresses the off-screen PR-spawn fan-out
        refresh_diffs if edges.any? # a finished turn likely just committed — repaint its count
        if announce_sounds
          play_sounds_for(edges, now)
          sparkle_for(edges, now)
        end
      end
    ensure
      # Merge, not replace: keep a STICKY baseline. A worktree whose hook report
      # ages out of `now` (a span longer than PRESENCE_TTL with no hook event —
      # e.g. one tool that runs longer than the TTL) must retain its last-known
      # state, or its eventual completion would read as a brand-new first
      # appearance (prev.key? false) and be silently swallowed. Stickiness also
      # keeps a restarted session quiet: SessionStart's :done matches the
      # remembered :done, so it's a non-change, not an edge. Bounded by worktrees
      # seen this process — tiny; never pruned.
      @prev_hook_states = (@prev_hook_states || {}).merge(now)
    end

    # Edge paths -> a bold "needs attention" marker each, except the workspace
    # you're already sitting in (you're watching it finish — no nudge needed). The
    # marker is persistent disk state, so unlike the sound it rides EVERY scan
    # (continuous and catch-up alike, no announce_sounds gate): which process
    # writes it doesn't matter, every sidebar reads the same file and bolds the row
    # until you view it (locate clears it). Fully rescued — never disturbs the scan.
    def mark_attention_for(edges)
      edges.each { |path| Attention.mark(path) unless viewing?(path) }
    rescue StandardError
      nil
    end

    # Are we currently sitting in this worktree? Canonicalizes both sides — edge
    # paths come realpath'd from the hook, @current_path raw from git.
    def viewing?(path)
      return false unless @current_path

      Attention.same_path?(path, @current_path)
    end

    # Edge paths -> owning projects -> debounced PR refresh (deduped per project).
    def refresh_prs_for(edges)
      edges.filter_map { |path| project_for_path(path) }.uniq
           .each { |project| maybe_refresh_prs(project) }
    end

    # Edge paths -> a completion sound each. completion_edges returns distinct
    # paths, so this is one sound per [worktree, state]: every worktree's
    # completion is heard, but a worktree can't double-fire in one scan. Fully
    # rescued — a sound fault never disturbs the scan or the PR refresh above.
    def play_sounds_for(edges, now)
      edges.each { |path| Sound.play(@config.sound_for(project_for_path(path), now[path])) }
    rescue StandardError
      nil
    end

    # Edge paths -> a brief completion twinkle each — the visual twin of the sound,
    # so it rides the same announce_sounds gate: only the sidebar you're watching
    # twinkles (a catch-up scan re-baselines silently and still). Only :done
    # sparkles — :waiting already blinks for attention. The deadline is wall-clock
    # (monotonic) so it expires in real time even while the pane is hidden — no stale
    # replay on switch-back; pulsing? keeps the loop animating while it's live, then
    # sparkling? GCs it. Fully rescued — a fault never disturbs scan, sound, or refresh.
    def sparkle_for(edges, now)
      deadline = monotonic + SPARKLE_SECS
      edges.each { |path| @sparkles[path] = deadline if now[path] == :done }
    rescue StandardError
      nil
    end

    # T3 — idle backstop: refresh any project whose badges have gone stale past
    # BACKSTOP_TTL — the ~2-min net that catches a PR merged/closed on GitHub
    # (which fires no local trigger) when nothing else does. Capped at
    # MAX_SPAWN_PER_RELOAD so opening home on a cold cache doesn't launch one gh
    # per project at once; the rest catch up on later reloads.
    def refresh_stale_prs
      @config.projects
             .map { |p| p["name"] }
             .select { |name| Pr.stale?(name, BACKSTOP_TTL) }
             .first(MAX_SPAWN_PER_RELOAD)
             .each { |name| maybe_refresh_prs(name) }
    rescue StandardError
      nil
    end

    # T4 — manual (R): force a refresh of every registered project's badges,
    # bypassing the staleness gates the automatic triggers use. A PR merged or
    # closed on GitHub fires no local signal, so this is the "I just did that, show
    # it now" escape hatch; the detached children poke us to redraw as gh returns.
    # Still debounced per project (maybe_refresh_prs), so a mashed R can't storm gh.
    # No wrapper (SWITCHBOARD_BIN unset) ⇒ maybe_refresh_prs can't spawn, so bail
    # before the notify rather than claim a refresh that can't happen. (A refresh
    # already in flight from a prior press still notifies — it's honest, one's running.)
    def refresh_prs_now
      # Diff counts are local, so heal them here too (R is the manual "show it now"
      # for the merged/base-moved staleness the mtime gate can't see) — independent
      # of the wrapper the PR refresh needs. Clear + recompute against the cached tree.
      @diffs.clear
      refresh_diffs
      return unless ENV["SWITCHBOARD_BIN"]

      @config.projects.map { |p| p["name"] }.each { |name| maybe_refresh_prs(name) }
      Tmux.notify("switchboard: refreshing #{@config.diff_counts? ? 'PRs + diffs' : 'PRs'}…")
    rescue StandardError
      nil
    end

    # Fire a non-blocking PR refresh for a project, debounced per project.
    # Detaches `switchboard refresh <project> --poke <our pane>` (mirrors
    # open_pr): the gh call stays off this paint loop, and the child redraws THIS
    # sidebar — the explicit pane id survives us navigating away before gh
    # returns, where a "current pane" lookup would drift. No SWITCHBOARD_BIN
    # (launched without the wrapper) ⇒ skip; cached badges still show.
    def maybe_refresh_prs(project)
      bin = ENV["SWITCHBOARD_BIN"]
      return unless bin && project
      # The sandbox (#126) seeds a STATIC PR cache to demo badges; its throwaway repo
      # has no origin, so a background `switchboard refresh` would fetch {} and clobber
      # the seed — the badge you're dogfooding would vanish. Skip the spawn there.
      return if ENV["SWITCHBOARD_SANDBOX"]

      now = monotonic
      return unless self.class.spawn_due?(@pr_spawned[project], now)

      @pr_spawned[project] = now
      pid = Process.spawn(bin, "refresh", project, "--poke", ENV["TMUX_PANE"].to_s,
                          out: File::NULL, err: File::NULL)
      Process.detach(pid)
    rescue SystemCallError
      nil
    end

    # The project owning a worktree path (over the ws nodes), or nil.
    def project_for_path(path)
      @nodes.find { |n| n.kind == "ws" && n.path == path }&.project
    end

    # --- input ---------------------------------------------------------------

    # :eof when our pane closed (read past end-of-stream) so the loop can exit
    # cleanly instead of busy-spinning forever on a dead pty; nil when select woke
    # us spuriously with nothing to read (treated as no key).
    def read_key
      $stdin.read_nonblock(READ_BYTES)
    rescue EOFError
      :eof
    rescue IO::WaitReadable
      nil
    end

    # Split a read into whole key tokens and dispatch each. A read can deliver many
    # keys at once (a held key-repeat, or the flurry of focus events tmux sends the
    # sidebar pane as it loses focus during a session switch). The original bug was
    # read_key's fixed 8-byte read (not a multiple of 3) slicing a multi-event
    # buffer: three focus events = 9 bytes, capped at 8, left a bare `O` (the tail
    # of focus-out `\e[O`) that dispatched as the open-repo key — you'd land on
    # GitHub right after creating a workspace. READ_BYTES (1024) removes that cap
    # for any realistic burst; tokenize is the structural backstop, parsing by the
    # real terminal grammar and carrying any sequence that still straddles a read
    # boundary in @pending so a final byte is never read alone as a key.
    #
    # A stop-token (quit ⇒ dispatch returns false) ends the loop NOW: never dispatch
    # the rest of the buffer past it, so a key buffered after a confirmed `q` can't
    # fall through into another action.
    def handle(buf)
      tokens, @pending = self.class.tokenize(@pending + buf.to_s)
      tokens.each { |t| return false unless dispatch(t) }
      true
    end

    # Pure terminal-input tokenizer: returns [complete tokens, trailing incomplete
    # sequence]. The grammar it recognizes (the only escapes a tmux pane delivers):
    #
    #   \e [ <param/intermediate 0x20-0x3F>* <final 0x40-0x7E>   CSI: arrows, focus (\e[I/\e[O)
    #   \e <any other byte>                                      Alt / SS3 lead (2-byte token)
    #   \e        (alone at the end of the buffer)               the Esc key
    #   <byte>                                                   a plain key
    #
    # An incomplete CSI (`\e[…` with no final byte yet) is returned as the remainder
    # rather than emitted, so its final byte can never be read alone as a key. `\e`
    # plus any non-`[` byte is consumed TOGETHER (a 2-byte token), so the `O` in an
    # SS3 `\eO…` can't escape alone either. A lone trailing `\e` is emitted as the
    # Esc key, not carried: terminals write a sequence's bytes as one unit, so a `\e`
    # with nothing after it is the key — and carrying it would stall Esc (filter /
    # prompt cancel) waiting for bytes that never come. The one case this leaves open
    # is a CSI split BEFORE its `[` (a read ending on a lone `\e`, the next starting
    # `[O`): the `\e` flushes as Esc and the `O` could re-orphan. That needs tmux to
    # fragment a 3-byte focus event across reads — it doesn't (it writes the sequence
    # in one go, and READ_BYTES reads it whole) — so it's unreachable here; closing
    # it for good would mean an Esc-timeout in the run loop, not worth the timing.
    def self.tokenize(buf)
      tokens = []
      i = 0
      n = buf.bytesize
      while i < n
        if buf.getbyte(i) != 0x1b            # plain key byte
          tokens << buf.byteslice(i, 1)
          i += 1
        elsif i + 1 >= n                      # lone trailing \e -> the Esc key
          tokens << buf.byteslice(i, 1)
          i += 1
        elsif buf.getbyte(i + 1) != 0x5b      # \e + non-'[' -> Alt / SS3 lead, kept whole
          tokens << buf.byteslice(i, 2)
          i += 2
        else                                  # CSI: \e[ params/intermediates, then a final byte
          j = i + 2
          j += 1 while j < n && (0x20..0x3f).cover?(buf.getbyte(j))
          if j >= n # final byte not here yet -> carry the partial, but cap it: no real
            partial = buf.byteslice(i, n - i) # CSI runs long, so an unterminated param run
            return [tokens, partial.bytesize <= CSI_MAX ? partial : +""] # is garbage, drop+resync
          elsif (0x40..0x7e).cover?(buf.getbyte(j)) # a valid final byte: emit the whole CSI
            tokens << buf.byteslice(i, j - i + 1)
            i = j + 1
          else # byte j is neither param nor final -> malformed: emit \e[… WITHOUT it and
            tokens << buf.byteslice(i, j - i) # resume on byte j, so a real key (a control
            i = j                             # byte like \r/\f after a split \e[) still fires
          end
        end
      end
      [tokens, +""]
    end

    def dispatch(key)
      return help_key(key) if @help     # ? overlay is open: a real key closes it, pokes pass through
      return filter_key(key) if @filter # / filter mode swallows the normal bindings

      # Structural sequences first: reserved keys with their own control flow that
      # are NOT user-remappable (issue #108) — the resize arrows, the ↵ context-
      # action, the C-l/C-r pokes, focus in/out. They're non-printable, so a
      # printable sidebar_keys override (Config#valid_sidebar_key?) can never
      # shadow them; checking them up front keeps that explicit.
      case key
      when "\e[C"             then resize(WIDTH_STEP)  # → widen the pane (issue #78)
      when "\e[D"             then resize(-WIDTH_STEP) # ← narrow the pane
      when "\r", "\n"         then enter
      when "\f"               then reload_and_refresh # Ctrl-L (hook poke on switch)
      when WARM_POKE_BYTE     then warm_poke # Ctrl-W (peer broadcast: shared view-state changed)
      when RELOAD_CONFIG_BYTE then reload_config_and_rebuild # Ctrl-R (post-edit reload)
      when "\e[I"             then return false if focus_in # focus-in: light cursor; #64 fast reap may exit the loop
      when "\e[O"             then @focused = false # tmux focus-out: drop it
      else                         return dispatch_action(key)
      end
      true
    end

    # The configurable arm of dispatch (issue #108): resolve the key to an action
    # via @keymap (its default, a sidebar_keys override, or a fixed alias like
    # ↓/^N/^O), then fire it. An unbound key is a no-op. Returns false only when
    # quit tears everything down (so the run loop exits); true otherwise.
    def dispatch_action(key)
      case @keymap[key]
      when :down               then move(1)
      when :up                 then move(-1)
      when :top                then @cursor = 0
      when :bottom             then @cursor = [@rows.size - 1, 0].max # clamp: empty tree → 0, not -1
      when :filter             then start_filter # type-to-filter the tree (issue #60)
      when :add_project        then add
      when :new_workspace      then create
      when :open_pr            then open_pr # open the PR in the browser
      when :open_repo          then open_repo # open the row's repo (branch if it has an open PR, else default)
      when :rename             then rename
      when :delete             then remove
      when :edit_config        then edit_config
      when :refresh_prs        then refresh_prs_now # force a PR-badge refresh (external merge/close)
      when :toggle_branch_fold then toggle_branch_fold # fold/unfold every workspace's branches (#107)
      when :toggle_full_header then toggle_full_header # seat the full header on every session
      when :help               then show_help # the full key map overlay (issue #62)
      when :quit               then return quit # q: tear down ALL switchboard sessions
      end
      true
    end

    # q: full teardown — kill every sb/ session (Tmux.kill_all), our own last so
    # the sweep finishes before this process dies with it. Guarded by a y/N
    # confirm because q meant "hide" until recently — an unconfirmed q just stays
    # in the loop (returns true). Confirmed, we return false too, so a no-server
    # quit (nothing to kill) still drops out cleanly.
    def quit
      return true unless confirm("quit all switchboard sessions?")

      AgentState.clear_all # killing every agent makes their last hook state stale — drop it now
      Tmux.kill_all
      false
    end

    # tmux focus-in: this pane is now the active one, so it's on screen. Light the
    # cursor bar and mark visible. If we were HIDDEN, do the same silent catch-up
    # reload tick would on an off->on edge — because marking @visible here consumes
    # the edge tick detects (`visible && !@visible`), so without this an un-poked
    # reappearance (bare attach, a stale window-switch hook) that lands focus on the
    # sidebar would render a stale tree until the next TREE_TICKS reload. A real
    # poked switch-in already set @visible=true, so reappeared is false — no double.
    def focus_in
      @focused = true
      reappeared = !@visible
      set_visible(true)
      reload(announce_sounds: false) if reappeared
      cursor_to_current # going back to the sidebar selects the workspace you're in
      # #64 fast reap: we may have just gained focus BECAUSE our work sibling closed and
      # we became the lone (active) pane. Check now so the wedge is caught within a frame
      # instead of up to one REFRESH tick. Returns true (=> dispatch exits the loop) only
      # in the workspace fall-home case; a normal focus-in (work pane still there) is false.
      lone_pane_handled
    end

    def move(delta)
      return if @rows.empty?

      @cursor = (@cursor + delta).clamp(0, @rows.size - 1)
    end

    # ↵: collapse/expand a project header, or switch to a workspace/branch.
    def enter
      node = current
      return unless node

      node.kind == "proj" ? toggle_collapse(node.project) : switch(node)
    end

    # Flip a project's fold, writing through to the shared store so every other
    # window's sidebar picks it up on its next reload (a switch-in poke, or a
    # while-visible scan). The in-memory set is updated too for same-frame feedback.
    def toggle_collapse(project)
      if @collapsed.include?(project)
        @collapsed.delete(project)
        Collapse.expand(project)
      else
        @collapsed.add(project)
        Collapse.collapse(project)
      end
      recompute_rows
      Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # other sidebars repaint the fold now (no switch-in flash)
    end

    # H: flip the full header on/off for EVERY session. Like the project fold it
    # writes through to the shared store (FullHeader), so every other window's
    # sidebar picks it up on its next reload (a switch-in poke or a while-visible
    # scan); the in-memory flag flips too for same-frame feedback in this pane (the
    # next render reads it). No recompute — only the header lines change, not @rows.
    def toggle_full_header
      @full_header = !@full_header
      @full_header ? FullHeader.enable : FullHeader.disable
      Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # other sidebars repaint the header now
    end

    # z: fold/unfold EVERY workspace's branch-history rows tree-wide (issue #107).
    # Global, regardless of the cursor. Like the project fold and the full-header
    # toggle it writes through to the shared store (BranchFold) so every other
    # window's sidebar picks it up on its next reload, and flips the in-memory flag
    # for same-frame feedback. Unlike those it DOES recompute_rows — folding changes
    # which rows are visible. The cursor then re-anchors to the row it was on by path:
    # folding from a branch row lands you on that workspace's row (the branch rows it
    # shared a path with are gone), so `z` doesn't jump you somewhere unrelated.
    def toggle_branch_fold
      here = current&.path
      @fold_branches = !@fold_branches
      @fold_branches ? BranchFold.fold : BranchFold.unfold
      recompute_rows
      i = @rows.index { |n| n.path == here } if here
      @cursor = i if i
      Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # other sidebars repaint the fold now
    end

    def switch(node)
      Tmux.go(Worktree.new(project: node.project, path: node.path, branch: node.branch,
                           dirty: false, pr: node.pr, base: nil, primary: false),
              start: @config.session_command_for(node.project))
    end

    # --- ? help overlay (issue #62) ------------------------------------------
    #
    # `?` opens the full key map over the tree (render_help). While it's open,
    # dispatch routes every key here: a real keystroke closes it, but a synthetic
    # tmux byte (HELP_IGNORED_BYTES — the C-l/C-r pokes, focus in/out) is ignored so a
    # background PR-refresh poke or a focus change can't dismiss it out from under
    # the reader — the same robustness filter_key has. `?` can't open while filtering
    # (there it's a query char), so @help and @filter are never both set.

    # `?`: open the overlay. No recompute — the overlay doesn't read @rows.
    def show_help
      @help = true
    end

    # Any real key dismisses; a poke/focus byte passes through untouched. Always
    # returns true (the loop lives on, and the dismissing key only closes the
    # overlay — no passthrough into an action, even a typed q).
    def help_key(key)
      dismiss_help unless HELP_IGNORED_BYTES.include?(key)
      true
    end

    def dismiss_help
      @help = false
    end

    # --- / filter mode (issue #60) -------------------------------------------
    #
    # An in-sidebar, fzf-style incremental filter — NOT the removed external fzf
    # popup. `/` enters; printable keys extend a query that narrows the rows to
    # matching switch targets; ↵ jumps to the highlighted match; Esc restores the
    # full tree. Like fzf, j/k are query input here (not motion — unlike the tree,
    # where they move) — movement is the arrows / ^N / ^P — so any name is reachable
    # by typing, and no destructive key (d, q) can fire mid-search.

    # Key handling while filtering. Always returns true: filter mode never quits
    # the loop — a typed 'q' is just a query character, not a teardown.
    def filter_key(key)
      case key
      when "\e"           then end_filter            # Esc: cancel, restore the full tree
      when "\r", "\n"     then switch_to_filtered    # ↵: open the highlighted match
      when "\e[B", "\x0E" then move(1)               # ↓ / ^N within the matches
      when "\e[A", "\x10" then move(-1)              # ↑ / ^P
      when "\x7F", "\b"   then backspace_filter       # Backspace (DEL / ^H): trim the query
      else append_filter(key) if printable?(key) # any printable ASCII char -> query
      end
      true
    end

    # A single printable ASCII byte (the only thing that extends the query). Tested
    # at the BYTE level — read_nonblock hands us ASCII-8BIT, so a stray high byte
    # from a non-ASCII keypress is one out-of-range byte we ignore, never a decode
    # that raises. UTF-8 in workspace names isn't typeable into the query (yet).
    def printable?(key)
      key.bytesize == 1 && key.getbyte(0).between?(0x20, 0x7E)
    end

    # /: enter filter mode with an empty query (matches everything, so the full
    # tree shows) and the cursor on the first row. The leap-to-first-match only
    # happens once you type (append_filter) — entry leaves you at the top.
    def start_filter
      @filter = +""
      recompute_rows
      @cursor = 0
    end

    # Esc: leave filter mode, restore the full collapse-aware tree, and land back
    # on the workspace this session is in (cursor_to_current) rather than wherever
    # the filtered cursor sat.
    def end_filter
      @filter = nil
      @cursor = 0
      recompute_rows
      cursor_to_current
    end

    # A printable char extends the query; re-select the top workspace match
    # (fzf-style), so the best result is always one ↵ away as you type.
    def append_filter(ch)
      @filter += ch
      recompute_rows
      @cursor = first_selectable
    end

    # Backspace trims the query; backspacing past the start exits filter mode —
    # erasing your way back through the `/` is the same gesture as Esc.
    def backspace_filter
      return end_filter if @filter.empty?

      @filter = @filter[0..-2]
      recompute_rows
      @cursor = first_selectable
    end

    # ↵ in filter mode is context-sensitive, like the normal tree's ↵ but repurposed
    # for search: on a workspace it switches (open the existing one); on a project
    # header it CREATES a new workspace there (collapse is meaningless while
    # filtering, so ↵-on-project becomes the project-level action). Grab the row
    # before end_filter rebuilds @rows; both paths then act on the normal tree.
    def switch_to_filtered
      node = current
      return unless node

      end_filter
      node.kind == "proj" ? create(node) : switch(node)
    end

    # Fire-and-forget a `gh` command that may hit the network, off the paint loop.
    # Detached, not `system`: gh resolves the PR/repo against the API before opening
    # the browser, so a slow network would otherwise freeze the loop. spawn raises
    # (unlike system) if the dir or `gh` is missing, so swallow that to keep the UI
    # alive — nothing opens on failure. Shared by open_pr and open_repo.
    def spawn_gh(*args, chdir:)
      Process.detach(Process.spawn("gh", *args, chdir: chdir, out: File::NULL, err: File::NULL))
    rescue SystemCallError
      nil
    end

    # o: open the highlighted workspace/branch's PR in the browser. Runs in the
    # worktree dir so `gh` infers the repo. No PR for the branch ⇒ gh exits quietly
    # and nothing opens.
    def open_pr
      node = current
      return unless node && node.kind != "proj"

      branch = node.branch.to_s
      return if branch.empty? || branch.start_with?("-") # never hand a dash-led name to gh as a flag

      spawn_gh("pr", "view", branch, "--web", chdir: node.path)
    end

    # `gh browse` sub-args for a row, or nil if it has no openable path. Deep-link the
    # repo AT the row's branch (--branch) only when the row has an OPEN PR: GitHub
    # closes a PR the instant its head branch is deleted, so an open (or draft —
    # status is still "OPEN") PR guarantees the branch is on the remote and
    # /tree/<branch> resolves rather than 404s. A merged/closed PR keeps its badge
    # (Pr.fetch lists --state all) after the branch is gone, so it is NOT a deep-link
    # signal. No open PR — and the project header, which has neither pr nor branch —
    # opens the repo home / default branch. node.pr is already loaded for the badge,
    # so this costs no extra I/O; an open PR also implies a valid pushed branch name,
    # so no dash-led guard is needed.
    def self.browse_args(node)
      return nil unless node && node.path

      args = ["browse"]
      branch = node.branch.to_s
      args += ["--branch", branch] if node.pr.is_a?(Hash) && node.pr["status"].to_s.upcase == "OPEN" && !branch.empty?
      args
    end

    # O: open the highlighted row's repo in the browser (sibling to o/PR). Unlike o
    # this rides every kind — every worktree resolves to the same repo — so it works
    # on the project header too. browse_args picks repo-home vs the row's branch.
    def open_repo
      node = current
      args = self.class.browse_args(node)
      return unless args

      spawn_gh(*args, chdir: node.path)
    end

    # Create the worktree (quiet) and drop into it — no name prompt. `n` (and
    # filter-mode ↵-on-a-project, which passes that header in) always auto-names:
    # `Creator.create` with a blank name cuts a placeholder adjective-noun dir +
    # branch you start working in immediately, then rename once you know the work via
    # `r` / `switchboard rename` / the agent nudge (#114 — doubling down on the
    # deferred-naming #94 and agent self-naming #92). Defaults to the highlighted row.
    def create(node = current)
      return unless node

      rows, = winsize
      print "\e[#{rows};1H\e[K\e[?25lcreating…"
      $stdout.flush
      dest = Creator.create(@config, node.project, "")

      if dest
        Tmux.go(Worktree.new(project: node.project, path: dest, branch: nil,
                             dirty: false, pr: nil, base: nil, primary: false),
                start: @config.session_command_for(node.project))
      end
      reload
    end

    # a: register a new project. n only makes worktrees *inside* a project, so
    # this is the keyboard path to the first project — switchboard can now stand
    # up from an empty sidebar with no CLI round-trip. Two modes: point at a repo
    # already on disk, or clone one from a URL.
    def add
      rows, cols = winsize
      print "\e[#{rows};1H\e[K\e[?25h#{trunc('add — [l] local repo · [c] clone url', cols)}"
      $stdout.flush
      choice = read_char
      print "\e[?25l"
      case choice&.downcase
      when "l" then add_local
      when "c" then add_clone
      else reload
      end
    end

    # Register an existing local repo by path. Name derives from its basename.
    def add_local
      path = prompt_line("path to an existing git repo")
      return reload if blank_input?(path)

      _, err = Registrar.register(@config, path)
      flash(err) if err
      reload_config
      reload
    end

    # Clone a URL under projects_root, then register it. The clone blocks the
    # paint loop (like delete/rename do) — fine, it's a deliberate action.
    def add_clone
      url = prompt_line("git URL to clone")
      return reload if blank_input?(url)

      rows, cols = winsize
      print "\e[#{rows};1H\e[K#{trunc("cloning #{url}…", cols)}"
      $stdout.flush
      _, err = Registrar.clone(@config, url)
      flash(err) if err
      reload_config
      reload
    end

    # Re-read config from disk so a freshly added project shows on the next
    # rebuild (@config is otherwise cached for the session). Config.new no longer
    # raises on malformed YAML (it degrades to empty + records load_error), so keep
    # the last good @config on a parse error and return the error for the caller to
    # surface; nil on a clean reload.
    def reload_config
      fresh = Config.new
      @config = fresh unless fresh.load_error
      fresh.load_error
    end

    # e: edit config.yml in its own pane beside the home sidebar, then return to
    # wherever we are now. Scaffold first so there's always a real file to edit.
    # The editor owns its OWN throwaway pane (not this narrow strip, not the
    # shared home shell), so there's no raw-mode dance and we just stay a live
    # tree. The editor is left UNescaped (Editor::SHELL_COMMAND) so the spawned
    # shell expands $EDITOR at run time, not this sidebar process. The trailer —
    # run in that pane after :q — switches the client back to this session and
    # pokes its sidebar to re-read config (Ctrl-R), so a changed session_command /
    # new project shows the moment you quit.
    def edit_config
      Config.scaffold
      bin    = Shellwords.escape(ENV["SWITCHBOARD_BIN"] || "switchboard")
      path   = Shellwords.escape(Config.path)
      origin = Shellwords.escape(Tmux.session_of.to_s) # the session `e` was pressed from
      Tmux.edit_in_home("#{Editor::SHELL_COMMAND} #{path}; #{bin} reload-config #{origin}")
    end

    # Re-read the (possibly hand-edited) config and rebuild — driven by the
    # dedicated post-edit poke (Ctrl-R) after `e`'s editor exits. Guard the parse:
    # the whole point of `e` is editing raw YAML, so a syntax slip is expected.
    # reload_config keeps the last good @config on a parse error and hands back the
    # message; surface it on tmux's status line — visible even when focus isn't on
    # the tree — rather than tear the sidebar down.
    def reload_config_and_rebuild
      if (err = reload_config)
        return Tmux.notify("switchboard: config not reloaded — #{err}")
      end

      # Also a catch-up: `e` switches the client to home to edit, so this sidebar
      # was off-screen with a frozen baseline while the (visible) home sidebar
      # rang any completions. Reload silently on the Ctrl-R return — else those
      # already-heard completions re-ring here, the same duplicate this fix kills.
      # C-r is sent only after the client is switched back to us, so we're on screen:
      # mark visible (consume the off->on edge so tick won't reload again, ungate paint).
      set_visible(true)
      reload(announce_sounds: false)
    rescue StandardError => e
      Tmux.notify("switchboard: config not reloaded — #{e.message}")
    end

    # d: remove the highlighted thing. On a project header that's
    # remove_project (unregister + close its sessions); on a workspace it's
    # delete (drop the worktree). The legend's `d` label tracks the row kind.
    def remove
      node = current
      return unless node

      node.kind == "proj" ? remove_project(node) : delete
    end

    # Remove a project from the registry and close its sessions (the keyboard
    # path to what you'd otherwise do by hand-editing config.yml). Unregistering
    # is pure config surgery — the repo and its worktrees on disk are untouched —
    # but its sb/ sessions are torn down here: once the project is gone from the
    # registry, prune (which reconciles only against registered projects) can
    # never reach them, so they'd orphan for good.
    #
    # Removing the project you're standing in would kill the very session this
    # sidebar runs in. Like workspace delete, fall back to home first; the home
    # sidebar then drives. Home rebuilds from git, which won't show a config
    # change, so poke it to re-read the now-smaller config — BEFORE the kill, or
    # our own death aborts the poke.
    def remove_project(node)
      name = node.project
      return unless @config.project(name)
      return unless confirm("remove #{name}? (closes its sessions)")

      # Unregister first and bail on failure — never kill sessions while the
      # config still lists the project (a write error with the config stale
      # would otherwise leave a registered project with no sessions). The guard
      # above makes the error unreachable today, but it keeps the kill honest.
      _, err = Registrar.unregister(@config, name)
      return flash(err) if err

      ejecting = Tmux.session_of.to_s.start_with?(Tmux.session_prefix(name))
      Tmux.go_home if ejecting
      Tmux.poke_sidebar_of(Tmux::HOME, reload_config: true) if ejecting
      Tmux.kill_project_sessions(name)
      return if ejecting

      reload_config
      reload
    end

    # Delete a workspace: remove the worktree (force-confirm if dirty), drop the
    # branch if safely merged, and kill its tmux session.
    def delete
      node = current
      return unless node && node.kind == "ws"

      project = @config.project(node.project)
      return unless project

      repo = project["path"]
      label = File.basename(node.path)
      return unless confirm("delete #{label}?")

      unless Git.remove_worktree(repo, node.path)
        return unless confirm("#{label} has uncommitted changes — force?")

        Git.remove_worktree(repo, node.path, force: true)
      end
      Git.delete_branch(repo, node.branch) # safe -d; unmerged branches are kept

      worktree = Worktree.new(project: node.project, path: node.path, branch: node.branch,
                              dirty: false, pr: nil, base: nil, primary: false)
      # If we're deleting the very session we're attached to, killing it would
      # eject us from switchboard (this sidebar lives inside it). Fall back to
      # the persistent home session first, then kill — "the one you're in, last".
      # Our process dies with that session, so home's own sidebar drives from
      # here (it reloads to the post-deletion tree, which git already reflects).
      deleting_current = Tmux.session_of == Tmux.session_name(worktree)
      Tmux.go_home if deleting_current
      Tmux.kill(worktree)
      reload unless deleting_current
    end

    # Rename a workspace: move its worktree directory (the display name) + rename
    # its session in place. Shares the core with `switchboard rename` via Rename
    # (issue #42); the sidebar reloads on every outcome (silent on failure, as
    # before — the tree just re-reads git truth).
    def rename
      node = current
      return unless node && node.kind == "ws"
      project = @config.project(node.project)
      return unless project

      newname = prompt_line("rename #{File.basename(node.path)} to")
      return reload if blank_input?(newname)

      # The CLI warns these to stderr; the sidebar can't (stderr would paint over
      # the TUI), so flash on the bottom row — a silent reload would leave a failed
      # rename looking like nothing happened.
      msg = rename_error(Rename.perform(@config, node.project, node.path, newname))
      flash(msg) if msg
      reload
    end

    # Bottom-row message for a non-success rename, or nil when it succeeded (the
    # reloaded tree is feedback enough; :unchanged is not an error).
    def rename_error(result)
      case result.status
      when :exists  then "already exists: #{File.basename(result.dest)}"
      when :branch_exists then "branch #{File.basename(result.dest)} already exists — pick another name"
      when :invalid then "invalid name — letters/digits/. - _, no /, and a valid git branch"
      when :partial then "renamed the dir, but the tmux session rename failed — run prune"
      when :failed  then "rename failed (git worktree move)"
      end
    end

    # Single-key y/N confirmation on the bottom row.
    def confirm(message)
      rows, = winsize
      print "\e[#{rows};1H\e[K\e[?25h#{message} [y/N] "
      $stdout.flush
      answer = read_char
      print "\e[?25l"
      answer.to_s.downcase == "y"
    end

    # Inline line prompt on the bottom row, edited in raw mode (issue #68). We stay
    # raw — never drop to cooked — so the line discipline can't swallow Esc as a
    # literal byte: Esc and Ctrl-C cancel (return nil), ↵ submits the stripped text,
    # Backspace/Ctrl-U edit. The old cooked `$stdin.gets` left the prompt with no way
    # out but a bare ↵ (undiscoverable) or killing the sidebar. Shared by a/r so
    # every name prompt cancels the same way (`n` no longer prompts — #114). The hidden cursor is restored in an
    # ensure so a raise can't strand a visible block cursor; any read fault returns
    # nil (cancel), the same graceful-degrade contract the cooked version had.
    def prompt_line(label)
      buf = +"" # collects the typed text; bare ↵ ⇒ "" ⇒ blank_input? cancels
      draw_prompt(label, buf)
      loop do
        chunk = read_prompt_key
        return nil if chunk.nil? # read fault / dead pane: cancel
        case edit_buffer(chunk, buf)
        when :cancel then return nil
        when :submit then return buf.strip # bare ↵ ⇒ "" ⇒ blank_input? cancels too
        end
        draw_prompt(label, buf)
      end
    rescue StandardError
      nil
    ensure
      print "\e[?25l"
    end

    # Fold one raw read into the name buffer, returning :submit / :cancel / :edit. A
    # read arrives as a burst — a paste (the `a` clone URL / local path), or a fast
    # key-repeat — so process it token by token the way the main loop's `handle`
    # does (escape-led tokens are 3 bytes), NOT all-or-nothing: a pasted URL must
    # land its printable bytes while an arrow burst ("\e[A") still drops whole rather
    # than leaking "[A" into the name. Cooked `gets` buffered pastes for free; raw
    # mode has to reassemble them here.
    def edit_buffer(chunk, buf)
      chunk = chunk.dup # slice! mutates; never consume the caller's (possibly frozen) read
      until chunk.empty?
        token = chunk.start_with?("\e") ? chunk.slice!(0, 3) : chunk.slice!(0, 1)
        case token
        when "\e", "\x03" then return :cancel  # bare Esc / Ctrl-C
        when "\r", "\n"   then return :submit  # ↵ (rest of a multi-line paste is dropped, like gets)
        when "\x7F", "\b" then buf.chop!       # Backspace (DEL / ^H)
        when "\x15"       then buf.clear       # Ctrl-U: clear the line
        else buf << token if printable?(token) # printable byte ⇒ name; arrow/fn bursts drop
        end
      end
      :edit
    end

    # Block for the next raw read and return its bytes — a keypress, an escape
    # sequence, or a whole paste (read big so a pasted URL lands in one go, not 8
    # bytes at a time). We're already raw, so Esc and Ctrl-C arrive as bytes here,
    # not as a swallowed control or a signal. nil on a dead pane (EOF) so prompt_line
    # cancels rather than spinning; a spurious select wakeup with nothing to read
    # retries rather than cancelling, matching read_key's no-op on the same race.
    def read_prompt_key
      IO.select([$stdin]) # block until there's something to read
      $stdin.read_nonblock(1024)
    rescue IO::WaitReadable
      retry
    rescue EOFError
      nil
    end

    # Repaint the inline prompt on the bottom row and park a real cursor right after
    # the typed text. An empty buffer shows a dim hint advertising the escape hatch
    # (issue #68); it clears the moment you type so a long name isn't crowded on the
    # narrow pane. The caret column is set explicitly so the hint can trail the input
    # without the caret jumping past it.
    def draw_prompt(label, buf)
      rows, cols = winsize
      prefix = "#{label} › "
      # The hint must live INSIDE the width budget. Truncating only prefix+buf and
      # tacking the hint on after let a long label + the hint overflow the 40-col pane;
      # the 41st char auto-wrapped (DECAWM) on the bottom row and scrolled a stale
      # prompt copy into scrollback every cancel→reopen (issue #80). Reserve the hint's
      # display width so the whole line fits — a long label is clipped while empty (the
      # hint always shows) and restored the moment you type (hint gone). Held plain for
      # the width count; the dim SGR is applied only at print time.
      hint   = buf.empty? ? " (esc cancel)" : ""
      shown  = trunc(prefix + buf, cols - hint.length)
      print "\e[#{rows};1H\e[K#{shown}#{hint.empty? ? '' : "\e[2m#{hint}\e[0m"}"
      caret = [shown.length + 1, cols].min # 1-based, parked right after the visible input
      print "\e[#{rows};#{caret}H\e[?25h"
      $stdout.flush
    end

    # An empty prompt result — nil (read failed / cancelled) or "" (bare enter) — means cancel.
    def blank_input?(text)
      text.nil? || text.empty?
    end

    # Surface an error on the bottom row and wait for a keypress, so it's
    # readable before the next repaint wipes it.
    def flash(message)
      rows, cols = winsize
      print "\e[#{rows};1H\e[K\e[31m#{trunc(message, cols - 11)}\e[0m — any key "
      $stdout.flush
      read_char
    end

    # One key in raw mode (nil if the read fails).
    def read_char
      $stdin.getc
    rescue StandardError
      nil
    end

    # --- rendering -----------------------------------------------------------

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

    def winsize
      $stdout.winsize
    rescue StandardError
      [40, 40]
    end

    # A SINGLE line: the context-sensitive nav verb + the `? help` gateway. The
    # action keys (a/n/o/O/r/d/e/R/H/q) used to be crammed into two more lines ONLY
    # because the footer was the sole place to teach them; the #62 overlay is now the
    # complete reference, so the footer sheds the tail and gives those two rows back
    # to the tree. `? help` is the always-on pointer to everything dropped — a help
    # you must already know `?` to find would be circular. One line for every row
    # kind, so the tree never reflows as the cursor moves (the nav verb swaps:
    # open/collapse/switch; the home session shows its title instead). The empty tree
    # (fresh install) shows the first-project invite in place of nav.
    def footer
      return filter_footer if @filter
      # empty tree: invite the first project (the add key resolved live, #108)
      return ["#{key_hint(:add_project)} add a project · #{help_hint}"] unless current

      # ws AND br both open the worktree session, so they read alike (NAV_WS).
      nav = current.kind == "proj" ? NAV_PROJ : NAV_WS
      ["#{@home ? HOME_TITLE : nav} · #{help_hint}"]
    end

    # The persistent "? help" gateway, the ? resolved from the live bindings so a
    # remapped help key shows correctly (issue #108).
    def help_hint
      "#{key_hint(:help)} help"
    end

    # An action's resolved key for a footer hint, falling back to its default when
    # the binding was collision-dropped (doctor reports the clash) so the hint
    # never shows a blank. This DELIBERATELY diverges from the `?` overlay, which
    # shows a `—` for a dropped binding (Keymap.help_rows): the one-line footer
    # prefers a non-blank best-effort key, while the overlay + doctor are the
    # authoritative surfaces for the rare misconfigured-collision case.
    def key_hint(action)
      @bindings[action] || Keymap::DEFAULTS[action]
    end

    # The filter-mode legend: the live query, then the in-mode keys. j/k are query
    # input here (unlike the tree, where they move), so movement is the arrows
    # / ^N^P. ↵ is context-sensitive — opens a highlighted workspace, or creates a
    # new one on a highlighted project header — so the label tracks the row. The
    # count is workspaces only (headers don't count) — it reassures you the query is
    # biting (and a 0-match query isn't a frozen pane). Three lines: filter mode is
    # live state (query + action + count), not key-teaching, so unlike the slimmed
    # one-line normal footer it keeps the room it needs; entering/leaving the mode is
    # a deliberate switch, so the height change there is fine (the tree changes too).
    def filter_footer
      n = @rows.count { |node| node.kind != "proj" }
      count = n == 1 ? "1 match" : "#{n} matches"
      action = current&.kind == "proj" ? "↵ new workspace" : "↵ open"
      ["/#{@filter}", "#{action} · esc cancel", "↑↓ ^n/^p move · #{count}"]
    end

    # The brand header above the tree. EVERY session leads with the wordmark, so the
    # name has presence beyond the footer in any pane — a minimal one-liner on a
    # focused worktree session. The HOME sidebar (switchboard's anchor, where the
    # tree is short and base-camp framing fits) additionally seats a time-of-day
    # greeting, a one-line console of what the board is handling, and a rule — and
    # the `H` toggle (@full_header, shared on disk) extends that same full header to
    # every other session. Each line carries its own ANSI and is fit to `cols`; only
    # the wordmark wears the accent.
    def header(cols)
      wordmark = "#{BRAND}#{trunc(WORDMARK, cols)}\e[0m"
      return [wordmark] unless @home || @full_header

      [
        wordmark,
        "\e[2m#{trunc(greeting, cols)}\e[0m",
        "\e[2m#{trunc(console, cols)}\e[0m",
        "\e[2m#{'─' * cols}\e[0m"
      ]
    end

    # First name for the home greeting, from git's global identity (falling back to
    # $USER), downcased to match the sidebar's lowercase voice. nil when we can't
    # tell — the greeting then drops the name. Called once, lazily, from greeting
    # (memoized there); degrades to nil on any failure, like every other shell-out here.
    def operator_name
      name = `git config user.name 2>/dev/null`.strip
      name = ENV["USER"].to_s if name.empty?
      first = name.split.first
      first && !first.empty? ? first.downcase : nil
    rescue StandardError
      nil
    end

    # Time-of-day greeting for the home header, by name when we know the operator.
    # The name is resolved once here (lazy + memoized; nil is a valid result, so the
    # uncomputed sentinel is `false`) — only a home pane that renders a greeting ever
    # shells out. The time part is recomputed each paint (cheap), tracking the clock.
    def greeting
      @operator = operator_name if @operator == false
      part = case Time.now.hour
             when 0...12  then "morning"
             when 12...18 then "afternoon"
             else              "evening"
             end
      @operator ? "good #{part}, #{@operator}" : "good #{part}"
    end

    # One-line operator console for the home header: how many workspaces the board
    # is patching, how many agents are working right now, how many PRs are open.
    # Counts the whole tree (@nodes) so a collapsed project still tallies; the
    # active/PR clauses drop when zero to keep the line calm. Terse to fit the pane.
    def console
      trees  = @nodes.count { |n| n.kind == "ws" }
      active = @agents.values.count(:thinking)
      prs    = @nodes.count { |n| n.pr.is_a?(Hash) && View.pr_state(n.pr) == "OPEN" }
      parts  = ["#{trees} #{trees == 1 ? 'worktree' : 'worktrees'}"]
      parts << "#{active} active"                       if active.positive?
      parts << "#{prs} #{prs == 1 ? 'PR' : 'PRs'} open" if prs.positive?
      parts.join(" · ")
    end

    def render
      return render_help if @help # the ? overlay replaces the tree (issue #62)

      rows, cols = winsize
      head = header(cols)
      foot = footer
      head = [] if rows - foot.size - head.size < 1 # too short to seat both — tree first
      top = head.size
      height = rows - foot.size - top
      scroll(height)

      visible = @rows[@offset, height].to_a
      @visible_rows = visible # the on-screen slice — pulsing? animates only for these
      adds_w, dels_w, pr_w = column_widths(@rows) # fixed columns, measured once (#118)
      out = +"\e[H"
      head.each_with_index do |text, i|
        out << "\e[#{i + 1};1H\e[K#{text}" # header lines carry (and reset) their own ANSI
      end
      visible.each_with_index do |node, i|
        active = @offset + i == @cursor
        out << "\e[#{top + i + 1};1H\e[K" << line(node, active, cols, adds_w: adds_w, dels_w: dels_w, pr_w: pr_w)
      end
      # Erase rows left over from a previous, longer state (e.g. after a
      # collapse), then draw the footer hints on the bottom rows.
      out << "\e[#{top + visible.size + 1};1H\e[0J"
      foot.each_with_index do |text, i|
        out << "\e[#{rows - foot.size + 1 + i};1H\e[K\e[2m#{trunc(text, cols)}\e[0m"
      end
      $stdout.write(out)
    end

    # The ? help overlay (issue #62). Paints the full key map with the same
    # cursor-addressed \e[K / \e[0J no-flash technique as render (no full \e[2J, so
    # the per-tick repaint while it's open doesn't flicker), with a dim "any key to
    # close" hint pinned to the bottom row. The body comes from help_body, capped so
    # the hint always seats.
    def render_help
      rows, cols = winsize
      lines = help_body(rows, cols)
      out = +"\e[H"
      lines.each_with_index do |text, i|
        out << "\e[#{i + 1};1H\e[K#{text}" # each line carries (and resets) its own ANSI
      end
      out << "\e[#{lines.size + 1};1H\e[0J" # erase below the last line (incl. any old footer)
      out << "\e[#{rows};1H\e[K\e[2m#{trunc('any key to close', cols)}\e[0m"
      $stdout.write(out)
    end

    # The overlay's lines, capped to leave the bottom row for the "any key to close"
    # hint. A short pane drops the tail (HELP is top-loaded with navigation), never
    # the top. Pure given winsize + @config, so the height-cap is unit-testable
    # without raw I/O — the suite keeps render-to-stdout out of scope.
    def help_body(rows, cols)
      help_lines(cols).first([rows - 1, 0].max)
    end

    # Format the key map (Keymap.help_rows, built from the live @bindings so the
    # shown keys never drift — issue #108) plus the resolved tmux rows into rendered
    # lines: the wordmark, then each section as a blank separator + bold heading, and
    # each key row as `key.ljust(HELP_KEY_COLS)  desc`. trunc runs on the PLAIN string
    # BEFORE the ANSI is wrapped on, so truncation can never cut an escape (line()).
    def help_lines(cols)
      out = ["#{BRAND}#{trunc(WORDMARK, cols)}\e[0m"]
      (Keymap.help_rows(@bindings) + tmux_help_rows).each do |key, desc|
        if key.empty?
          out << "" << "#{BRAND}#{trunc(desc, cols)}\e[0m" # blank separator, then the heading
        else
          out << trunc("#{key.ljust(HELP_KEY_COLS)}  #{desc}", cols)
        end
      end
      out
    end

    # The tmux-layer keys that operate the sidebar itself, resolved at render time
    # (the prefix is needed first, unlike the in-pane keys — the heading says so).
    # `show / hide` answers "how do I hide this whole thing?" (no in-sidebar key does
    # — q quits everything); `move between panes` surfaces the user's OWN select-pane
    # keys (Tmux.pane_switch_keys, memoized), the implicit step switchboard never
    # binds. toggle defaults to "s"; home + pane-switch rows drop when unbound/undetected.
    def tmux_help_rows
      toggle = @config.tmux_key("toggle")
      home   = @config.tmux_key("home")
      switch = (@pane_switch_keys ||= Tmux.pane_switch_keys)
      rows = [["", "tmux (operate the sidebar)"]]
      rows << ["prefix #{toggle}", "show / hide the sidebar"] if toggle
      rows << ["prefix #{switch.join(' ')}", "move between panes"] if switch.any?
      rows << ["prefix #{home}", "jump to the home session"] if home
      rows
    end

    def scroll(height)
      @offset = @cursor if @cursor < @offset
      @offset = @cursor - height + 1 if @cursor >= @offset + height
      @offset = 0 if @offset.negative?
    end

    # The three right-hand columns are a property of the whole visible row set,
    # not a single row (#118), so they're measured once here and threaded into
    # every line — letting the +adds, −dels, and #n numbers each stack into a
    # straight column. Measured over the full @rows (collapse-/filter-aware), NOT
    # the on-screen slice, so the columns stay put while you scroll instead of
    # reflowing each keypress; folding a noisy project naturally tightens them.
    # Projects carry no cells and so don't size the columns. Returns the adds /
    # dels sub-column widths and the PR column width.
    def column_widths(rows)
      adds_w = dels_w = pr_w = 0
      rows.each do |node|
        next if node.kind == "proj"

        pr_w = [pr_w, View.pr_identifier(node.pr).length].max
        adds, dels = View.diff_parts(diff_visible?(node) ? diff_for(node) : nil)
        adds_w = [adds_w, adds.to_s.length].max
        dels_w = [dels_w, dels.to_s.length].max
      end
      [adds_w, dels_w, pr_w]
    end

    # The plain width the right region reserves: the diff column (the two sub-
    # columns plus their separator, when both seat) then the PR column, with a
    # 2-col gap between them only when both are present.
    def region_width(diff_w, pr_w)
      w = diff_w + pr_w
      w += 2 if diff_w.positive? && pr_w.positive?
      w
    end

    def line(node, active, cols, adds_w: nil, dels_w: nil, pr_w: nil)
      # The flush-right region is the diff count then the PR identifier ("+22 −333
      # #12"), each right-justified into a fixed column so they stack down the
      # tree (#118). Reserve its plain width (plus a gap) so the name truncates to
      # fit rather than overrunning.
      id = node.kind == "proj" ? "" : View.pr_identifier(node.pr)
      counts = diff_visible?(node) ? diff_for(node) : nil
      adds, dels = View.diff_parts(counts) # plain "+22" / "−333", nil where zero

      # Column widths are threaded from render; single-row callers (and tests)
      # fall back to this row's own widths — a one-row column equals the row, so
      # the output is unchanged. Projects carry neither, so they get the full width.
      adds_w ||= adds.to_s.length
      dels_w ||= dels.to_s.length
      pr_w   ||= id.length
      adds_w = dels_w = pr_w = 0 if node.kind == "proj"
      diff_w = adds_w + dels_w + (adds_w.positive? && dels_w.positive? ? 1 : 0)

      # Too narrow to seat name + diff + badge? Drop the whole diff column first —
      # uniformly across rows, since cols/widths are shared, so the columns never
      # split (the badge is the more essential signal). Reachable only on a hand-
      # narrowed pane with a huge diff AND a long PR number.
      region_w = region_width(diff_w, pr_w)
      if diff_w.positive? && cols - region_w - 1 < MIN_NAME_COLS
        adds_w = dels_w = diff_w = 0
        region_w = region_width(diff_w, pr_w)
      end
      left_cols = region_w.zero? ? cols : [cols - region_w - 1, 1].max
      text = trunc(plain(node), left_cols)

      # The reverse-video cursor bar only when the sidebar is the focused pane;
      # off-focus the cursor row renders like any other, so the bright bar never
      # tugs at your eye while you're working in the pane beside it. The diff/badge
      # go plain here so they read under the inverted bar.
      if active && @focused
        right = right_region(counts, node.pr, adds_w, dels_w, pr_w, with_color: false)
        bar = region_w.zero? ? text : "#{text.ljust(left_cols)} #{right}"
        return "\e[7m#{bar.ljust(cols)}\e[0m"
      end

      body = colored(node, text, current: node.kind == "ws" && node.path == @current_path)
      return body if region_w.zero?

      # `colored` preserves `text`'s visible width, so pad off the plain region
      # width (right_region pads each cell off its plain length, then wraps ANSI).
      right_colored = right_region(counts, node.pr, adds_w, dels_w, pr_w, with_color: true)
      pad = [cols - text.length - region_w, 1].max
      "#{body}#{' ' * pad}#{right_colored}"
    end

    # The fixed-width right region: [+adds][ ][−dels]  [#pr], each (sub)cell
    # right-justified into its column so the numbers stack vertically (#118). An
    # absent cell renders as aligned blanks, not a gap that shifts its neighbor.
    # The plain cell text is re-derived from counts/pr here (not threaded) so the
    # call sites pass only the source + the cross-row widths. with_color: false
    # gives the plain form (width math / the reverse-video bar); true wraps ANSI —
    # width math stays on the plain strings either way.
    def right_region(counts, pr, adds_w, dels_w, pr_w, with_color:)
      id = View.pr_identifier(pr)
      cells = []
      cells << diff_cell(counts, adds_w, dels_w, with_color: with_color) if adds_w.positive? || dels_w.positive?
      cells << pad_cell(id, with_color ? View.pr_tag(pr) : id, pr_w) if pr_w.positive?
      cells.join("  ")
    end

    # The diff column: the adds sub-cell and dels sub-cell, each right-justified
    # into its sub-column (so +adds stack and −dels stack), joined by one space.
    def diff_cell(counts, adds_w, dels_w, with_color:)
      adds, dels = View.diff_parts(counts)
      styled_adds, styled_dels = with_color ? View.diff_tag_parts(counts) : [adds, dels]
      parts = []
      parts << pad_cell(adds, styled_adds, adds_w) if adds_w.positive?
      parts << pad_cell(dels, styled_dels, dels_w) if dels_w.positive?
      parts.join(" ")
    end

    # Right-justify one cell into its column: pad off the PLAIN string's width,
    # then emit the (possibly ANSI-wrapped) content — so color never throws the
    # width off. An empty cell becomes width spaces (the aligned blank).
    def pad_cell(text, styled, width)
      (" " * [width - text.to_s.length, 0].max) + styled.to_s
    end

    # Plain (no color) — used for the highlighted row and as the base text. The
    # ws prefix is always 4 cols ("  X ") so names line up whether or not a dot is
    # present; idle leaves the dot slot blank. The dot carries the live, uncolored
    # state glyph (`glyph_for`): under the reverse-video cursor bar color is
    # stripped but the spinner/diamond/dot SHAPE survives, so the selected row
    # still shows what its agent is doing.
    def plain(node)
      case node.kind
      when "proj"
        # In filter mode the children show regardless of fold, so the header always
        # reads expanded (▾); the ▸ collapsed glyph only applies to the normal tree.
        folded = @filter.nil? && @collapsed.include?(node.project)
        "#{folded ? '▸' : '▾'} #{node.project}"
      when "ws"   then "#{pointer(node.path)} #{ws_glyph(node.path)} #{node.name}#{fold_cue(node)}"
      else             "     #{node.last ? '└' : '├'}#{node.active ? '●' : ' '}#{node.branch}"
      end
    end

    # The " ▸N" cue trailing a folded multi-branch workspace's name — N branch rows
    # tucked away by the global `z` fold (issue #107). "" for every other row (folded
    # is only set on a fold_ws clone). Plain here for width math; colored() wraps it
    # in the dim SGR, reserving this same width off the name budget so the two paths
    # stay the same visible width (the line()/right-region alignment depends on it).
    def fold_cue(node)
      node.folded ? " ▸#{node.folded}" : ""
    end

    # The bare (uncolored) "you are here" gutter pointer for a workspace path —
    # CURRENT_MARK for the session's current workspace, a blank otherwise. Shared by
    # plain (so the marker survives under the reverse-video cursor bar, where color
    # is stripped but shape isn't); colored builds its own bold-cyan form.
    def pointer(path)
      path == @current_path ? CURRENT_MARK : " "
    end

    def colored(node, text, current: false)
      case node.kind
      when "proj" then "\e[1m#{text}\e[0m"
      when "ws"
        dot = sparkling?(node.path) ? SPARKLE_COLORED[(@pulse / 2) % SPARKLE_COLORED.size] : dot_for(@agents[node.path])
        # The " ▸N" fold cue is appended ONLY when its full width was reserved off the
        # name budget (budget >= 1 ⇒ ≥1 name col left after the cue). At a very narrow
        # pane the budget floors and there's no room: drop the cue so colored's visible
        # width matches plain's `text` (== the pre-#107 no-cue width) instead of
        # overrunning and staircasing the #118 diff/PR columns. The cue returns as the
        # pane widens; the common case is unchanged (budget large, cue always shows).
        cue = fold_cue(node)
        budget = text.length - 4 - cue.length
        cue = "" if budget < 1
        name = trunc(node.name.to_s, [budget, 1].max)
        ptr = " "
        if current
          ptr  = "#{BRAND}#{CURRENT_MARK}\e[0m"  # "you are here" pointer — bold-cyan, switchboard's signature accent
          name = "\e[36m#{name}\e[0m"            # ...and the name cyan, matching the prompt's directory color
        elsif @attention.include?(node.path)
          name = "\e[1;33m#{name}\e[0m"          # unviewed completion — bold yellow until you look (the current row is never marked)
        end
        "#{ptr} #{dot} #{name}#{cue.empty? ? '' : "\e[2m#{cue}\e[0m"}" # dim ▸N cue last, its width already reserved
      else "#{BRANCH_FG}#{text}\e[0m"
      end
    end

    # Bare state glyph for a workspace row, twinkling briefly right after the
    # agent's turn lands before it settles to the steady dot. Bare (uncolored) so
    # the shape survives under the reverse-video selected row, mirroring glyph_for.
    def ws_glyph(path)
      return SPARKLE_GLYPHS[(@pulse / 2) % SPARKLE_GLYPHS.size] if sparkling?(path)

      glyph_for(@agents[path])
    end

    # Bare state glyph (no color), the single source for both render paths. The
    # spinner cycles through SPIN_FRAMES on @pulse; the diamond blinks filled/
    # hollow every BLINK_PERIOD ticks; done is steady; idle is a blank slot.
    def glyph_for(state)
      case state
      when :thinking then SPIN_FRAMES[@pulse % SPIN_FRAMES.size]
      when :waiting  then (@pulse / BLINK_PERIOD).even? ? "◆" : "◇"
      when :done     then "●"
      else " "
      end
    end

    # Colored state glyph for a normal (non-selected) row. Mirrors glyph_for in
    # palette ANSI; thinking indexes the pre-built SPIN_COLORED so there's no
    # per-frame string allocation.
    def dot_for(state)
      case state
      when :thinking then SPIN_COLORED[@pulse % SPIN_COLORED.size]
      when :waiting  then (@pulse / BLINK_PERIOD).even? ? WANTS_ON : WANTS_OFF
      when :done     then DONE
      else " "
      end
    end

    def trunc(str, width)
      str = str.to_s
      return "" if width <= 0

      str.length > width ? "#{str[0, width - 1]}…" : str
    end
  end
end
