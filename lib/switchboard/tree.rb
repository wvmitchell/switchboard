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

    # Structured tree node — what the rendered sidebar draws (the fzf picker
    # uses the string-based `lines` instead).
    Node = Struct.new(:kind, :project, :path, :branch, :name, :pr, :dirty, :active, :last,
                      keyword_init: true)

    # Flat, ordered list of Nodes: project header, its workspaces, and a
    # workspace's branches (when it has more than one).
    def nodes(model)
      model.projects.flat_map do |project|
        list = [Node.new(kind: "proj", project: project.name, path: project.path)]
        project.worktrees.reject(&:primary).each do |wt|
          list << Node.new(kind: "ws", project: project.name, path: wt.path, branch: wt.branch,
                           name: wt.display_name, pr: wt.pr, dirty: wt.dirty)
          branches = lineage(wt)
          next unless branches.size > 1

          branches.each_with_index do |branch, i|
            list << Node.new(kind: "br", project: project.name, path: wt.path, branch: branch,
                             pr: model.pr_for(branch), active: branch == wt.branch,
                             last: i == branches.size - 1)
          end
        end
        list
      end
    end

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
