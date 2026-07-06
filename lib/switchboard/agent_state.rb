# frozen_string_literal: true

require "shellwords"

module Switchboard
  # Per-worktree agent state for the sidebar dots. Two presence signals, either
  # of which means "an agent is here":
  #   hook state — what Claude Code reported via sb-agent-hook (exact, instant).
  #                A recent report IS presence: the hook only fires from inside
  #                the worktree, so we don't second-guess presence with a process
  #                scan (the agent's process cwd can differ from its project dir).
  #                ONE exception: a fresh :thinking. No hook fires when you
  #                interrupt a turn (Esc/Ctrl-C), so a stale :thinking would spin
  #                for the full TTL after a cancel. So a fresh :thinking is
  #                corroborated against its work pane (pane_delta) — Claude's TUI
  #                animates while working and freezes at the prompt, so a pane gone
  #                static means the report is stale and the dot rests. Fail-safe:
  #                anything but a POSITIVE static reading keeps the :thinking.
  #   process    — Agents.active (tmux/pgrep) for hook-less agents (codex/aider,
  #                or Claude before `enable-hooks`); their state is the coarser
  #                busy/idle `activity` read of the pane.
  #
  # Returns Hash<worktree_path, :thinking|:done|:waiting>; absent = idle (no dot).
  # A hook report counts only while fresh (PRESENCE_TTL) so a closed agent's last
  # state ages out; the process scan covers a still-running idle agent past that.
  class AgentState
    STATES = %w[thinking done waiting].freeze
    PRESENCE_TTL = 900 # seconds a hook report counts as a live agent
    STALE_GC = 86_400 # seconds; a still-existing-dir state file older than this is reaped (global codex hook hygiene)
    STATIC_MIN_AGE = 2.0 # seconds a work pane must hold identical content before a :static
                         # verdict — below REFRESH, above a rapid poke/reload rescan gap, so a
                         # sub-second re-scan can't misread a still-animating pane as idle

    # Hook-derived states from the last scan (path => state), excluding the
    # coarse activity fallback. The sidebar's PR-refresh edge trigger reads this
    # so it only fires on the exact hook signal, never the 3s capture-hash guess.
    attr_reader :last_hook_states

    def initialize
      @seen = {} # pane_id => [last capture hash, monotonic when that content first appeared]
      @last_hook_states = {}
    end

    # Where the reporter drops <state>\t<cwd>\t<epoch> files. Resolved from ENV on
    # every read (not frozen at load) so tests can redirect it per-example, and so
    # it tracks the exact precedence the hook sh-script uses: SWITCHBOARD_STATE_DIR,
    # else XDG_STATE_HOME, else ~/.local/state.
    def self.state_dir
      File.expand_path(
        ENV["SWITCHBOARD_STATE_DIR"] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", "agents")
      )
    end

    # Wipe every hook-state file. Called on `quit`: tearing down all sb/ sessions
    # kills every agent at once, so their last-reported states are now stale — a
    # lingering :thinking would otherwise read as a live, working agent for up to
    # PRESENCE_TTL after the process is gone (you'd have to /resume to clear it).
    # Per-file isolated and fully rescued; a restarted agent re-reports its state
    # on SessionStart, so an over-eager wipe self-heals.
    def self.clear_all
      Dir.glob(File.join(state_dir, "*")).each do |file|
        File.delete(file) if File.file?(file)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # worktree_paths -> Hash<path, state>. Only worktrees with an agent appear.
    # hooks_only skips the Agents.active (tmux/pgrep/lsof) fallback entirely — the
    # warm-render path passes it so an off-screen sidebar stays cheap; hook-less /
    # activity-based dots just defer their freshness to the next visible scan.
    def scan(worktree_paths, hooks_only: false)
      hooks = read_hooks
      process = nil # Agents.active, fetched lazily (skipped entirely if all hooked / hooks_only)
      panes = nil
      hook_states = {} # the hook-only subset, stashed for last_hook_states
      states = worktree_paths.each_with_object({}) do |wt, out|
        state = fresh_hook(wt, hooks)
        if state == :thinking && !hooks_only && pane_delta(wt, panes ||= Tmux.work_panes) == :static
          # A fresh :thinking whose work pane has gone STATIC is a stale report —
          # the agent was interrupted / walked away (no Stop fires on Esc/Ctrl-C).
          # Render it resting (:done) but keep it OUT of hook_states, so the
          # completion edge (which rides hook_states only) rings no false chime —
          # exactly like the activity fallback below. Anything but :static falls
          # through to trust the hook (pane changed / no single pane / off-screen).
          out[wt] = :done
        elsif state
          out[wt] = hook_states[wt] = state
        elsif !hooks_only && (process ||= Agents.active(worktree_paths)).include?(wt)
          out[wt] = activity(wt, panes ||= Tmux.work_panes)
        end
      end
      @last_hook_states = hook_states
      states
    end

    private

    # Per-scan access to the resolved state dir — delegates to ::state_dir so the
    # read path and the teardown wipe (clear_all) always agree on the location.
    def state_dir
      self.class.state_dir
    end

    # Hook files: one line "<state>\t<cwd>\t<epoch>", keyed by the canonicalized
    # cwd as [state, age]. A fully-formed line whose worktree no longer exists is
    # garbage-collected so the dir can't grow without bound. Requiring all three
    # fields keeps a torn mid-write read from ever deleting a live worktree's file
    # — it just gets skipped for this cycle. Keying by realpath (not the raw cwd)
    # collapses two reports that resolve to the same dir into one entry, freshest
    # kept: a rename leaves a bridge symlink (old -> new) so a running agent's
    # frozen project dir keeps resolving, which aliases its stale pre-move file
    # and its fresh post-move file onto the same worktree.
    def read_hooks
      now = Time.now.to_i
      Dir.glob(File.join(state_dir, "*")).each_with_object({}) do |file, h|
        state, cwd, epoch = File.read(file).chomp.split("\t", 3)
        next unless state && cwd && epoch && STATES.include?(state)

        unless Dir.exist?(cwd)
          File.delete(file)
          next
        end

        key = real(cwd)
        age = now - epoch.to_i
        # Age-based GC: the global codex hook reports from EVERY dir codex runs in (not
        # just switchboard worktrees), so an existing-dir file long past use would linger
        # forever on the dir-exists GC alone. Drop anything older than STALE_GC. `age >`
        # (not `.abs`) so a future-epoch/backward-clock file isn't reaped as stale.
        if age > STALE_GC
          File.delete(file)
          next
        end

        h[key] = [state.to_sym, age] if !h.key?(key) || age < h[key][1]
      rescue StandardError
        next
      end
    rescue StandardError
      {}
    end

    # Deepest hook cwd at or under the worktree wins (agent launched in a subdir),
    # but only if its report is still fresh. Keys are already canonicalized
    # (read_hooks), so we only canonicalize the worktree — a symlinked worktree
    # root still matches the hook's physical `pwd -P`.
    def fresh_hook(worktree, hooks)
      wt = real(worktree)
      cwd = hooks.keys.select { |c| under?(c, wt) }.max_by(&:length)
      return nil unless cwd

      state, age = hooks[cwd]
      state if age.abs <= PRESENCE_TTL # abs so a backward clock step (future epoch) still ages out
    end

    # Did `worktree`'s agent WORK pane change since the last scan? The three-way
    # answer the coarse fallback (activity) and the :thinking corroboration share:
    #   :changed | :static | :unknown (no single pane, no baseline, failed capture,
    #                                   or content not yet held long enough to trust)
    # The pane is found by worktree PATH, not command — an agent's
    # pane_current_command is unreliable (Claude reports its version). Requires
    # EXACTLY ONE non-sidebar candidate; 0 or >1 (multi-window / extra shell) is
    # :unknown, so the caller trusts the hook rather than hash the wrong pane. A
    # :static verdict additionally requires the content to have held identical for
    # >= STATIC_MIN_AGE — so a sub-REFRESH rescan (a PR-poke, an action reload)
    # landing a fraction of a second after the last can't misread a still-animating
    # pane (two equal frames 0.3s apart) as idle. Age is measured from when the
    # content FIRST appeared, so a burst of rapid rescans can't keep resetting it.
    def pane_delta(worktree, panes)
      wt = real(worktree)
      under = panes.select { |_id, path| under?(real(path), wt) }
      return :unknown unless under.one?

      id, = under.first
      now = capture_hash(id)
      return :unknown if now.nil? # a FAILED capture is indistinguishable from static by value,
      #                             so treat it as "can't tell" — never downgrade on a tmux hiccup

      prev = @seen[id] # [hash, monotonic-when-this-content-first-appeared], nil on first sighting
      if prev.nil? || prev[0] != now
        @seen[id] = [now, monotonic] # new content (or first sighting): stamp when it appeared
        return prev.nil? ? :unknown : :changed
      end
      # Same content as last scan: only "static" once it has held long enough that a
      # working pane's animated TUI would have moved; else keep trusting the hook.
      monotonic - prev[1] >= STATIC_MIN_AGE ? :static : :unknown
    end

    # Coarse busy/idle for a hook-less agent: pane changed since last scan ->
    # thinking, else done. A missing pane / first sighting both read done (as
    # before). Can't tell "wants input" from "done" without hooks -> never :waiting.
    def activity(worktree, panes)
      pane_delta(worktree, panes) == :changed ? :thinking : :done
    end

    # A hash of the pane's visible content, or nil when the capture failed/was empty.
    # nil (not a constant like "".hash / 0) so pane_delta can tell a genuine read from
    # a tmux hiccup — else two failed captures would compare equal and read as static.
    def capture_hash(pane_id)
      out = `tmux capture-pane -p -t #{Shellwords.escape(pane_id)} 2>/dev/null`
      $?.success? && !out.empty? ? out.hash : nil
    rescue StandardError
      nil
    end

    # Monotonic clock (a seam the tests stub) — pane_delta measures how long a work
    # pane has held identical content against it. Monotonic, not wall-clock, so an
    # NTP/DST step can't make a just-seen pane read as long-static.
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def under?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def real(path)
      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
