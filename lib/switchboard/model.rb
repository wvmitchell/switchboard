# frozen_string_literal: true

module Switchboard
  # A single worktree, the unit you switch between. `branch` is the live HEAD
  # (git truth), `name` is emdash's friendly label when we can recover it.
  Worktree = Struct.new(:project, :path, :branch, :head, :name, :dirty, :pr, :base, :primary, keyword_init: true) do
    def leaf
      File.basename(path)
    end

    def display_name
      name || branch || leaf
    end
  end

  Project = Struct.new(:id, :name, :path, :base_ref, :worktrees, keyword_init: true)

  # Assembles the project -> worktree tree: git for truth, emdash for enrichment.
  class Model
    def initialize(emdash = Emdash.new)
      @emdash = emdash
    end

    def projects
      @projects ||= @emdash.projects.filter_map do |row|
        next unless Dir.exist?(row["path"])

        Project.new(
          id: row["id"], name: row["name"], path: row["path"], base_ref: row["base_ref"],
          worktrees: build_worktrees(row)
        )
      end
    end

    # Flat list across all projects — what the picker consumes.
    def worktrees
      projects.flat_map(&:worktrees)
    end

    def find(path)
      worktrees.find { |w| w.path == path }
    end

    def project_at(path)
      projects.find { |p| p.path == path }
    end

    def pr_for(branch)
      @emdash.prs[branch]
    end

    private

    def build_worktrees(project)
      Git.worktrees(project["path"]).reject { |w| w[:bare] }.map do |w|
        branch = w[:branch] || Git.current_branch(w[:path])
        Worktree.new(
          project: project["name"],
          path: w[:path],
          branch: branch,
          head: w[:head],
          name: @emdash.task_names[branch] || @emdash.task_by_leaf[File.basename(w[:path])],
          dirty: Git.dirty?(w[:path]),
          pr: @emdash.prs[branch],
          base: project["base_ref"],
          primary: w[:path] == project["path"]
        )
      end
    end
  end
end
