# frozen_string_literal: true

module Switchboard
  # What deleting a workspace and quitting switchboard do, for both front-ends. The confirms
  # and flashes stay in the sidebar, and the prints stay in the CLI.
  module Workspaces
    module_function

    # Tear down every sb/ session. Returns the sessions it killed. Cancels first: an in-flight
    # build must not open a session after the kill.
    def quit_all
      Creation.cancel_all
      AgentState.clear_all    # killing every agent makes their last hook state stale — drop it now
      Monitoring.clear_all    # ...and every monitoring declaration is now stale too
      Notify.clear_all        # ...and any pending "come look" alert is moot once the agents are gone
      OffstageHold.clear_all  # ...and any held ◷ chime: the background work it waited on died with them
      PendingDelete.clear_all # ...and any in-flight delete's row-hide (the daemon still finishes the removal)
      Tmux.kill_all
    end

    # Remove a worktree and the branches that go with it. `branches:` is what you confirmed
    # deleting with the workspace, and a failed removal keeps them all. Without it (a canceled
    # dispatch, an older caller) `delete_branch` is the safe `-d`: git refuses a still-checked-out
    # or unmerged branch, even after a failed removal. `force_branch:` is for a
    # dispatched tree already proven untouched (nothing past its base): a placeholder branch
    # never reads as merged into your local base, so the safe -d would leak one per canceled build.
    #
    # Like `switchboard delete`, it writes a receipt first and, once git no longer lists the
    # tree, forgets everything switchboard kept for it (Deletion.forget), so a reaper killed
    # mid-delete is finished by the next delete or prune. The removal stays forced: `d`'s
    # confirm already accepted a dirty tree.
    def remove!(repo, path, branch, force_branch: false, branches: nil)
      real = Paths.real_or_self(path)
      receipt = reaper_receipt(repo, path, real, branches)
      removed = Git.remove_worktree(repo, path, force: true, locked: Creation.unfinished_at?(path))
      trees = Git.worktrees(repo, strict: true)
      gone = removed && trees && trees.none? { |w| Paths.real_or_self(w[:path]) == real }
      unless gone
        DeleteReceipt.delete(real) if receipt && trees # verified still there: nothing to recover
        return branches ? nil : Git.delete_branch(repo, branch, force: force_branch)
      end

      out = Deletion.forget(receipt || receipt_fields(repo, path, real, branches))
      Git.delete_branch(repo, branch, force: force_branch) unless branches
      DeleteReceipt.delete(real) if out.failed.empty?
      report_kept(out.kept)
    end

    def reaper_receipt(repo, path, real, branches)
      receipt = receipt_fields(repo, path, real, branches)
      DeleteReceipt.write(receipt) ? receipt : nil
    end

    # The reaper's argv carries no project or record (it's a cross-version contract), so
    # both are found here, before the folder goes.
    def receipt_fields(repo, path, real, branches)
      repo_real = Paths.real_or_self(repo)
      project = Config.new.projects.find { |p| p["path"] && Paths.real_or_self(p["path"]) == repo_real }
      rec = Creation.for_path(real)
      name = project ? Worktree.new(project: project["name"], path: path).display_name : File.basename(path)
      { "path" => path, "real" => real, "project" => project&.dig("name").to_s, "repo" => repo, "name" => name,
        "record" => rec&.dig("id"), "token" => rec&.dig("token"), "server" => Creation.current_server,
        "branches" => (branches || []).map { |e| "#{e.sha}:#{e.name}" }, "phase" => "removed", "deleted" => [] }
        .merge(DeleteReceipt.owner)
    end

    # Runs after the row is gone, often from a daemon, so tmux is the only place to say so.
    def report_kept(kept)
      names = kept.select { |k| k.start_with?("branch ") }.map { |k| k.split(" ", 3)[1] }
      return if names.empty?

      Tmux.notify_everyone("switchboard: kept branch #{names.join(', ')} (in use or changed)", display_time: Tmux.display_time)
    end
  end
end
