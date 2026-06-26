# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Rename.perform end-to-end against real throwaway worktrees (the move + bridge
  # are real git; the tmux session rename is the one stubbed seam). The shared
  # core behind both the sidebar `r` key and `switchboard rename` (issue #42).
  class RenameTest < SandboxTest
    # Config registering `proj` -> a real repo.
    def config_for(repo)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      Config.new
    end

    # A linked worktree at wts/proj/<leaf> off `repo` (returns its path).
    def add_worktree(repo, leaf, branch: leaf)
      dest = path("wts", "proj", leaf)
      git(repo, "worktree", "add", "-q", dest, "-b", branch)
      dest
    end

    def test_perform_moves_the_dir_and_leaves_a_bridge
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "new")

      assert_equal :ok, result.status
      dest = path("wts", "proj", "new")
      assert_equal dest, result.dest
      assert File.directory?(dest)
      assert File.symlink?(old), "a bridge symlink is left at the old path"
      assert_equal File.realpath(dest), File.realpath(old), "the bridge resolves to the new dir"
    end

    # The whole point of the rename surviving a restart: Claude's transcript dir,
    # keyed by the (now-changed) cwd, is carried to the new path so `/resume` finds
    # it (issue #42 follow-up).
    def test_perform_carries_the_claude_history_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      # Claude keys by the canonicalized cwd; the worktree is real here, so on macOS
      # (/var -> /private/var) the raw sandbox path and Claude's key differ — seed at
      # the realpath key the running agent actually wrote under.
      hist = File.join(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"], ClaudeHistory.encode(File.realpath(old)))
      FileUtils.mkdir_p(hist)
      File.write(File.join(hist, "s1.jsonl"), "turn\n")

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      dest_hist = File.join(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"],
                            ClaudeHistory.encode(File.realpath(path("wts", "proj", "new"))))
      assert File.exist?(File.join(dest_hist, "s1.jsonl")), "the transcript moved to the new key"
    end

    def test_perform_unknown_project_is_failed
      config = config_for(temp_git_repo("proj"))
      assert_equal :failed, Rename.perform(config, "nope", path("x"), "new").status
    end

    def test_perform_blank_name_is_invalid
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "..").status # sanitizes to ""
      assert File.directory?(old), "no move on an invalid name"
    end

    # Agents type branch-style names; a "/" the sanitizer preserves would nest the
    # dir while the session/leaf see only the basename, so rename rejects it.
    def test_perform_rejects_a_slash_in_the_name
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "feature/auth").status
      assert File.directory?(old), "no move on a slashed name"
    end

    def test_perform_rename_to_the_same_name_is_unchanged
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :unchanged, Rename.perform(config_for(repo), "proj", old, "old").status
      assert File.directory?(old)
    end

    def test_perform_real_dir_collision_is_exists
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      FileUtils.mkdir_p(path("wts", "proj", "taken"))
      assert_equal :exists, Rename.perform(config_for(repo), "proj", old, "taken").status
      assert File.directory?(old), "no move onto a real dir"
    end

    # A stale rename-bridge squatting the target must not block the move.
    def test_perform_clears_a_stale_bridge_at_the_target
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      other = add_worktree(repo, "other", branch: "other")
      File.symlink(other, path("wts", "proj", "dest"))
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "dest").status
      assert File.directory?(path("wts", "proj", "dest"))
    end

    def test_perform_move_failure_is_failed
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Git, :move_worktree, ->(*, **) { false }) do
        assert_equal :failed, Rename.perform(config, "proj", old, "new").status
      end
    end

    def test_perform_renames_the_session_with_sanitized_leaf_names
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      seen = []
      stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(o, n) { seen << [o, n]; true }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "new").status
        end
      end
      assert_equal [["sb/proj/old", "sb/proj/new"]], seen
    end

    # Dir moved but a *reachable* session's rename failed -> :partial (recoverable;
    # prune reaps the orphan), distinct from a clean :ok.
    def test_perform_is_partial_when_a_live_session_rename_fails
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(*) { false }) do
          assert_equal :partial, Rename.perform(config, "proj", old, "new").status
        end
      end
      assert File.directory?(path("wts", "proj", "new")), "the dir still moved on :partial"
    end

    # No live session (clientless rename from a plain shell) is not a failure.
    def test_perform_is_ok_when_no_session_exists
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      stub_method(Tmux, :has_session?, ->(_) { false }) do
        assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      end
    end

    # A case-only rename (Old -> old) must NOT misreport as :exists/:failed. On a
    # case-insensitive FS (macOS) the two names are the same dir -> :unchanged; on a
    # case-sensitive FS they're distinct -> a real :ok move. Either is honest; the
    # regression (caught in review) was the bogus :exists the old File.exist? guard
    # produced on macOS.
    def test_perform_handles_a_case_only_rename_without_a_false_collision
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "Old")
      result = Rename.perform(config_for(repo), "proj", old, "old")
      assert_includes %i[ok unchanged], result.status,
                      "a case-only rename is not a collision or a failure"
    end

    # foo.bar and foo-bar both sanitize to the session sb/proj/foo-bar, so the dir
    # moves (dest != old_path) but the session names collapse equal — no tmux call.
    def test_perform_skips_session_rename_when_names_collapse_equal
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "foo.bar")
      config = config_for(repo)
      stub_method(Tmux, :has_session?, ->(*) { flunk "no session check when names collapse" }) do
        stub_method(Tmux, :rename_session, ->(*) { flunk "no rename when names collapse" }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "foo-bar").status
        end
      end
      assert File.directory?(path("wts", "proj", "foo-bar"))
    end

    # --- branch sync (#94) ---------------------------------------------------

    # When the branch is unpushed and still matches the leaf, rename renames it too,
    # so the dir and branch stay in step (the whole point of #94).
    def test_perform_syncs_the_branch_when_unpushed_and_in_sync
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old") # branch "old" == leaf, no remote
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert_equal "new", Git.current_branch(path("wts", "proj", "new"))
      refute Git.branch_exists?(repo, "old"), "the old branch name is gone"
    end

    # The branch adopts the CURRENT branch_prefix on rename (prefix drift): a bare
    # "old" branch becomes "wv/new".
    def test_perform_applies_the_branch_prefix
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "branch_prefix" => "wv",
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      assert_equal :ok, Rename.perform(Config.new, "proj", old, "new").status
      assert_equal "wv/new", Git.current_branch(path("wts", "proj", "new"))
    end

    # A pushed branch is left intact (renaming it would orphan its remote ref / PR),
    # but the dir still moves.
    def test_perform_leaves_a_pushed_branch
      repo = temp_git_repo("proj", origin: true)
      old = path("wts", "proj", "old")
      git(repo, "worktree", "add", "--no-track", "-q", "-b", "old", old, "origin/main")
      git(old, "push", "-q", "origin", "old") # offline push to the local bare origin
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert File.directory?(path("wts", "proj", "new")), "dir still moves"
      assert Git.branch_exists?(repo, "old"), "the pushed branch is left intact"
    end

    # A branch the user switched away from the leaf is left alone (dir-only rename).
    def test_perform_leaves_a_diverged_branch
      repo = temp_git_repo("proj")
      old = path("wts", "proj", "old")
      git(repo, "worktree", "add", "-q", "-b", "feature-x", old) # branch != leaf
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert Git.branch_exists?(repo, "feature-x"), "a diverged branch is left alone"
      refute Git.branch_exists?(repo, "new")
    end

    # A lingering branch at the target name ⇒ :branch_exists, and NOTHING moves
    # (atomic-ish: the agent retries with a new name; no dir≠branch divergence).
    def test_perform_branch_exists_moves_nothing
      repo = temp_git_repo("proj")
      git(repo, "branch", "new") # a lingering branch from a deleted workspace
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "new")
      assert_equal :branch_exists, result.status
      refute File.symlink?(old), "no bridge — the move never happened"
      refute File.exist?(path("wts", "proj", "new")), "dest not created"
      assert Git.branch_exists?(repo, "old"), "the old branch is untouched"
    end

    # A name git rejects as a branch fails clean before any move (when syncing).
    def test_perform_invalid_branch_name_moves_nothing
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "x.lock") # sanitizes ok, bad ref
      assert_equal :invalid, result.status
      refute File.exist?(path("wts", "proj", "x.lock")), "nothing moved"
      assert Git.branch_exists?(repo, "old")
    end
  end
end
