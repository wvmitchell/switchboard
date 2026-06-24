# frozen_string_literal: true

require "shellwords"

module Switchboard
  # Per-worktree agent state for the sidebar dots. Two presence signals, either
  # of which means "an agent is here":
  #   hook state — what Claude Code reported via sb-agent-hook (exact, instant).
  #                A recent report IS presence: the hook only fires from inside
  #                the worktree, so we don't second-guess it with a process scan
  #                (the agent's process cwd can differ from its project dir, e.g.
  #                when a wrapper launches it elsewhere — then the scan misses it).
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

    # Hook-derived states from the last scan (path => state), excluding the
    # coarse activity fallback. The sidebar's PR-refresh edge trigger reads this
    # so it only fires on the exact hook signal, never the 3s capture-hash guess.
    attr_reader :last_hook_states

    def initialize
      @seen = {} # pane_id => last capture hash, for the activity fallback
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
    def scan(worktree_paths)
      hooks = read_hooks
      process = nil # Agents.active, fetched lazily (skipped entirely if all hooked)
      panes = nil
      hook_states = {} # the hook-only subset, stashed for last_hook_states
      states = worktree_paths.each_with_object({}) do |wt, out|
        state = fresh_hook(wt, hooks)
        if state
          out[wt] = hook_states[wt] = state
        elsif (process ||= Agents.active(worktree_paths)).include?(wt)
          out[wt] = activity(wt, panes ||= Agents.tmux_panes)
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

    # Pane content changed since the last scan -> thinking, else done. Can't tell
    # "wants input" apart from "done" without hooks, so it never returns :waiting.
    def activity(worktree, panes)
      wt = real(worktree)
      id, = panes.find { |_id, path| under?(real(path), wt) }
      return :done unless id

      now = capture_hash(id)
      changed = @seen.key?(id) && @seen[id] != now
      @seen[id] = now
      changed ? :thinking : :done
    end

    def capture_hash(pane_id)
      `tmux capture-pane -p -t #{Shellwords.escape(pane_id)} 2>/dev/null`.hash
    rescue StandardError
      0
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
