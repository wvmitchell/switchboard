# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Deleting a workspace takes its local branches with it. Driven against real repos:
  # what's at stake is how git itself treats a reflog, a checkout and an unmerged branch.
  class WorkspaceBranchesTest < SandboxTest
    def workspace(repo, name = "wt", branch: "feature")
      git(repo, "worktree", "add", "-q", path(name), "-b", branch)
      path(name)
    end

    def branches(repo)
      git(repo, "branch", "--format=%(refname:short)").split
    end

    def names(entries)
      entries.map(&:name)
    end

    def commit(worktree)
      git(worktree, "commit", "-q", "--allow-empty", "-m", "ahead")
    end

    def reap(repo, worktree, branch, entries)
      stub_method(Tmux, :broadcast_warm, ->(**) {}) do
        CLI.send(:reap_worktree!, repo, worktree, branch, branches: entries)
      end
    end

    # Value: protects=the rule that deleting a workspace removes every branch it used; fails_when=the plan reads only the current branch or stops reading the worktree's own reflog; why_new=removal only ever tried the last branch; seam=none; no_claim=remote branches
    def test_plan_covers_the_current_branch_and_every_one_the_workspace_visited
      repo = temp_git_repo("app")
      wt = workspace(repo)
      git(wt, "checkout", "-q", "-b", "second")
      git(wt, "switch", "-q", "-c", "third")
      assert_equal %w[feature second third], names(WorkspaceBranches.plan(repo, wt, "main")).sort
    end

    # Value: protects=a workspace delete never takes the trunk or a branch another workspace is on; fails_when=the plan forgets the base's short name, the always-kept names, or other worktrees; why_new=the plan is new and a reflog names everything it passed through; seam=none; no_claim=none
    def test_plan_never_offers_the_trunk_or_a_branch_checked_out_elsewhere
      repo = temp_git_repo("app")
      git(repo, "branch", "develop")
      git(repo, "branch", "master")
      git(repo, "checkout", "-q", "--detach") # frees main, so this workspace can visit it
      wt = workspace(repo)
      %w[develop master main].each { |b| git(wt, "checkout", "-q", b) }
      git(wt, "checkout", "-q", "-b", "now-busy")
      git(wt, "checkout", "-q", "feature")
      git(repo, "worktree", "add", "-q", path("other"), "now-busy")
      assert_equal %w[feature], names(WorkspaceBranches.plan(repo, wt, "origin/develop"))
    end

    # Value: protects=the trunk survives however the project's base is spelled; fails_when=kept_names strips only one leading segment, so refs/heads/develop leaves develop offered and, as a lone merged branch, unlisted; why_new=Codex and red team both reproduced this; seam=none; no_claim=none
    def test_plan_keeps_the_base_in_every_spelling
      %w[develop origin/develop refs/heads/develop refs/remotes/origin/develop team/upstream/develop].each_with_index do |base, i|
        repo = temp_git_repo("app#{i}")
        git(repo, "branch", "develop")
        wt = workspace(repo, "wt#{i}")
        git(wt, "checkout", "-q", "develop")
        git(wt, "checkout", "-q", "feature")
        assert_equal %w[feature], names(WorkspaceBranches.plan(repo, wt, base)), "base: #{base}"
      end
    end

    # Value: protects=a project's remote default branch survives when the configured base differs; fails_when=kept_names drops Git.remote_head; why_new=the trunk tests have no origin/HEAD, so remote_head returns nil; seam=none; no_claim=remote branches
    def test_plan_keeps_the_remote_default_branch
      repo = temp_git_repo("app", origin: true)
      git(repo, "branch", "develop")
      git(repo, "push", "-q", "origin", "develop")
      git(repo, "remote", "set-head", "origin", "develop")
      wt = workspace(repo)
      git(wt, "checkout", "-q", "develop")
      git(wt, "checkout", "-q", "feature")
      assert_equal %w[feature], names(WorkspaceBranches.plan(repo, wt, "origin/release"))
    end

    # Value: protects=the plan names only branches that exist now; fails_when=a renamed-away name or a detached sha is offered; why_new=the reflog keeps both; seam=none; no_claim=none
    def test_plan_skips_names_that_no_longer_resolve
      repo = temp_git_repo("app")
      wt = workspace(repo)
      git(wt, "checkout", "-q", "-b", "old")
      git(wt, "checkout", "-q", "--detach")
      git(wt, "checkout", "-q", "old")
      git(wt, "branch", "-m", "old", "new")
      assert_equal %w[feature new], names(WorkspaceBranches.plan(repo, wt, "main")).sort
    end

    # Value: protects=a revision the reflog recorded isn't offered as a branch; fails_when=the plan trusts rev-parse instead of git's branch list, so main~1 resolves under refs/heads/ and is listed then falsely reported as kept; why_new=security specialist reproduced it; seam=none; no_claim=none
    def test_plan_skips_a_revision_expression_from_the_reflog
      repo = temp_git_repo("app")
      commit(repo)
      wt = workspace(repo)
      git(wt, "checkout", "-q", "main~1")
      git(wt, "checkout", "-q", "feature")
      assert_equal %w[feature], names(WorkspaceBranches.plan(repo, wt, "main"))
    end

    # Value: protects=a mis-cased checkout on a case-insensitive filesystem can't reach the trunk or another worktree's branch; fails_when=names aren't checked against git's own spelling, so branch -D MAIN unlinks main's loose ref; why_new=three reviewers reproduced this on APFS; seam=none; no_claim=case-sensitive filesystems, where the checkout itself fails
    def test_plan_ignores_a_mis_cased_name_on_a_case_insensitive_filesystem
      repo = temp_git_repo("app")
      skip "needs a case-insensitive filesystem" unless File.exist?(File.join(repo, ".GIT", "HEAD"))
      git(repo, "checkout", "-q", "--detach") # frees main for the mis-cased checkout
      git(repo, "branch", "live")
      git(repo, "worktree", "add", "-q", path("other"), "live")
      wt = workspace(repo)
      git(wt, "checkout", "-q", "MAIN")
      git(wt, "checkout", "-q", "--detach")
      git(wt, "checkout", "-q", "feature")
      git(wt, "checkout", "-q", "LIVE")
      git(wt, "checkout", "-q", "feature")
      assert_equal %w[feature], names(WorkspaceBranches.plan(repo, wt, "main"))
    end

    # Value: protects=a branch another live workspace once used isn't deleted from under it, and the last workspace still takes it; fails_when=the plan subtracts only other worktrees' current branches, or the reflog check outlives the worktree; why_new=red team reproduced another workspace's parked work going; seam=none; no_claim=none
    def test_a_branch_another_workspace_used_stays_until_the_last_one_goes
      repo = temp_git_repo("app")
      b = workspace(repo, "b", branch: "theirs")
      commit(b)
      git(b, "checkout", "-q", "-b", "moved-on")
      a = workspace(repo, "a", branch: "mine")
      git(a, "checkout", "-q", "theirs")
      git(a, "checkout", "-q", "mine")
      assert_equal %w[mine], names(WorkspaceBranches.plan(repo, a, "main"))

      reap(repo, b, "moved-on", WorkspaceBranches.plan(repo, b, "main"))
      assert_includes branches(repo), "theirs", "a has used it, so b's delete leaves it"
      assert_equal %w[mine theirs], names(WorkspaceBranches.plan(repo, a, "main")).sort
    end

    # Value: protects=a branch renamed since the sidebar last read it still goes with its workspace; fails_when=the plan trusts a caller's cached branch, since the reflog records no rename as a checkout; why_new=Codex reproduced a silent survivor; seam=none; no_claim=none
    def test_plan_reads_the_current_branch_from_git
      repo = temp_git_repo("app")
      wt = workspace(repo)
      git(wt, "branch", "-m", "feature", "renamed")
      assert_equal %w[renamed], names(WorkspaceBranches.plan(repo, wt, "main"))
    end

    # Value: protects=a renamed workspace's symlinked old path still reads as this tree; fails_when=the plan compares raw paths, so its branch reads as checked out elsewhere and leaks; why_new=only macOS's tmpdir exercised this by accident, and CI runs Linux; seam=none; no_claim=the rename itself
    def test_plan_treats_a_symlinked_path_as_the_same_tree
      repo = temp_git_repo("app")
      wt = workspace(repo)
      File.symlink(wt, path("old-name"))
      assert_equal %w[feature], names(WorkspaceBranches.plan(repo, path("old-name"), "main"))
    end

    # Value: protects=a commit message can't add a branch to the delete list; fails_when=the visited_branches regex loses its anchor; why_new=every reflog in these tests is a real checkout; seam=none; no_claim=other reflog subjects
    def test_a_commit_message_cannot_add_a_branch
      repo = temp_git_repo("app")
      git(repo, "branch", "bystander")
      wt = workspace(repo)
      git(wt, "commit", "-q", "--allow-empty", "-m", "checkout: moving from feature to bystander")
      assert_equal %w[feature], names(WorkspaceBranches.plan(repo, wt, "main"))
    end

    # Value: protects=nothing is offered when a worktree couldn't be read, since it could hold a candidate; fails_when=the plan uses the non-strict listing; why_new=strict exists for destructive callers; seam=Git.worktrees; no_claim=none
    def test_plan_offers_nothing_when_git_cannot_list_every_worktree
      stub_method(Git, :worktrees, ->(*, **) { nil }) do
        assert_empty WorkspaceBranches.plan("/repos/app", "/wt/a", "main")
      end
    end

    def test_plan_offers_nothing_for_a_tree_git_does_not_list
      repo = temp_git_repo("app")
      workspace(repo)
      assert_empty WorkspaceBranches.plan(repo, path("no-such-tree"), "main")
    end

    # Value: protects=the confirm warns about unmerged work and stays quiet about a lone merged branch; fails_when=the merged flag or listing rule inverts; why_new=option A's whole safety is this prompt; seam=none; no_claim=painting
    def test_listing_flags_what_is_not_in_the_base_and_stays_out_of_the_simple_case
      repo = temp_git_repo("app")
      wt = workspace(repo)
      plan = WorkspaceBranches.plan(repo, wt, "main")
      assert_empty WorkspaceBranches.listing(plan, "main"), "one merged branch needs no list"

      commit(wt)
      plan = WorkspaceBranches.plan(repo, wt, "main")
      assert_equal ["also deletes (! not in main):", "! feature"], WorkspaceBranches.listing(plan, "main"),
                   "a lone unmerged branch is worth naming"
    end

    # Value: protects=unmerged names lead the list; fails_when=plan stops sorting; why_new=the listing test's unmerged branch was already first; seam=none; no_claim=none
    def test_unmerged_branches_lead_the_list
      repo = temp_git_repo("app")
      wt = workspace(repo)
      commit(wt)
      git(wt, "checkout", "-q", "-b", "merged-one", "main")
      assert_equal ["also deletes (! not in main):", "! feature", "  merged-one"],
                   WorkspaceBranches.listing(WorkspaceBranches.plan(repo, wt, "main"), "main")
    end

    # Value: protects=an unreadable base reads as unmerged, so the prompt warns; fails_when=ancestor? fails open; why_new=a project with no fetched origin/main is common; seam=none; no_claim=none
    def test_a_base_that_does_not_resolve_reads_as_not_merged
      repo = temp_git_repo("app")
      wt = workspace(repo)
      plan = WorkspaceBranches.plan(repo, wt, "origin/nope")
      assert_equal [false], plan.map(&:merged)
    end

    def test_args_round_trip_a_slashed_name
      entry = WorkspaceBranches::Entry.new(name: "wv/feature", sha: "abc123")
      back = WorkspaceBranches.from_args(["reap-worktree", "/r", "/p", "b", *WorkspaceBranches.to_args([entry])])
      assert_equal [%w[wv/feature abc123]], back.map { |e| [e.name, e.sha] }
    end

    # Value: protects=an older caller keeps its safe -d, and an empty plan deletes nothing rather than falling back to it; fails_when=from_args returns [] without the flag or nil with it; why_new=the difference decides whether `main` could get -d'd; seam=none; no_claim=none
    def test_args_tell_an_older_caller_from_an_empty_plan
      assert_nil WorkspaceBranches.from_args(%w[reap-worktree /r /p b --force-branch])
      assert_empty WorkspaceBranches.from_args(%w[reap-worktree /r /p b --branches])
    end

    # Value: protects=the reported bug: a merged branch survived, and a squash-merged one always would; fails_when=the reaper goes back to -d or ignores the visited list; why_new=the old test pinned the opposite; seam=none; no_claim=none
    def test_reap_deletes_every_confirmed_branch_even_unmerged_ones
      repo = temp_git_repo("app")
      wt = workspace(repo)
      commit(wt)
      git(wt, "checkout", "-q", "-b", "second")
      commit(wt)
      plan = WorkspaceBranches.plan(repo, wt, "main")
      said = nil
      stub_method(Tmux, :notify_everyone, ->(msg, **) { said = msg }) { reap(repo, wt, "second", plan) }
      assert_empty branches(repo) & %w[feature second]
      refute File.exist?(wt)
      assert_nil said, "a clean delete has nothing to report"
    end

    # Value: protects=a workspace with nothing to delete keeps its branch; fails_when=reap_worktree! treats an empty plan like an older caller and falls back to -d, which takes a merged branch once the tree is freed; why_new=only from_args was tested with an empty plan; seam=none; no_claim=which names get planned
    def test_reap_with_an_empty_plan_deletes_no_branch
      repo = temp_git_repo("app")
      wt = workspace(repo)
      reap(repo, wt, "feature", [])
      refute File.exist?(wt), "the tree still goes"
      assert_includes branches(repo), "feature"
    end

    # Value: protects=a removal that failed keeps its branches, since the row comes back; fails_when=the reaper deletes branches without checking the removal; why_new=-D doesn't get git's no-op for free on the visited ones; seam=Git.remove_worktree; no_claim=none
    def test_reap_keeps_every_branch_when_the_removal_fails
      repo = temp_git_repo("app")
      wt = workspace(repo)
      git(wt, "checkout", "-q", "-b", "second")
      plan = WorkspaceBranches.plan(repo, wt, "main")
      stub_method(Git, :remove_worktree, ->(*, **) { false }) { reap(repo, wt, "second", plan) }
      assert_includes branches(repo), "feature"
      assert_includes branches(repo), "second"
    end

    # Value: protects=a commit landing after the confirm is never lost, and the survivor is reported; fails_when=delete skips the pinned-tip check or stops reporting; why_new=the confirm and the delete are far apart; seam=Tmux.notify_everyone; no_claim=tmux display
    def test_a_branch_that_moved_after_the_confirm_is_kept_and_reported
      repo = temp_git_repo("app")
      wt = workspace(repo)
      plan = WorkspaceBranches.plan(repo, wt, "main")
      commit(wt)
      said = nil
      stub_method(Tmux, :display_time, -> { "750" }) do
        stub_method(Tmux, :notify_everyone, ->(msg, **) { said = msg }) { reap(repo, wt, "feature", plan) }
      end
      assert_includes branches(repo), "feature"
      assert_includes said.to_s, "kept branch feature"
    end

    # Value: protects=a branch that became busy after the confirm survives; fails_when=delete moves to update-ref, which doesn't refuse a checkout; why_new=branch -D is the guard here; seam=none; no_claim=none
    def test_delete_refuses_a_branch_checked_out_elsewhere
      repo = temp_git_repo("app")
      git(repo, "branch", "taken")
      wt = path("elsewhere")
      git(repo, "worktree", "add", "-q", wt, "taken")
      entry = WorkspaceBranches.entry(repo, "taken", "main")
      assert_equal %w[taken], WorkspaceBranches.delete(repo, [entry])
      assert_includes branches(repo), "taken"
    end

    def test_a_branch_already_gone_is_not_reported_as_kept
      repo = temp_git_repo("app")
      entry = WorkspaceBranches::Entry.new(name: "gone", sha: "abc")
      assert_empty WorkspaceBranches.delete(repo, [entry])
    end
  end
end
