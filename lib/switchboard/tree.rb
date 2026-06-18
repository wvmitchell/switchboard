# frozen_string_literal: true

module Switchboard
  # Builds the flat list fzf renders as a project -> worktree -> branch tree.
  # A worktree with more than one branch in its history expands into inline
  # child rows you cycle with the normal arrow keys — no second picker.
  module Tree
    module_function

    # Cap how many branches a workspace expands to; dedicated worktrees are
    # short-lived, but we never want a runaway list.
    MAX_BRANCHES = 8

    def lines(model)
      model.projects.flat_map do |project|
        rows = [View.project_row(project)]
        # The canonical/trunk checkout is never a switch target.
        project.worktrees.reject(&:primary).each do |worktree|
          rows << View.workspace_row(worktree)
          branches = lineage(worktree)
          next unless branches.size > 1

          branches.each_with_index do |branch, i|
            rows << View.branch_row(
              worktree.path, branch, model.pr_for(branch),
              project: project.name, active: branch == worktree.branch, last: i == branches.size - 1
            )
          end
        end
        rows
      end
    end

    def lineage(worktree)
      (Git.branch_history(worktree.path, limit: MAX_BRANCHES) | [worktree.branch].compact)
    end
  end
end
