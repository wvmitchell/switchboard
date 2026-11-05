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
    # or unmerged branch, so it's a no-op when the removal failed. `force_branch:` is for a
    # dispatched tree already proven untouched (nothing past its base): a placeholder branch
    # never reads as merged into your local base, so the safe -d would leak one per canceled build.
    def remove!(repo, path, branch, force_branch: false, branches: nil)
      removed = Git.remove_worktree(repo, path, force: true, locked: Creation.unfinished_at?(path))
      return Git.delete_branch(repo, branch, force: force_branch) unless branches

      WorkspaceBranches.delete_and_report(repo, branches) if removed
    end
  end
end
