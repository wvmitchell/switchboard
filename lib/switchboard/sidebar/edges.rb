# frozen_string_literal: true

module Switchboard
  class Sidebar
    # The agent-edge fanout (extracted from the Sidebar body in #57; the
    # behavior is issue #19 + its twins). Each scan hands on_scan the fresh
    # hook states; it diffs them against the sticky baseline it owns and fans
    # the completion edges out to every consumer: the bold "needs attention"
    # marker, the completion sound, the on-row twinkle, and the debounced
    # background PR refresh. The state driving that — the baseline, the
    # sparkle deadlines, and the per-project spawn clock — lives HERE and
    # nowhere else, so the subtle rules (the announce_sounds catch-up gate,
    # first-appearance-seeds-baseline, the ensure that a raise can't corrupt)
    # are testable without constructing a Sidebar. Everything else arrives per
    # call — deliberately: the sidebar REASSIGNS @config on a config reload,
    # so capturing it at construction would silently pin stale sound/project
    # settings.
    class Edges
      # Background PR-badge refresh (issue #19): event-driven, never blocks the UI.
      PR_DEBOUNCE = 5          # min seconds between background refreshes per project
      BACKSTOP_TTL = 120       # idle fallback: refresh a project staler than this. Kept
                               # short (2 min) because a PR merged/closed *on GitHub* fires
                               # no local trigger — this backstop, riding the ~15s visible
                               # reloads, is what eventually catches it (R forces it now).
      MAX_SPAWN_PER_RELOAD = 3 # cap backstop spawns per reload (cold-home fan-out)

      SPARKLE_SECS = 3.0       # wall-clock lifetime of a twinkle before it settles to DONE

      # Paths whose agent state newly entered a resting state (:done/:waiting) since
      # the previous scan — i.e. a hooked agent just finished a turn. A path we've
      # never seen before (prev has no key for it) is the agent *announcing
      # presence*, not completing: SessionStart reports :done the instant a
      # freshly-created workspace's Claude is ready, and that must NOT ring the
      # completion sound (or spawn a PR refresh for a branch that has no PR yet). So
      # a first appearance only seeds the baseline; the next real Stop is the edge.
      # The caller keeps `prev` sticky across scans (on_scan merges), so
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

      def initialize
        @prev_hook_states = nil # last scan's hook states; nil until the first scan
        @prev_notify = {}       # worktree path => last-seen notify-marker mtime; the per-process
                                # cursor that makes a declared `monitoring notify` ring once (twin
                                # of @prev_hook_states, but for the alert channel)
        @sparkles = {}          # worktree path => monotonic deadline of an active completion
                                # twinkle; the sidebar's pulsing? keeps animating until it
                                # lapses (sparkling?)
        @pr_spawned = {}        # project => monotonic of its last background PR refresh
      end

      # T1 — a hooked agent just reached a resting state (finished a turn / asked
      # for input). Four consumers ride the same edge: a bold "needs attention"
      # marker (the visual twin of the dot, persisted so it survives until viewed), a
      # background PR refresh (it may have pushed a branch / opened a PR), a
      # completion sound (the audible twin), and a brief on-row twinkle (its visual
      # twin — same announce_sounds gate as the sound). `now` is the hook-only state
      # snapshot (never the activity fallback, which flips every 3s and would fire
      # on noise). Skips the first scan — no baseline to diff.
      #
      # Ordering + isolation are load-bearing: the mark and PR refresh run first
      # (the mark fully rescued; the PR fan-out is the ONE unrescued consumer —
      # see the return-path note below), and @prev_hook_states ALWAYS advances
      # (ensure) so a raise here can't corrupt the next edge diff — even when it
      # trips the caller's broad refresh_agents rescue into blanking the dots
      # for one scan.
      #
      # Deliberate post-#57 ordering note: the sound/sparkle fire BEFORE the
      # caller's diff recount now (pre-split the recount ran between the PR
      # spawn and the sound) — the completion signal no longer waits on git.
      #
      # announce_sounds gates the sound and its twinkle, not the mark, the PR refresh,
      # or the baseline advance. A catch-up scan (switch-in / reappear) passes false: each sidebar
      # is its own process with its own baseline, frozen while off-screen, so without
      # this it would re-ring every completion that finished while it slept (already
      # heard from the sidebar that was on screen then). PRs still refresh — debounced
      # and idempotent — and the baseline still advances, so the next real completion
      # scanned while we're here rings normally.
      #
      # Returns the edge list ([] on the first scan) — the caller rides it for the
      # diff-count refresh (a finished turn likely just committed). The announce/
      # mark consumers are individually rescued so their faults can't eat the
      # return; refresh_prs_for is the one unrescued consumer, so a fault there
      # raises past us (the fault-path test pins exactly this) — and the ensure
      # still advances the baseline either way.
      #
      # `offstage` ({ path => pid }) and `idle` (Set) are the session evidence for the ◷
      # hold (ClaudeSessions.activity): a :done edge on a path whose session still reads
      # `busy` (a background agent — ClaudeSessions::HANDOFF_STATUS) is a hand-off, so it's HELD (OffstageHold) instead of ringing, and the
      # hold rings later from settle_holds. Both default empty: no evidence, today's chime.
      # `sessions_ok` false means the session read failed: no evidence either way, so
      # nothing releases a hold on it.
      def on_scan(now, monitoring:, nodes:, config:, current_path:,
                  notify_pending: {}, first_turn: Set.new, announce_sounds: true, refresh_prs: true,
                  offstage: {}, idle: Set.new, sessions_ok: true)
        edges = []
        if @prev_hook_states
          edges = self.class.completion_edges(@prev_hook_states, now)
          # A monitored worktree's routine :done is not a "come look, I'm done" event —
          # drop it from the human-facing signals (bold, sound, sparkle) so a background
          # loop doesn't chime and bold every tick. :waiting still surfaces (it wants
          # input), and the PR/diff refresh rides EVERY edge (a tick may have committed).
          completions = edges.reject { |path| suppress_completion?(path, now[path], monitoring, first_turn) }
          # A :done whose session still reads `busy` handed work to a background agent: hold
          # its chime + bold (a background shell rings now — it may never end). Written by EVERY scan (warm and
          # catch-up too), because whichever pane is on screen when the work finishes
          # rings it, and that pane may not be this one. A hold that failed to land rings
          # now instead: early beats never.
          handoffs = completions.select { |path| now[path] == :done && offstage.key?(path) && hold(path, offstage[path]) }
          completions -= handoffs
          # Bold rides the un-suppressed COMPLETIONS only. A declared alert's bold is written
          # directly into Attention by the CLI (so it persists even when no sidebar is on
          # screen), so it's NOT re-marked here — one source of truth, and no viewing?-skip drift.
          mark_attention_for(completions, current_path)
          refresh_prs_for(edges, nodes) if refresh_prs # warm suppresses the off-screen PR-spawn fan-out
          if announce_sounds
            # A declared "come look" alert (`monitoring notify`): its marker mtime is newer
            # than our per-process cursor. An INDEPENDENT alert channel, NOT a hook edge — it
            # may fire mid-:thinking, with no Stop. It only rings + sparkles here; the diff
            # refresh still rides the hook `edges` (returned below), never the alert.
            forced = notify_pending.select { |p, m| (prev = @prev_notify[p]).nil? || m > prev }.keys
            alerted = completions | forced
            # :alert is STRICTLY LOCAL to sound/sparkle: a throwaway states map, never merged
            # into `now` (which advances @prev_hook_states) or the returned `edges` (which the
            # diff refresh rides) or render_state (which reads @agents). It only picks the alert
            # sound/glyph for a forced path whose real hook state is :thinking/absent — but NOT
            # if that path ALSO has a live :waiting edge this scan (an input request is more
            # urgent than a routine alert, and already owns its chime + blink): let :waiting win.
            overrides = forced.reject { |p| now[p] == :waiting }.to_h { |p| [p, :alert] }
            states = overrides.empty? ? now : now.merge(overrides)
            play_sounds_for(alerted, states, nodes, config)
            sparkle_for(alerted, states)
          end
          release_rung_holds(completions, now) if announce_sounds && sessions_ok
        end
        settle_holds(now, nodes, offstage: offstage, idle: idle, current_path: current_path,
                                 announce: announce_sounds, config: config)
        edges
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
        # The notify cursor advances EVERY scan (catch-up included), so a switch-in scan
        # re-baselines a while-away alert silently instead of re-ringing it. Absent from
        # notify_pending => no marker => no entry, so it stays bounded by notified worktrees.
        @prev_notify.merge!(notify_pending)
      end

      # This pane's last-known hook state for `path` (sticky past PRESENCE_TTL, unlike
      # AgentState's fresh view) — what keeps ◷ up through a long background job.
      def last_state(path)
        (@prev_hook_states || {})[path]
      end

      # The baseline as a code reload hands it to the new process (#48, D1): the sticky
      # hook states and the notify cursor. Without them a worktree quiet past PRESENCE_TTL
      # would read as a first appearance, and its completion would ring nowhere.
      def baseline
        { hook_states: @prev_hook_states || {}, notify: @prev_notify.dup }
      end

      # Seed from a reload's carried baseline, before the first scan. An empty one stays nil
      # (the first scan only baselines, as for a fresh process) unless the old image had
      # `scanned`: a pane with no hooked worktree carries `{}`, and its first scan must still
      # ring a `monitoring notify` newer than the carried cursor. The caller passes the
      # payload's announce: it's set only after an announcing scan, which also advanced the
      # notify cursor, so a first scan that announces always has a cursor to compare against.
      # Seeding on every resume wouldn't guarantee that. It lasts one hop: a reload before
      # this image's first scan hands over announce false.
      def restore_baseline(hook_states:, notify:, scanned: false)
        @prev_hook_states = hook_states.dup if scanned || !hook_states.empty?
        @prev_notify.merge!(notify)
      end

      # One background-dispatch ping: the sound (your :done sound, or the soft falling
      # :failed for a ✘) and, for a success, the twinkle. The ring decision itself is the record's
      # compare-and-set (Sidebar#ring_creations); this only voices it.
      def announce(path, project, state, config)
        Sound.play(config.sound_for(project, state))
        sparkle_for([path], { path => state }) unless state == :failed
      rescue StandardError
        nil
      end

      # Is `path` mid-twinkle? Deadlines are wall-clock (monotonic), NOT pulse units —
      # the sidebar's @pulse only crawls while a pane is off-screen, so a
      # pulse-denominated deadline would survive ~48s hidden and replay the twinkle
      # on switch-back. Once passed, drop the entry so @sparkles stays bounded and
      # the dot settles. Self-GCing.
      def sparkling?(path)
        deadline = @sparkles[path]
        return false unless deadline
        return true if deadline > monotonic

        @sparkles.delete(path)
        false
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

      # T3 — idle backstop: refresh any project whose badges have gone stale past
      # BACKSTOP_TTL — the ~2-min net that catches a PR merged/closed on GitHub
      # (which fires no local trigger) when nothing else does. Capped at
      # MAX_SPAWN_PER_RELOAD so opening home on a cold cache doesn't launch one gh
      # per project at once; the rest catch up on later reloads.
      def refresh_stale_prs(config)
        config.projects
              .map { |p| p["name"] }
              .select { |name| Pr.stale?(name, BACKSTOP_TTL) }
              .first(MAX_SPAWN_PER_RELOAD)
              .each { |name| maybe_refresh_prs(name) }
      rescue StandardError
        nil
      end

      private

      # Edge paths -> a bold "needs attention" marker each, except the workspace
      # you're already sitting in (you're watching it finish — no nudge needed). The
      # marker is persistent disk state, so unlike the sound it rides EVERY scan
      # (continuous and catch-up alike, no announce_sounds gate): which process
      # writes it doesn't matter, every sidebar reads the same file and bolds the row
      # until you view it (locate clears it). Fully rescued — never disturbs the scan.
      def mark_attention_for(edges, current_path)
        edges.each { |path| Attention.mark(path) unless viewing?(path, current_path) }
      rescue StandardError
        nil
      end

      # The single predicate the sound + bold + sparkle all consult: a monitored
      # worktree's :done is a routine loop tick, not a completion, so it's suppressed
      # from every human-facing signal. Only :done — :waiting is an actionable request
      # for input and always surfaces, even mid-monitor.
      #
      # A dispatched task's first turn is suppressed the same way: its Creation record
      # owns that ping (it can't be lost between scans, and a fresh workspace's first
      # appearance would swallow the edge anyway), so the edge stands aside until that
      # ping has rung or you've viewed the workspace (D16).
      def suppress_completion?(path, state, monitoring, first_turn = Set.new)
        state == :done && (monitoring.include?(path) || first_turn.include?(path))
      end

      def hold(path, pid)
        OffstageHold.hold(path, pid: pid)
      rescue StandardError
        nil
      end

      # A normal :done this (announcing) scan just rang is that worktree's turn ending,
      # so a hold another pane wrote for it inside the done-before-idle race would ring
      # the same end twice. Only the ringing pane drops it: a silent pane that sees the
      # edge late (after the work finished) would take the only ring with it.
      def release_rung_holds(completions, now)
        completions.each { |path| OffstageHold.release(path) if now[path] == :done }
      rescue StandardError
        nil
      end


      # Resolve every held ◷ chime. A follow-up turn (the hook left :done) releases it
      # silently: that turn's own Stop rings normally. Only an announcing scan releases —
      # an off-screen pane can catch a short follow-up turn the on-screen pane's scans
      # miss, and then nothing would ring; left held, it matures for the on-screen pane
      # (late, if no pane was on screen through the follow-up — a TODOS.md item).
      # Otherwise it matures only on EVIDENCE — the session reads a settled `idle`, or
      # the busy session's process is gone — never on missing evidence (a failed scan,
      # an unreadable file or pid keeps holding). A mature hold rings only from an
      # on-screen announcing scan, which claims it first (one unlink wins across every
      # pane); other scans leave it for that pane. The bold rides the claim too: an
      # off-screen pane marking it could re-bold a workspace you just viewed, in the
      # moment before the on-screen pane claims. Fully rescued.
      def settle_holds(now, nodes, offstage:, idle:, current_path:, announce:, config:)
        paths = nodes.select { |n| n.kind == "ws" }.map(&:path)
        OffstageHold.held(paths).each do |path, held|
          state = now.fetch(path) { (@prev_hook_states || {})[path] }
          if state && state != :done
            OffstageHold.release(path) if announce
            next
          end
          next if offstage.key?(path)
          next unless idle.include?(path) || (held[:pid] && !ProcessIdentity.alive?(held[:pid]))
          next unless announce && OffstageHold.claim(path)

          mark_attention_for([path], current_path)
          play_sounds_for([path], { path => :done }, nodes, config)
          sparkle_for([path], { path => :done })
        end
      rescue StandardError
        nil
      end

      # Is the sidebar currently sitting in this worktree? Canonicalizes both sides —
      # edge paths come realpath'd from the hook, current_path raw from git.
      def viewing?(path, current_path)
        return false unless current_path

        Attention.same_path?(path, current_path)
      end

      # Edge paths -> owning projects -> debounced PR refresh (deduped per project).
      def refresh_prs_for(edges, nodes)
        edges.filter_map { |path| project_for_path(nodes, path) }.uniq
             .each { |project| maybe_refresh_prs(project) }
      end

      # Edge paths -> a completion sound each. completion_edges returns distinct
      # paths, so this is one sound per [worktree, state]: every worktree's
      # completion is heard, but a worktree can't double-fire in one scan. Fully
      # rescued — a sound fault never disturbs the scan or the PR refresh above.
      def play_sounds_for(edges, states, nodes, config)
        edges.each { |path| Sound.play(config.sound_for(project_for_path(nodes, path), states[path])) }
      rescue StandardError
        nil
      end

      # Edge paths -> a brief completion twinkle each — the visual twin of the sound,
      # so it rides the same announce_sounds gate: only the sidebar you're watching
      # twinkles (a catch-up scan re-baselines silently and still). Only :done
      # sparkles — :waiting already blinks for attention. The deadline is wall-clock
      # (monotonic) so it expires in real time even while the pane is hidden — no stale
      # replay on switch-back; the sidebar's pulsing? keeps the loop animating while
      # it's live, then sparkling? GCs it. Fully rescued — a fault never disturbs
      # scan, sound, or refresh.
      def sparkle_for(edges, states)
        deadline = monotonic + SPARKLE_SECS
        edges.each { |path| @sparkles[path] = deadline if %i[done alert].include?(states[path]) }
      rescue StandardError
        nil
      end

      # The project owning a worktree path (over the ws nodes), or nil. The
      # sidebar keeps an ivar-reading twin for its T2 trigger — change the
      # matching rule in both or they drift.
      def project_for_path(nodes, path)
        nodes.find { |n| n.kind == "ws" && n.path == path }&.project
      end

      # Own private clock — threading `now:` values through every signature above
      # would widen the seam for no behavioral gain (#57 review, D10).
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
