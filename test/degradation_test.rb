# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The graceful-degradation convention (a CLAUDE.md invariant): a failed shell-out
  # or corrupt cache must degrade to []/{}/nil/an-integer, never crash the UI. Each
  # of these would otherwise blow up the sidebar's paint loop.
  class DegradationTest < SandboxTest
    def test_git_worktrees_on_a_non_repo_is_empty
      assert_empty Git.worktrees(path("notarepo"))
    end

    def test_git_dirty_on_a_non_repo_is_false
      refute Git.dirty?(path("notarepo"))
    end

    def test_git_remote_head_on_a_non_repo_is_nil
      assert_nil Git.remote_head(path("notarepo"))
    end

    def test_pr_for_project_with_no_cache_is_empty
      assert_equal({}, Pr.for_project("never-fetched"))
    end

    def test_pr_for_project_with_corrupt_cache_is_empty
      FileUtils.mkdir_p(Pr.cache_dir)
      File.write(Pr.cache_file("app"), "}{ not json")
      assert_equal({}, Pr.for_project("app"))
    end

    # An absent pane (or absent tmux) makes the backtick return "" and capture_hash
    # hashes that — it returns an Integer, it does NOT return 0 and does NOT raise.
    # The real invariant is "never crashes the scan". (On a box with tmux this
    # exercises pane-absent; on a tmux-less CI runner, tmux-absent — same path.)
    def test_capture_hash_returns_an_integer_when_the_pane_is_absent
      assert_kind_of Integer, AgentState.new.send(:capture_hash, "%no-such-pane")
    end
  end
end
