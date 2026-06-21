# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # Model assembles the project -> worktree tree from Config + Git + the Pr cache.
  # Real repo, real config, sandboxed PR cache. (realpath the repo so the config
  # path matches git's physical worktree path on macOS, where /var symlinks /private/var.)
  class ModelTest < SandboxTest
    def config_for(repo, name: "app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => name, "path" => repo }]))
      Config.new
    end

    def test_builds_projects_and_flags_the_primary_checkout
      repo = File.realpath(temp_git_repo("app"))
      model = Model.new(config_for(repo))
      projects = model.projects
      assert_equal 1, projects.size
      assert_equal "app", projects[0].name
      wts = projects[0].worktrees
      assert_equal 1, wts.size
      assert wts[0].primary, "the repo's own checkout is the primary"
      assert_equal "main", wts[0].branch
    end

    def test_skips_projects_whose_directory_is_missing
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "gone", "path" => path("nope") }]))
      assert_empty Model.new(Config.new).projects
    end

    def test_pr_for_is_nil_without_a_cache
      model = Model.new(config_for(File.realpath(temp_git_repo("app"))))
      assert_nil model.pr_for("main")
    end

    # Exercises the Pr cache read end-to-end (cache_file under the sandboxed
    # SWITCHBOARD_CACHE_DIR) feeding Model.pr_for.
    def test_pr_for_reads_the_pr_cache
      model = Model.new(config_for(File.realpath(temp_git_repo("app"))))
      FileUtils.mkdir_p(Pr.cache_dir)
      File.write(Pr.cache_file("app"), JSON.dump("main" => { "identifier" => "#7", "status" => "OPEN" }))
      assert_equal "#7", model.pr_for("main")["identifier"]
    end
  end
end
