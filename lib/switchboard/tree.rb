# frozen_string_literal: true

module Switchboard
  # Builds the flat project -> worktree -> branch list the sidebar renders as a
  # tree. A worktree with more than one branch in its history expands into
  # inline child rows you cycle with the normal arrow keys.
  module Tree
    module_function

    # Cap how many branches a workspace expands to; dedicated worktrees are
    # short-lived, but we never want a runaway list.
    MAX_BRANCHES = 8

    # Structured tree node — what the rendered sidebar draws.
    Node = Struct.new(:kind, :project, :path, :branch, :name, :pr, :dirty, :base, :active, :last,
                      :expanded, keyword_init: true)

    # Flat, ordered list of Nodes: project header, its workspaces, and a
    # workspace's branches (when it has more than one).
    def nodes(model, branch_cache: nil)
      model.projects.flat_map do |project|
        list = [Node.new(kind: "proj", project: project.name, path: project.path)]
        project.worktrees.reject(&:primary).each do |wt|
          branches = lineage(wt, branch_cache)
          expanded = branches.size > 1
          # When a workspace expands into per-branch rows, the PR badge belongs on the
          # branch row that owns it. The current branch's PR is wt.pr, so showing it on
          # the workspace row too would render the same #number twice. A single-branch
          # workspace keeps the badge on its row — the only place it can show. The diff
          # count rides the same logic (#90): the sidebar suppresses it on an expanded
          # ws row (the active branch row carries the identical base...HEAD count).
          list << Node.new(kind: "ws", project: project.name, path: wt.path, branch: wt.branch,
                           name: wt.display_name, pr: expanded ? nil : wt.pr, dirty: wt.dirty,
                           base: wt.base, expanded: expanded)
          next unless expanded

          branches.each_with_index do |branch, i|
            list << Node.new(kind: "br", project: project.name, path: wt.path, branch: branch,
                             pr: model.pr_for(branch), base: wt.base, active: branch == wt.branch,
                             last: i == branches.size - 1)
          end
        end
        list
      end
    end

    def lineage(worktree, branch_cache = nil)
      (Git.branch_history(worktree.path, limit: MAX_BRANCHES, cache: branch_cache) | [worktree.branch].compact)
    end
  end
end
