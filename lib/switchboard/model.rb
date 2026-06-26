# frozen_string_literal: true

module Switchboard
  # A single worktree, the unit you switch between. `branch` is the live HEAD
  # (git truth); the display name is the worktree's directory leaf.
  Worktree = Struct.new(:project, :path, :branch, :dirty, :pr, :base, :primary, keyword_init: true) do
    def leaf
      File.basename(path)
    end

    def display_name
      leaf
    end
  end

  Project = Struct.new(:name, :path, :base_ref, :worktrees, keyword_init: true)

  # Assembles the project -> worktree tree from switchboard's own config (git
  # for truth, gh for PR badges). No emdash/Conductor database at runtime.
  class Model
    def initialize(config = Config.new, with_dirty: true)
      @config = config
      @prs = {}                # project name => { branch => pr }; keyed per project
                               # so two repos sharing a branch name don't collide (#66)
      @with_dirty = with_dirty # the sidebar skips the per-worktree git status
    end

    def projects
      @projects ||= @config.projects.filter_map do |row|
        next unless Dir.exist?(row["path"])

        Project.new(
          name: row["name"], path: row["path"], base_ref: row["base_ref"],
          worktrees: build_worktrees(row)
        )
      end
    end

    # PR for a branch within a project (cached map, accumulated as projects build).
    # Keyed by (project, branch), not bare branch: two registered projects can both
    # have a `feature/foo`, and a flat branch-keyed map let the second to load shadow
    # the first — rendering the wrong repo's badge on a branch row (issue #66). `dig`
    # is nil-safe for an unknown project.
    def pr_for(project, branch)
      projects # ensure the map is populated
      @prs.dig(project, branch)
    end

    private

    def build_worktrees(project)
      prs = Pr.for_project(project["name"])
      @prs[project["name"]] = prs # this project's branch->PR map, under its own key

      Git.worktrees(project["path"]).reject { |w| w[:bare] }.map do |w|
        branch = w[:branch] || Git.current_branch(w[:path])
        Worktree.new(
          project: project["name"],
          path: w[:path],
          branch: branch,
          dirty: @with_dirty ? Git.dirty?(w[:path]) : false,
          pr: prs[branch],
          base: project["base_ref"],
          primary: w[:path] == project["path"]
        )
      end
    end
  end
end
