# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Git is the runtime source of truth, so these run against real throwaway repos
  # (temp_git_repo) rather than stubbing — git is already a dependency and the
  # porcelain parsing is exactly what we want to pin. All hermetic via SandboxTest.
  class GitTest < SandboxTest
    def test_worktrees_lists_main_and_added_with_branches
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", path("wt2"), "-b", "feature")
      wts = Git.worktrees(repo)
      assert_equal 2, wts.size
      branches = wts.map { |w| w[:branch] }
      assert_includes branches, "main"
      assert_includes branches, "feature"
      refute(wts.any? { |w| w[:bare] })
    end

    def test_worktrees_flags_a_bare_repo
      repo = temp_git_repo("app", origin: true)
      assert(Git.worktrees("#{repo}.git").any? { |w| w[:bare] }, "bare clone reports bare: true")
    end

    def test_current_branch
      assert_equal "main", Git.current_branch(temp_git_repo)
    end

    def test_dirty_is_false_when_clean_true_with_changes
      repo = temp_git_repo
      refute Git.dirty?(repo)
      File.write(File.join(repo, "new.txt"), "x")
      assert Git.dirty?(repo)
    end

    def test_branch_history_reads_checkout_reflog_newest_first
      repo = temp_git_repo
      git(repo, "checkout", "-q", "-b", "feature")
      git(repo, "checkout", "-q", "main")
      hist = Git.branch_history(repo)
      assert_includes hist, "feature"
      assert_includes hist, "main"
      assert_equal "main", hist.first, "the most recent checkout target comes first"
    end

    def test_remote_head_with_and_without_origin
      assert_equal "origin/main", Git.remote_head(temp_git_repo("withremote", origin: true))
      assert_nil Git.remote_head(temp_git_repo("noremote"))
    end

    def test_ahead_behind_counts_relative_to_base
      repo = temp_git_repo("app", origin: true)
      assert_equal [0, 0], Git.ahead_behind(repo, "origin/main")
      git(repo, "commit", "--allow-empty", "-q", "-m", "ahead")
      assert_equal [1, 0], Git.ahead_behind(repo, "origin/main")
    end

    # Pr.repo_slug is a git-shelling helper, so it lives with the other real-repo
    # tests. No network — we only set the remote URL.
    def test_repo_slug_from_origin_url
      repo = temp_git_repo("app")
      git(repo, "remote", "add", "origin", "git@github.com:wvmitchell/switchboard.git")
      assert_equal "wvmitchell/switchboard", Pr.repo_slug(repo)
    end

    def test_repo_slug_nil_without_origin
      assert_nil Pr.repo_slug(temp_git_repo("noremote"))
    end
  end
end
