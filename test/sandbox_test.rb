# frozen_string_literal: true

require_relative "test_helper"
require "set"

module Switchboard
  class SandboxTest_Sandbox < SandboxTest
    # --- sandbox_env: the full wall-off (F4/F8) ------------------------------

    def test_sandbox_env_redirects_everything_into_throwaway
      env = Sandbox.sandbox_env("/tmp/sbx9-x", "/tmp/sbx9-x/state", "/my/checkout")
      set = env[:set]

      %w[SWITCHBOARD_CONFIG SWITCHBOARD_STATE_DIR SWITCHBOARD_ATTENTION_DIR
         SWITCHBOARD_COLLAPSE_DIR SWITCHBOARD_FULL_HEADER_FILE SWITCHBOARD_BRANCH_FOLD_FILE
         SWITCHBOARD_WIDTH_FILE SWITCHBOARD_CACHE_DIR SWITCHBOARD_CLAUDE_PROJECTS_DIR
         XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
         GIT_CONFIG_GLOBAL GH_CONFIG_DIR].each do |k|
        assert set[k].start_with?("/tmp/sbx9-x/state"), "#{k} escaped the throwaway tree: #{set[k]}"
      end

      assert_equal "/tmp/sbx9-x", set["TMUX_TMPDIR"]
      assert_equal "/my/checkout/bin/switchboard", set["SWITCHBOARD_BIN"]
      assert_equal "1", set["SWITCHBOARD_SANDBOX"]
      assert_equal File::NULL, set["GIT_CONFIG_SYSTEM"]

      # #145: claude's self-updater guards — both set (belt-and-suspenders). NOT paths,
      # so asserted here, outside the throwaway-path loop above.
      assert_equal "1", set["DISABLE_AUTOUPDATER"], "claude's background auto-updater must be off in the sandbox (#145)"
      assert_equal "1", set["DISABLE_UPDATES"], "manual `claude update` must be off too — same symlink-repoint footgun (#145)"
    end

    def test_sandbox_env_keeps_home_and_clears_tmux_and_gh_token
      env = Sandbox.sandbox_env("/tmp/sbx9-x", "/tmp/sbx9-x/state", "/c")
      refute env[:set].key?("HOME"), "HOME must be left untouched (real shell/tmux/ruby stay usable)"
      assert_includes env[:unset], "TMUX"     # else a nested attach from inside real tmux fails
      # gh reads GH_TOKEN OR GITHUB_TOKEN (+ enterprise twins) — all must be cleared
      %w[GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN].each do |k|
        assert_includes env[:unset], k, "#{k} must be cleared so no real gh credential escapes"
      end
    end

    # --- seed_repo: the fixtures actually render (F2/D9) ----------------------

    def test_seed_repo_builds_the_four_worktrees_with_correct_state
      Sandbox.write_git_config
      state = path("sbstate")
      Sandbox.seed_repo(state)

      wt = File.join(state, "worktrees", "sandbox")
      %w[auth-token-refresh bulk-import quiet-cleanup sidebar-polish].each do |leaf|
        assert File.directory?(File.join(wt, leaf)), "missing worktree #{leaf}"
      end

      # 1. PR badge renders "#12", NOT "#?" (the shape the renderer actually reads)
      cache = JSON.parse(File.read(Pr.cache_file("sandbox")))
      entry = cache["sandbox/auth-token-refresh"]
      assert_equal "#12", View.pr_identifier(entry)
      assert_equal "OPEN", entry["status"]

      # 2. big diff is non-trivial vs base main
      adds, = Git.diff_counts(File.join(wt, "bulk-import"), "main")
      assert_operator adds, :>, 100, "big-diff worktree should have a large +count"

      # 4. multi-branch worktree expands (reflog holds >1 branch)
      assert_operator Git.branch_history(File.join(wt, "sidebar-polish")).size, :>=, 2

      # dots seeded for two worktrees, in the throwaway state dir
      dots = Dir.glob(File.join(AgentState.state_dir, "*"))
      assert_operator dots.size, :>=, 2
    end

    # --- D11: the SWITCHBOARD_SANDBOX guards ---------------------------------

    def test_reap_sidebars_noops_inside_the_sandbox
      ENV["SWITCHBOARD_SANDBOX"] = "1"
      # Even with a machine-global sidebar process and NO matching live pane (which
      # would normally flag it an orphan), the sandbox must reap nothing.
      stub_method(Tmux, :sidebar_processes, ->(*) { [[999, "ttys999"]] }) do
        stub_method(Tmux, :live_pane_ttys, ->(*) { Set["ttys000"] }) do
          assert_equal [], Reconcile.reap_sidebars(dry_run: true)
        end
      end
    end

    def test_reap_sidebars_active_without_the_flag
      ENV.delete("SWITCHBOARD_SANDBOX")
      stub_method(Tmux, :sidebar_processes, ->(*) { [[999, "ttys999"]] }) do
        stub_method(Tmux, :live_pane_ttys, ->(*) { Set["ttys000"] }) do
          assert_equal [999], Reconcile.reap_sidebars(dry_run: true),
                       "the guard, not empty state, is what makes the sandbox safe"
        end
      end
    end

    # --- run guard + dispatch ------------------------------------------------

    def test_run_bails_clearly_when_tmux_is_missing
      stub_method(Sandbox, :tmux?, ->(*) { false }) do
        out, err = capture_io { assert_equal false, Sandbox.run }
        assert_empty out
        assert_match(/needs tmux/, err)
      end
    end

    def test_cli_dispatches_sandbox
      called = false
      stub_method(Sandbox, :run, ->(*) { called = true }) do
        CLI.run(["sandbox"])
      end
      assert called, "`switchboard sandbox` must route to Sandbox.run"
    end
  end
end
