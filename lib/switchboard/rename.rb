# frozen_string_literal: true

module Switchboard
  # Rename a workspace: move its worktree directory (the display name) and rename
  # its tmux session in place. The shared core behind both front-ends — the
  # sidebar `r` key (Sidebar#rename) and the `switchboard rename` CLI verb
  # (issue #42) — so a running agent can (re)name its own live workspace.
  #
  # The branch is left as-is so its PR link and git identity stay intact. No UI
  # here: callers own the prompt / reload / messages. The result is a status the
  # caller maps to output:
  #
  #   :ok        moved + session renamed (or no session to rename — clientless)
  #   :unchanged the name didn't change (rename to the current leaf)
  #   :invalid   the name sanitizes to empty, carries a "/", or isn't a valid branch
  #   :exists    a real dir already sits at the target
  #   :branch_exists a branch by the target name already exists (a lingering branch
  #              from a deleted workspace) — nothing moved; pick another name (#94)
  #   :failed    the git worktree move failed (or the project is unknown)
  #   :partial   the dir moved but a *reachable* session's rename failed — the
  #              dir is the source of truth, so this is recoverable (prune reaps
  #              the orphan), but the caller should say so rather than claim :ok
  module Rename
    module_function

    Result = Struct.new(:status, :dest)

    def perform(config, project_name, old_path, newname)
      project = config.project(project_name)
      return Result.new(:failed) unless project

      name = Creator.sanitize(newname)
      # Reject a "/" the sanitizer preserves: a slashed name would nest the dir
      # while Tmux.session_name / Worktree#leaf only see the basename, so the
      # session and sidebar would silently disagree with the path. Agents type
      # branch-style names (feature/auth), so this is the likely CLI input.
      return Result.new(:invalid) if name.empty? || name.include?("/")

      dest = File.join(File.dirname(old_path), name)
      # Same target ⇒ nothing to do. File.identical? also catches a case-only
      # rename (Old -> old) on a case-insensitive FS (macOS APFS), where the two
      # names ARE the same dir and git worktree move can't separate them — so it's
      # "unchanged", not a collision or a failure. (A case-only change therefore
      # also doesn't sync the branch — an accepted edge; see #94.)
      return Result.new(:unchanged, dest) if dest == old_path || File.identical?(dest, old_path)
      # A real dir blocks the move; a stale rename-bridge symlink does not
      # (move_worktree clears it first), so only a non-symlink counts as taken.
      return Result.new(:exists, dest) if File.exist?(dest) && !File.symlink?(dest)

      sync = sync_branch?(project["path"], old_path)
      # All branch checks BEFORE any dir move / history migrate, so a collision or
      # invalid name fails clean (nothing moved) and the agent can retry with another
      # name. Branch is renamed FIRST so a branch failure aborts before we touch the
      # dir or transcripts (#94).
      if sync
        new_branch = branch_for(config, name)
        return Result.new(:invalid, dest) unless Git.valid_branch_name?(new_branch)
        return Result.new(:branch_exists, dest) if Git.branch_exists?(project["path"], new_branch)
        return Result.new(:failed, dest) unless Git.rename_branch(project["path"], sync, new_branch)
      end

      # Capture the canonical OLD path before the move: move_worktree leaves a bridge
      # symlink at old_path resolving to dest, so realpath(old_path) AFTER the move
      # returns dest — carrying the markers post-move would key off the wrong path.
      old_real = canonical(old_path)

      # bridge: leave a symlink at the old path so a running agent's frozen
      # project dir keeps resolving and its hooks keep reporting (see move_worktree).
      unless Git.move_worktree(project["path"], old_path, dest, bridge: true)
        # The dir move failed after the branch was renamed — put the branch back so
        # the dir and branch can't diverge, then report the failure. Best-effort: if
        # this rollback ALSO fails (a racing process took the old name), the dir keeps
        # the old leaf on the new branch — a rare double-fault we accept rather than
        # loop; a later rename sees the mismatch and just won't re-sync the branch.
        Git.rename_branch(project["path"], branch_for(config, name), sync) if sync
        return Result.new(:failed, dest)
      end

      # Carry the agent's conversation history to the new path so `/resume` still
      # finds it after a restart — the cwd just changed out from under it (#42).
      ClaudeHistory.migrate(old_path, dest)

      # Carry the shared per-worktree markers (bold, monitoring) to the new realpath,
      # so a rename doesn't drop them — both are keyed by realpath, which just changed.
      new_real = canonical(dest)
      Attention.carry(old_real, new_real)
      Monitoring.carry(old_real, new_real)

      Result.new(rename_session(project_name, old_path, dest), dest)
    end

    # File.realpath, degrading to the raw path on a vanished/odd path — a best-effort
    # canonical key for the marker carry (a bad path just misses a carry, never raises).
    def canonical(path)
      File.realpath(path)
    rescue StandardError
      path
    end

    # The branch to rename, or false when the branch should be left alone. We sync
    # the branch to match the new leaf only when it's still the auto-created branch
    # (its basename equals the old leaf) AND it hasn't been pushed — renaming a
    # pushed branch would orphan its remote ref / PR. `pushed?` checks a
    # remote-tracking ref, NOT @{upstream} (worktree add auto-tracks the base) (#94).
    def sync_branch?(repo, old_path)
      branch = Git.current_branch(old_path)
      return false if branch.empty?
      return false unless File.basename(branch) == File.basename(old_path)
      return false if Git.pushed?(repo, branch)

      branch
    end

    # The convention-correct branch for a leaf: <branch_prefix>/<leaf>, or bare
    # <leaf> when no prefix is configured. The workspace dir stays the bare leaf.
    def branch_for(config, name)
      [config.branch_prefix, name].compact.join("/")
    end

    # Rename the session in place (don't kill it) so a running agent and its
    # conversation survive. Returns :ok when there was nothing to rename (same
    # name, or no live session — a clientless rename from a plain shell) or the
    # rename succeeded; :partial only when a session genuinely existed and the
    # rename failed, so the caller can distinguish "fine" from "orphaned".
    def rename_session(project_name, old_path, dest)
      old_name = Tmux.session_name(Worktree.new(project: project_name, path: old_path))
      new_name = Tmux.session_name(Worktree.new(project: project_name, path: dest))
      return :ok if old_name == new_name
      return :ok unless Tmux.has_session?(old_name) # no session yet / no server — not a failure

      Tmux.rename_session(old_name, new_name) ? :ok : :partial
    end
  end
end
