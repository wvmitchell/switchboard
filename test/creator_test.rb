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

    # A stale rename bridge (a symlink) squatting the target name must be reclaimed,
    # not read as "already exists" — create clears it, then makes the worktree.
    def test_create_reclaims_a_stale_bridge_squatting_the_name
      config = config_for(temp_git_repo("proj", origin: true))
      dest = File.join(config.worktree_root, "proj", "reused")
      FileUtils.mkdir_p(File.dirname(dest))
      File.symlink(path("target-long-gone"), dest) # dangling bridge at the target name
      out = Creator.create(config, "proj", "reused")
      assert_equal dest, out
      refute File.symlink?(dest), "the stale bridge is cleared"
      assert File.directory?(dest)
      assert_equal "reused", Git.current_branch(dest)
    end

    def test_create_unknown_project_is_nil
      config = config_for(temp_git_repo("proj", origin: true))
      capture_io { assert_nil Creator.create(config, "nope", "x") }
    end

    # No name given -> a faker placeholder workspace + a real branch matching it (#94).
    def test_create_with_blank_name_generates_a_placeholder
      config = config_for(temp_git_repo("proj", origin: true))
      dest = Creator.create(config, "proj", "")
      refute_nil dest
      leaf = File.basename(dest)
      assert_match(/\A[a-z]+-[a-z]+\z/, leaf, "an adjective-noun placeholder leaf")
      assert File.directory?(dest)
      assert_equal leaf, Git.current_branch(dest), "branch matches the leaf (no prefix here)"
    end

    # A generated name already taken by a DIR is skipped; generation retries (#94).
    def test_create_placeholder_retries_past_a_taken_dir
      config = config_for(temp_git_repo("proj", origin: true))
      Creator.create(config, "proj", "taken") # occupies dir + branch "taken"
      names = %w[taken free]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        dest = Creator.create(config, "proj", "")
        assert_equal File.join(config.worktree_root, "proj", "free"), dest
      end
    end

    # A generated name whose BRANCH exists (even with no dir) fails `worktree add`;
    # generation retries to a free name rather than giving up (#94).
    def test_create_placeholder_retries_past_a_branch_only_collision
      repo = temp_git_repo("proj", origin: true)
      config = config_for(repo)
      git(repo, "branch", "branchonly") # a branch with no worktree dir
      names = %w[branchonly free2]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        dest = Creator.create(config, "proj", "")
        assert_equal File.join(config.worktree_root, "proj", "free2"), dest
      end
    end

    # Hooks (incl. the #92 nudge) are wired when auto_rename is on, even if the
    # agent-state dots are off — so the nudge works without dots.
    def test_create_wires_hooks_when_auto_rename_on_even_with_dots_off
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "agent_state_hooks" => false, "auto_rename" => true,
                                        "projects" => [{ "name" => "proj", "path" => temp_git_repo("proj", origin: true) }]))
      dest = Creator.create(Config.new, "proj", "thing")
      assert Hook.enabled?(dest), "hooks wired because auto_rename is on"
    end

    # A PER-PROJECT auto_rename:true (global off, dots off) must still wire the hook —
    # else the runtime nudge (which resolves auto_rename_for(project)) never has a hook
    # to fire from, and the project override silently does nothing.
    def test_create_wires_hooks_for_a_per_project_auto_rename_opt_in
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "agent_state_hooks" => false, "auto_rename" => false,
                                        "projects" => [{ "name" => "proj", "auto_rename" => true,
                                                         "path" => temp_git_repo("proj", origin: true) }]))
      dest = Creator.create(Config.new, "proj", "thing")
      assert Hook.enabled?(dest), "per-project auto_rename:true wires the hook even with global off"
    end

    # The inverse override: global auto_rename:true but this project opts OUT — no hook
    # (with dots also off), matching what auto_rename_for resolves at runtime.
    def test_create_skips_hooks_for_a_per_project_auto_rename_opt_out
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "agent_state_hooks" => false, "auto_rename" => true,
                                        "projects" => [{ "name" => "proj", "auto_rename" => false,
                                                         "path" => temp_git_repo("proj", origin: true) }]))
      dest = Creator.create(Config.new, "proj", "thing")
      refute Hook.enabled?(dest), "per-project auto_rename:false skips the hook despite global on"
    end

    def test_create_skips_hooks_when_dots_and_auto_rename_both_off
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "agent_state_hooks" => false,
                                        "projects" => [{ "name" => "proj", "path" => temp_git_repo("proj", origin: true) }]))
      dest = Creator.create(Config.new, "proj", "thing")
      refute Hook.enabled?(dest), "no hooks when both dots and auto_rename are off"
    end

    # The branch created off origin/main must NOT inherit it as an upstream
    # (--no-track), so rename's pushed? gate (whose @{upstream} arm would otherwise
    # see origin/main) doesn't misread a fresh worktree as pushed (#94).
    def test_create_branch_has_no_upstream_and_reads_unpushed
      config = config_for(temp_git_repo("proj", origin: true))
      Creator.create(config, "proj", "fresh")
      repo = config.project("proj")["path"]
      refute Git.tracking_upstream?(repo, "fresh"), "--no-track ⇒ origin/main not inherited as upstream"
      refute Git.pushed?(repo, "fresh"), "a freshly-created branch reads as not-pushed"
    end
  end
end
