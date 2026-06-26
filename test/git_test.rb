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

    def test_move_worktree_moves_the_directory
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", path("old"), "-b", "feature")
      assert Git.move_worktree(repo, path("old"), path("new"))
      refute File.exist?(path("old"))
      assert File.directory?(path("new"))
    end

    # A live agent freezes its project dir at the OLD path; bridge: leaves a
    # symlink there pointing at the new dir so its hooks keep resolving.
    def test_move_worktree_with_bridge_leaves_a_symlink_behind
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", path("old"), "-b", "feature")
      assert Git.move_worktree(repo, path("old"), path("new"), bridge: true)
      assert File.symlink?(path("old")), "old path is a symlink, not gone"
      assert_equal File.realpath(path("new")), File.realpath(path("old")), "bridge resolves to the new dir"
    end

    def test_move_worktree_without_bridge_leaves_nothing_behind
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", path("old"), "-b", "feature")
      assert Git.move_worktree(repo, path("old"), path("new"))
      refute File.symlink?(path("old"))
      refute File.exist?(path("old"))
    end

    # Reusing a name a prior rename bridged: the stale symlink at the target must
    # not block the move (git refuses a move onto an existing path).
    def test_move_worktree_clears_a_stale_bridge_at_the_target
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", path("a"), "-b", "fa")
      git(repo, "worktree", "add", "-q", path("b"), "-b", "fb")
      File.symlink(path("b"), path("dest")) # a leftover bridge squatting the target name
      assert Git.move_worktree(repo, path("a"), path("dest")), "stale symlink at dest is cleared first"
      refute File.symlink?(path("dest"))
      assert File.directory?(path("dest"))
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

    # The Sidebar passes a per-process cache so a reload that finds the reflog
    # unchanged skips the rev-parse subprocess AND the re-parse. Prove the hit path
    # by poisoning the cached parse: an unchanged reflog must return the poison,
    # i.e. it didn't read the file again.
    def test_branch_history_returns_the_cache_when_the_reflog_is_unchanged
      repo = temp_git_repo
      git(repo, "checkout", "-q", "-b", "feature")
      git(repo, "checkout", "-q", "main")
      cache = {}
      Git.branch_history(repo, cache: cache) # populate
      gitdir, mtime, limit, = cache[repo]
      cache[repo] = [gitdir, mtime, limit, ["SENTINEL"]]
      assert_equal ["SENTINEL"], Git.branch_history(repo, cache: cache),
                   "an unchanged reflog returns the cached parse, not a fresh read"
    end

    # A new checkout appends to logs/HEAD, bumping its mtime — the cache key — so the
    # entry invalidates and the history is re-parsed.
    def test_branch_history_reparses_when_the_reflog_mtime_changes
      repo = temp_git_repo
      git(repo, "checkout", "-q", "-b", "feature")
      git(repo, "checkout", "-q", "main")
      cache = {}
      Git.branch_history(repo, cache: cache)
      gitdir, _mtime, limit, = cache[repo]
      cache[repo] = [gitdir, Time.at(0), limit, ["STALE"]] # force a mtime mismatch
      hist = Git.branch_history(repo, cache: cache)
      assert_includes hist, "feature", "a changed reflog mtime invalidates the cache and re-parses"
      refute_includes hist, "STALE"
    end

    # A detached-HEAD checkout records the commit-ish (full or abbreviated SHA) in
    # the reflog `to` token; it must not surface as a branch row. Covers the #21
    # regression (abbreviated SHA) plus the 4-char and full-SHA cases — the latter
    # two pin both ends of the filter on the line we changed.
    def test_branch_history_excludes_detached_sha_checkouts
      repo = temp_git_repo
      full = git(repo, "rev-parse", "HEAD").strip
      short = git(repo, "rev-parse", "--short=7", "HEAD").strip
      four = full[0, 4] # git's minimum abbreviation; unique in a one-commit repo
      [short, four, full].each do |sha|
        git(repo, "checkout", "-q", sha) # detached HEAD at a SHA
        git(repo, "checkout", "-q", "main")
      end
      hist = Git.branch_history(repo)
      refute_includes hist, short, "abbreviated (7-char) detached SHA is not a branch"
      refute_includes hist, four, "abbreviated (4-char) detached SHA is not a branch"
      refute_includes hist, full, "full SHA detached checkout is not a branch"
      assert_includes hist, "main"
    end

    # The inverse of the SHA filter: a real branch whose name happens to be hex
    # (the failure mode of a naive length regex) must still appear. "abc" sits
    # below the 4-char floor; "deadbeef" exercises the OID-prefix discrimination.
    def test_branch_history_keeps_hex_named_branches
      repo = temp_git_repo
      git(repo, "checkout", "-q", "-b", "abc") # 3 hex chars, below the abbrev floor
      git(repo, "checkout", "-q", "main")
      git(repo, "checkout", "-q", "-b", "deadbeef") # 8 hex chars, looks like a SHA
      git(repo, "checkout", "-q", "main")
      hist = Git.branch_history(repo)
      assert_includes hist, "abc", "a short hex branch name is still a branch"
      assert_includes hist, "deadbeef", "a real hex-named branch is not mistaken for a SHA"
    end

    # The OID-prefix filter is hash-agnostic; prove it on SHA-256. Skipped (not
    # failed) on git builds that lack the object format.
    def test_branch_history_excludes_sha256_detached_checkout
      repo = begin
        temp_git_repo("sha256repo", object_format: "sha256")
      rescue RuntimeError
        skip "git lacks sha256 object format"
      end
      short = git(repo, "rev-parse", "--short=12", "HEAD").strip
      git(repo, "checkout", "-q", short)
      git(repo, "checkout", "-q", "main")
      refute_includes Git.branch_history(repo), short, "sha256 abbreviated detached checkout is not a branch"
    end

    # The bug this whole feature exists to avoid: a branch you only ever moved AWAY
    # from — including the one a worktree was BORN on (which has no "moving to" line
    # of its own) — must still appear. To-only parsing dropped it, so a worktree that
    # cut a second branch in place showed only the new branch, never the first.
    def test_branch_history_includes_a_branch_only_ever_moved_from
      repo = temp_git_repo # born on main
      git(repo, "checkout", "-q", "-b", "feature") # main -> feature; main is only a "from"
      hist = Git.branch_history(repo)
      assert_includes hist, "feature"
      assert_includes hist, "main", "the born-on branch (only ever a 'from') still appears"
      assert_equal "feature", hist.first, "the branch moved TO is still newest-first"
    end

    # The mirror of the detached-`to` filter: a detached SHA in the `from` position
    # (you moved away from a detached HEAD) is filtered against the OLD oid, not the new.
    def test_branch_history_excludes_a_detached_sha_in_the_from_position
      repo = temp_git_repo
      short = git(repo, "rev-parse", "--short=7", "HEAD").strip
      git(repo, "checkout", "-q", short)           # detach at SHA
      git(repo, "checkout", "-q", "-b", "feature") # short -> feature; 'short' is now the "from"
      hist = Git.branch_history(repo)
      refute_includes hist, short, "a detached SHA moved-from is not a branch"
      assert_includes hist, "feature"
      assert_includes hist, "main"
    end

    # A HEAD-relative detached spelling (HEAD~1, HEAD@{2}, main^) is recorded by name
    # in the reflog `to` token but is not a local branch — the branch-name-illegal
    # character guard drops it. (Tags / remote-refs are valid branch spellings and
    # still slip through; that's a known, accepted limitation.)
    def test_branch_history_excludes_head_relative_detached_checkouts
      repo = temp_git_repo
      git(repo, "commit", "--allow-empty", "-q", "-m", "c2") # need a parent for HEAD~1
      git(repo, "checkout", "-q", "HEAD~1")        # detach onto HEAD~1 by name
      git(repo, "checkout", "-q", "-b", "feature")
      hist = Git.branch_history(repo)
      refute_includes hist, "HEAD~1", "a HEAD-relative detached spelling is not a branch"
      assert_includes hist, "feature"
      assert_includes hist, "main"
    end

    # The guard path: a repo with no checkout reflog (a fresh init has no
    # logs/HEAD at all) yields no branches instead of raising.
    def test_branch_history_empty_without_checkout_reflog
      repo = path("freshrepo")
      FileUtils.mkdir_p(repo)
      git(repo, "init", "-q", "-b", "main") # no commits → no logs/HEAD
      assert_empty Git.branch_history(repo)
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

    # --- diff counts (issue #79) ---------------------------------------------

    def test_diff_counts_sums_additions_and_deletions_vs_base
      repo = temp_git_repo("app", origin: true) # seed: README.md = "seed\n"
      assert_equal [0, 0], Git.diff_counts(repo, "origin/main"), "nothing ahead of base"
      File.write(File.join(repo, "README.md"), "one\ntwo\nthree\n") # -1 seed, +3 lines
      File.write(File.join(repo, "new.txt"), "x\n")                 # +1
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "work")
      assert_equal [4, 1], Git.diff_counts(repo, "origin/main")
    end

    def test_diff_counts_blank_base_is_zero
      assert_equal [0, 0], Git.diff_counts(temp_git_repo, nil)
      assert_equal [0, 0], Git.diff_counts(temp_git_repo("empty"), "")
    end

    # The branch-row case: count an arbitrary branch (not HEAD) vs base, from any checkout.
    def test_diff_counts_for_an_arbitrary_ref
      repo = temp_git_repo("app", origin: true)
      git(repo, "checkout", "-q", "-b", "feat")
      File.write(File.join(repo, "g.txt"), "x\ny\n")
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "feat")
      git(repo, "checkout", "-q", "main")
      assert_equal [2, 0], Git.diff_counts(repo, "origin/main", "feat")
    end

    def test_sum_numstat_parses_columns_and_skips_binary
      assert_equal [711, 34], Git.sum_numstat("700\t30\ta.rb\n11\t4\tb.rb\n")
      assert_equal [5, 0], Git.sum_numstat("5\t0\tonly_adds.rb\n")
      assert_equal [0, 9], Git.sum_numstat("0\t9\tonly_dels.rb\n")
      assert_equal [0, 0], Git.sum_numstat("-\t-\timage.png\n"), "binary rows fall out via to_i"
      assert_equal [0, 0], Git.sum_numstat(""), "empty diff"
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

    # --- branch sync helpers (#94) -------------------------------------------

    # rename_branch renames a branch checked out in a LINKED worktree (not a stub):
    # the worktree must end up on the new branch.
    def test_rename_branch_renames_a_worktree_checked_out_branch
      repo = temp_git_repo("app")
      wt = path("wt")
      git(repo, "worktree", "add", "-q", wt, "-b", "old")
      assert Git.rename_branch(repo, "old", "feature/new")
      assert_equal "feature/new", Git.current_branch(wt), "the worktree follows the rename"
    end

    def test_rename_branch_refuses_when_the_target_exists
      repo = temp_git_repo("app")
      git(repo, "branch", "taken")
      git(repo, "worktree", "add", "-q", path("wt"), "-b", "old")
      refute Git.rename_branch(repo, "old", "taken"), "-m fails into an existing branch"
      assert Git.branch_exists?(repo, "old"), "the source branch is untouched on refusal"
    end

    def test_branch_exists
      repo = temp_git_repo("app")
      git(repo, "branch", "here")
      assert Git.branch_exists?(repo, "here")
      refute Git.branch_exists?(repo, "absent")
    end

    def test_valid_branch_name
      assert Git.valid_branch_name?("feature/auth")
      refute Git.valid_branch_name?("foo..bar"), "git rejects double-dot"
      refute Git.valid_branch_name?("foo.lock"), "git rejects a .lock suffix"
      refute Git.valid_branch_name?(""), "blank is not valid"
    end

    # pushed? arm 1 — a remote-tracking ref: a --no-track branch off origin/main is
    # NOT pushed, and becomes so after a push to the (local, offline) bare origin.
    def test_pushed_via_remote_tracking_ref
      repo = temp_git_repo("app", origin: true)
      git(repo, "worktree", "add", "--no-track", "-b", "feat", path("wt"), "origin/main")
      refute Git.pushed?(repo, "feat"), "a --no-track branch off origin/main is not pushed"

      git(repo, "push", "-q", "origin", "feat") # offline: pushes to the local bare clone
      assert Git.pushed?(repo, "feat"), "a remote-tracking ref now exists"
    end

    # pushed? arm 2 — a configured upstream with NO remote-tracking ref (a stale/
    # set-upstream case): the @{upstream} arm catches it. This is why Creator uses
    # --no-track (else a fresh branch would carry origin/main as upstream here).
    def test_pushed_via_configured_upstream
      repo = temp_git_repo("app")
      git(repo, "branch", "feat")
      refute Git.tracking_upstream?(repo, "feat"), "no upstream yet"
      refute Git.pushed?(repo, "feat")

      git(repo, "branch", "--set-upstream-to=main", "feat") # upstream config, no remote ref
      assert Git.tracking_upstream?(repo, "feat")
      assert Git.pushed?(repo, "feat"), "a configured @{upstream} counts as tracked"
    end
  end
end
