# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Creator.create end-to-end against a real repo: it must make the worktree +
  # branch under worktree_root, guard the obvious failure modes, and — the bug
  # this suite added — never let a name escape the worktree root.
  class CreatorTest < SandboxTest
    # Config registering `proj` -> a real repo with an origin/main to branch from.
    def config_for(repo, name: "proj")
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => name, "path" => repo }]))
      Config.new
    end

    def test_create_makes_a_worktree_and_branch
      config = config_for(temp_git_repo("proj", origin: true))
      dest = Creator.create(config, "proj", "my feature")
      refute_nil dest
      assert_equal File.join(config.worktree_root, "proj", "my-feature"), dest
      assert File.directory?(dest)
      assert_equal "my-feature", Git.current_branch(dest)
    end

    def test_create_honors_branch_prefix
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "branch_prefix" => "wv",
                                        "projects" => [{ "name" => "proj", "path" => temp_git_repo("proj", origin: true) }]))
      dest = Creator.create(Config.new, "proj", "thing")
      assert_equal "wv/thing", Git.current_branch(dest)
    end

    # The headline bug: a traversal name must be neutralized, not honored.
    def test_create_neutralizes_path_traversal
      config = config_for(temp_git_repo("proj", origin: true))
      dest = Creator.create(config, "proj", "../../escape")
      refute_nil dest
      assert_equal File.join(config.worktree_root, "proj", "escape"), dest
      assert dest.start_with?("#{File.join(config.worktree_root, 'proj')}/"),
             "the worktree must stay inside the project's worktree dir"
    end

    # The other traversal axis (Codex): an explicit project name can carry
    # traversal too; the worktree must still land under worktree_root.
    def test_create_neutralizes_a_traversal_project_name
      repo = temp_git_repo("proj", origin: true)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "../escape", "path" => repo }]))
      dest = Creator.create(Config.new, "../escape", "ws")
      refute_nil dest
      assert dest.start_with?("#{path('wts')}/"),
             "a traversal project name must not escape worktree_root"
    end

    def test_create_rejects_a_name_that_sanitizes_to_empty
      config = config_for(temp_git_repo("proj", origin: true))
      capture_io { assert_nil Creator.create(config, "proj", "..") }
    end

    def test_create_refuses_to_clobber_an_existing_worktree
      config = config_for(temp_git_repo("proj", origin: true))
      Creator.create(config, "proj", "dup")
      capture_io { assert_nil Creator.create(config, "proj", "dup") }
    end

    def test_create_unknown_project_is_nil
      config = config_for(temp_git_repo("proj", origin: true))
      capture_io { assert_nil Creator.create(config, "nope", "x") }
    end
  end
end
