# frozen_string_literal: true

module Switchboard
  # Rename a workspace: move its worktree directory (the display name), rename its
  # branch when that's safe (#94), rename its tmux session in place, and (inside tmux)
  # start the worker that renames its live Claude session too. The shared core behind both front-ends — the
  # sidebar `r` key (Sidebar#rename) and the `switchboard rename` CLI verb
  # (issue #42) — so a running agent can (re)name its own live workspace.
  #
  # A pushed or diverged branch is left as-is so its PR link stays intact. No UI
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
  #   :building  the workspace is still being created; nothing moved
  #   :partial   the dir moved but a *reachable* session's rename failed — the
  #              dir is the source of truth, so this is recoverable (prune reaps
  #              the orphan), but the caller should say so rather than claim :ok
  #
  # `spawned` is true when a session-name worker was started (see SessionName).
  module Rename
    module_function

    Result = Struct.new(:status, :dest, :spawned)

    def perform(config, project_name, old_path, newname)
      sync_session_name(config, project_name, move(config, project_name, old_path, newname))
    end

    # The rename itself; `perform` adds the session-name sync on top.
    def move(config, project_name, old_path, newname)
      project = config.project(project_name)
      return Result.new(:failed) unless project
      # The worker still holds the old path for its session and launch line; renaming
      # under it would orphan that session and later start a second agent.
      return Result.new(:building) unless Creation.renamable?(Creation.for_path(old_path))

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
      # old_path, not dest: on a case-only rename the dir keeps its old case, and the session
      # name must match the dir.
      # Not when `dest` is a symlink: renaming back onto the bridge an earlier rename left
      # (A->B, then B->A) resolves to old_path too, but it's a real move.
      return Result.new(:unchanged, old_path) if dest == old_path || (!File.symlink?(dest) && File.identical?(dest, old_path))
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

      # Carry the shared per-worktree markers (bold, monitoring, a held ◷ chime) to the new realpath, so a
      # rename doesn't drop them — all are keyed by realpath, which just changed. Notify is
      # CLEARED, not carried: its marker can't distinguish a pending alert from a consumed one
      # (consumption is a per-process mtime cursor, not on disk), so carrying it would replay
      # a false "come look" chime under the new path. The bold (Attention) is the durable
      # signal and IS carried, so a truly-pending alert survives visually; clearing also
      # disposes of the old-realpath marker the bridge symlink would otherwise keep alive.
      new_real = canonical(dest)
      Attention.carry(old_real, new_real)
      Monitoring.carry(old_real, new_real)
      OffstageHold.carry(old_real, new_real)
      Notify.clear(old_real)
      SessionName::Outcome.forget(old_real) # about the old name; this rename's worker judges afresh
      Creation.repath(old_path, old_real, dest) # a dispatch the agent renamed on turn one still pings

      Result.new(rename_session(project_name, old_path, dest), dest)
    end

    # Start the detached worker that types `/rename <leaf>` into the workspace's live
    # agent session once that's safe. Only inside tmux — the worker drives tmux, and the
    # offline suite (no TMUX) can never launch a real switchboard from a rename test. A
    # same-name rename spawns too: it's the retry doctor points at.
    def sync_session_name(config, project_name, result)
      return result unless %i[ok partial unchanged].include?(result.status)
      return result unless ENV["TMUX"] && config.sync_session_name_for(project_name)
      return result unless File.basename(result.dest).match?(SessionName::NAME) # the worker would refuse it

      bin = ENV["SWITCHBOARD_BIN"] or return result
      # Its own process group: an agent's tool runner that kills the rename command's group
      # on return can't take the worker down before it daemonizes.
      Process.detach(Process.spawn(bin, "sync-session-name", result.dest, File.basename(result.dest),
                                   pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL))
      result.spawned = true
      result
    rescue SystemCallError
      result
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
