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
      def on_scan(now, monitoring:, nodes:, config:, current_path:,
                  announce_sounds: true, refresh_prs: true)
        edges = []
        if @prev_hook_states
          edges = self.class.completion_edges(@prev_hook_states, now)
          # A monitored worktree's routine :done is not a "come look, I'm done" event —
          # drop it from the human-facing signals (bold, sound, sparkle) so a background
          # loop doesn't chime and bold every tick. :waiting still surfaces (it wants
          # input), and the PR/diff refresh rides EVERY edge (a tick may have committed).
          notify = edges.reject { |path| suppress_completion?(path, now[path], monitoring) }
          mark_attention_for(notify, current_path)
          refresh_prs_for(edges, nodes) if refresh_prs # warm suppresses the off-screen PR-spawn fan-out
          if announce_sounds
            play_sounds_for(notify, now, nodes, config)
            sparkle_for(notify, now)
          end
        end
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
      def suppress_completion?(path, state, monitoring)
        state == :done && monitoring.include?(path)
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
      def play_sounds_for(edges, now, nodes, config)
        edges.each { |path| Sound.play(config.sound_for(project_for_path(nodes, path), now[path])) }
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
      def sparkle_for(edges, now)
        deadline = monotonic + SPARKLE_SECS
        edges.each { |path| @sparkles[path] = deadline if now[path] == :done }
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
