# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # What a created worktree IS, end-to-end against a real repo: its branch, where it
  # lands, the agent hooks it gets, and how placeholder names avoid collisions. Every
  # create is a background dispatch now, so these drive the real path — reserve a name,
  # then the worker (tmux stubbed; creator_dispatch_test covers the lifecycle itself).
  class CreatorTest < SandboxTest
    def config_for(repo, name: "proj", **extra)
      File.write(Config.path, YAML.dump({ "worktree_root" => path("wts"),
                                          "projects" => [{ "name" => name, "path" => repo }] }.merge(extra)))
      Config.new
    end

    # Reserve + run the worker with tmux stubbed out; returns the built worktree path
    # (nil when the build failed).
    def build(config, project = "proj")
      name, dest = Creator.reserve(config, project)
      return nil unless dest

      rec = Creation.create(project: project, name: name, path: dest, task: "")
      stub_method(Tmux, :ensure_session, ->(*) { true }) do
        stub_method(Tmux, :ensure_sidebar, ->(_n) {}) do
          stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
            stub_method(Creator, :await_claim, ->(*_a, **_k) { true }) { Creator.work(config, rec["id"]) }
          end
        end
      end
      found = Creation.find(rec["id"])
      found["worktree_added"] ? found["path"] : nil
    end

    def test_build_makes_a_placeholder_worktree_and_matching_branch
      config = config_for(temp_git_repo("proj", origin: true))
      dest = build(config)
      refute_nil dest
      leaf = File.basename(dest)
      assert_match(/\A[a-z]+-[a-z]+\z/, leaf, "an adjective-noun placeholder leaf")
      assert_equal File.join(config.worktree_root, "proj", leaf), dest
      assert_equal leaf, Git.current_branch(dest), "branch matches the leaf (no prefix here)"
    end

    def test_build_honors_branch_prefix
      config = config_for(temp_git_repo("proj", origin: true), "branch_prefix" => "wv")
      dest = build(config)
      assert_equal "wv/#{File.basename(dest)}", Git.current_branch(dest)
    end

    # A trailing slash on the prefix once built "wv//name" — an invalid ref that failed
    # `worktree add`. The prefix is normalized.
    def test_build_tolerates_a_trailing_slash_on_branch_prefix
      config = config_for(temp_git_repo("proj", origin: true), "branch_prefix" => "wv/")
      dest = build(config)
      refute_nil dest
      assert_equal "wv/#{File.basename(dest)}", Git.current_branch(dest)
    end

    # An explicit project name can carry traversal (`switchboard add ../x …`); the
    # worktree must still land under worktree_root.
    def test_build_neutralizes_a_traversal_project_name
      config = config_for(temp_git_repo("proj", origin: true), name: "../escape")
      dest = build(config, "../escape")
      refute_nil dest
      assert dest.start_with?("#{path('wts')}/"), "a traversal project name must not escape worktree_root"
    end

    def test_reserve_unknown_project_is_nil
      config = config_for(temp_git_repo("proj", origin: true))
      assert_nil Creator.reserve(config, "nope")
    end

    # A generated name already taken by a DIR is skipped (#94).
    def test_reserve_retries_past_a_taken_dir
      config = config_for(temp_git_repo("proj", origin: true))
      FileUtils.mkdir_p(File.join(config.worktree_root, "proj", "taken"))
      names = %w[taken free]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        assert_equal "free", Creator.reserve(config, "proj").first
      end
    end

    # A rename leaves a bridge symlink at the old placeholder path; once its target is
    # deleted it dangles — !File.exist? — yet still blocks `worktree add`. Skip it.
    def test_reserve_skips_a_dangling_rename_bridge
      config = config_for(temp_git_repo("proj", origin: true))
      FileUtils.mkdir_p(File.join(config.worktree_root, "proj"))
      File.symlink(path("long-gone"), File.join(config.worktree_root, "proj", "bridged"))
      names = %w[bridged clear]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        assert_equal "clear", Creator.reserve(config, "proj").first
      end
    end

    # A leftover sb/ session of the same name would make ensure_session early-return and
    # swallow the launch line, so a name with a live session is skipped too.
    def test_reserve_skips_a_name_with_a_leftover_session
      config = config_for(temp_git_repo("proj", origin: true))
      names = %w[stale-one fresh-one]
      stub_method(Placeholder, :generate, -> { names.shift }) do
        stub_method(Tmux, :has_session?, ->(name) { name == "sb/proj/stale-one" }) do
          assert_equal "fresh-one", Creator.reserve(config, "proj").first
        end
      end
    end

    # --- the agent hooks a new worktree gets ---------------------------------------
    # Wired for ANY agent (typed by hand or not) whenever dots, auto_rename or
    # background_presence is on — each resolved per project.

    def test_build_wires_hooks_when_auto_rename_on_even_with_dots_off
      config = config_for(temp_git_repo("proj", origin: true), "agent_state_hooks" => false, "auto_rename" => true)
      dest = build(config)
      assert ClaudeHook.enabled?(dest), "claude hook wired because auto_rename is on"
      refute File.exist?(File.join(dest, ".codex", "hooks.json")), "codex is global; no per-worktree file"
    end

    def test_build_wires_hooks_with_no_session_command_at_all
      config = config_for(temp_git_repo("proj", origin: true))
      dest = build(config)
      assert ClaudeHook.enabled?(dest), "an agent started by hand still gets its dot and nudges"
    end

    def test_build_wires_hooks_for_a_per_project_auto_rename_opt_in
      repo = temp_git_repo("proj", origin: true)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "agent_state_hooks" => false,
                                        "auto_rename" => false,
                                        "projects" => [{ "name" => "proj", "auto_rename" => true, "path" => repo }]))
      assert ClaudeHook.enabled?(build(Config.new)), "per-project auto_rename:true wires the hook with the global off"
    end

    def test_build_skips_hooks_for_a_per_project_auto_rename_opt_out
      repo = temp_git_repo("proj", origin: true)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "agent_state_hooks" => false,
                                        "auto_rename" => true, "background_presence" => false,
                                        "projects" => [{ "name" => "proj", "auto_rename" => false, "path" => repo }]))
      refute ClaudeHook.enabled?(build(Config.new)), "per-project auto_rename:false skips the hook despite global on"
    end

    def test_build_skips_hooks_when_dots_rename_and_presence_all_off
      config = config_for(temp_git_repo("proj", origin: true), "agent_state_hooks" => false,
                                                                 "auto_rename" => false, "background_presence" => false)
      refute ClaudeHook.enabled?(build(config))
    end

    def test_build_wires_the_hook_for_background_presence_alone
      config = config_for(temp_git_repo("proj", origin: true), "agent_state_hooks" => false,
                                                                 "auto_rename" => false, "background_presence" => true)
      assert ClaudeHook.enabled?(build(config)), "the monitoring nudge + session-boundary clears need it"
    end

    # The branch cut from origin/main must NOT inherit it as an upstream (--no-track), so
    # rename's pushed? gate doesn't misread a fresh worktree as pushed (#94).
    def test_build_branch_has_no_upstream_and_reads_unpushed
      config = config_for(temp_git_repo("proj", origin: true))
      branch = File.basename(build(config))
      repo = config.project("proj")["path"]
      refute Git.tracking_upstream?(repo, branch), "--no-track ⇒ origin/main not inherited as upstream"
      refute Git.pushed?(repo, branch), "a freshly-created branch reads as not-pushed"
    end

    # --- sanitize (shared with rename) ----------------------------------------------

    def test_sanitize_neutralizes_traversal
      assert_equal "etc", Creator.sanitize("../../etc")
      assert_equal "tmp/x", Creator.sanitize("/tmp/x")
      assert_equal "", Creator.sanitize("..")
      assert_equal "my-feature", Creator.sanitize("my feature")
    end
  end
end
