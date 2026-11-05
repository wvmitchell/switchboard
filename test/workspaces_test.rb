# frozen_string_literal: true

require_relative "test_helper"
require "set"

module Switchboard
  # What quitting and removing a workspace do, whichever front-end asked. The rows each
  # front-end adds around them are tested with that front-end.
  class WorkspacesTest < SandboxTest
    # Value: protects=dispatch never destroys work: no in-flight build opens a session after a
    # quit; fails_when=quit_all moves the cancel after the kill or drops it; why_new=replaces
    # one copy of this assertion per front-end; seam=none; no_claim=the real tmux teardown
    def test_quit_all_cancels_in_flight_builds_before_killing_sessions
      rec = Creation.create(project: "proj", name: "x", path: path("x"), task: "")
      state_at_kill = nil
      stub_method(Tmux, :kill_all, -> { state_at_kill = Creation.find(rec["id"])&.dig("state"); [] }) { Workspaces.quit_all }
      assert_equal "canceled", state_at_kill, "the real cancel_all ran before any session was killed"
    end

    # Value: protects=every per-session store being wiped before the kill, so nothing stale
    # outlives the agents; fails_when=a clear_all is dropped or moves after the kill; why_new=each
    # front-end's quit wrote its own list, and only some stores were checked; seam=none;
    # no_claim=the contents of each store (each store's own test)
    def test_quit_all_wipes_every_session_store_before_the_kill_and_returns_the_killed
      order = []
      stores = [AgentState, Monitoring, Notify, OffstageHold, PendingDelete]
      run = stores.reduce(-> { Workspaces.quit_all }) do |inner, store|
        -> { stub_method(store, :clear_all, -> { order << store }) { inner.call } }
      end
      killed = nil
      stub_method(Tmux, :kill_all, -> { order << :kill; %w[sb/a sb/b] }) { killed = run.call }
      assert_equal stores.to_set, order[0...-1].to_set
      assert_equal :kill, order.last
      assert_equal %w[sb/a sb/b], killed
    end

    # Value: protects=the removal forces past a lock only on our un-set-up build, like the reaper; fails_when=remove! drops or hardcodes `locked:`, so an interrupted add's ✘ can't be deleted without the binary, or a lock you set is overridden; why_new=the delete tests stub remove_worktree ignoring kwargs; seam=none; no_claim=git honoring the second --force (cli_test covers that against a real lock)
    def test_remove_forces_past_a_lock_only_on_an_unfinished_build
      rec = Creation.create(project: "app", name: "half", path: "/wt/half", task: "t")
      Creation.update(rec["id"], state: "failed", reason: "interrupted")
      locks = {}
      stub_method(Git, :remove_worktree, ->(_repo, p, **kw) { locks[p] = kw[:locked]; true }) do
        stub_method(Git, :delete_branch, ->(*, **) { true }) do
          %w[/wt/half /wt/a].each { |p| Workspaces.remove!("/repos/app", p, "b") }
        end
      end
      assert_equal({ "/wt/half" => true, "/wt/a" => false }, locks)
    end

    # Value: protects=a removal that failed keeps its branches in the no-binary path too; fails_when=remove! stops checking the removal and force-deletes branches for a workspace that still exists; why_new=only the reaper path had this test; seam=Git.remove_worktree; no_claim=why git refused
    def test_remove_keeps_the_branches_when_the_removal_fails
      planned = [WorkspaceBranches::Entry.new(name: "old", sha: "abc", merged: true)]
      deleted = false
      stub_method(Git, :remove_worktree, ->(*, **) { false }) do
        stub_method(WorkspaceBranches, :delete_and_report, ->(*) { deleted = true }) do
          Workspaces.remove!("/repos/app", "/wt/a", "feature", branches: planned)
        end
      end
      refute deleted
    end

    # Value: protects=a canceled build without the binary still cleans its branch, forced only when asked; fails_when=remove! drops the legacy delete_branch call or its force flag; why_new=the old assertion moved to the plan path; seam=Git.delete_branch; no_claim=git's -d semantics
    def test_remove_without_a_plan_uses_the_callers_branch_and_force
      calls = []
      stub_method(Git, :remove_worktree, ->(*, **) { true }) do
        stub_method(Git, :delete_branch, ->(_repo, b, force: false) { calls << [b, force] }) do
          Workspaces.remove!("/repos/app", "/wt/a", "safe")
          Workspaces.remove!("/repos/app", "/wt/b", "placeholder", force_branch: true)
        end
      end
      assert_equal [["safe", false], ["placeholder", true]], calls
    end

    # Value: protects=without a plan, a failed removal still leaves the branch to git: a branch
    # whose tree is already gone gets cleaned, a still-checked-out one survives even -D;
    # fails_when=remove! gates this delete on the removal as the plan path does, leaking the first,
    # or forces past git, losing the second; why_new=the other no-plan tests stub git or remove
    # successfully; seam=none; no_claim=why a removal failed
    def test_remove_without_a_plan_leaves_the_branch_to_git_when_the_removal_fails
      repo = temp_git_repo("app")
      git(repo, "branch", "treeless")
      git(repo, "worktree", "add", "-q", path("mine"), "-b", "mine")
      git(repo, "worktree", "lock", path("mine"))
      Workspaces.remove!(repo, path("never-made"), "treeless", force_branch: true)
      Workspaces.remove!(repo, path("mine"), "mine", force_branch: true)
      branches = git(repo, "branch", "--format=%(refname:short)").split
      refute_includes branches, "treeless"
      assert_includes branches, "mine"
      assert File.exist?(path("mine")), "a lock you set still holds"
    end
  end
end
