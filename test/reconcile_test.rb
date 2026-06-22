# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Reconcile is the core of issue #7: diff live sb/ sessions against the
  # worktrees git has, kill the orphans. The pure `orphans` decision is tested
  # directly; `prune` is tested over a REAL temp_git_repo with a really-removed
  # worktree (a stub of the orphan logic would be false-green), with only the
  # tmux seams (sessions/session_of/kill_session) stubbed.
  class ReconcileTest < SandboxTest
    NOW = 1_700_000_000
    OLD = NOW - 100 # comfortably older than SESSION_GRACE

    def sess(name, created = OLD) = { name: name, created: created }

    # --- orphans (pure) ------------------------------------------------------

    def test_orphans_returns_prefix_matched_sessions_absent_from_valid
      live = [sess("sb/app/feat"), sess("sb/app/gone"), sess("sb/home")]
      got = Reconcile.orphans(live, ["sb/app/feat"], ["sb/app/"], current: nil, now: NOW)
      assert_equal ["sb/app/gone"], got, "the un-backed sb/app/ session is the orphan"
    end

    def test_orphans_ignores_home_and_unmatched_prefixes
      live = [sess("sb/home"), sess("sb/other/x")]
      assert_empty Reconcile.orphans(live, [], ["sb/app/"], current: nil, now: NOW),
                   "home and non-app sessions match no verified prefix"
    end

    def test_orphans_respects_the_app_vs_app2_boundary
      live = [sess("sb/app2/x")]
      assert_empty Reconcile.orphans(live, ["sb/app/feat"], ["sb/app/"], current: nil, now: NOW),
                   "sb/app/ must not match sb/app2/"
    end

    def test_orphans_keeps_sessions_within_the_grace_window
      live = [sess("sb/app/fresh", NOW - 2)] # younger than SESSION_GRACE
      assert_empty Reconcile.orphans(live, [], ["sb/app/"], current: nil, now: NOW),
                   "a just-created session is never pruned (may host a live agent)"
    end

    def test_orphans_skips_the_current_session
      live = [sess("sb/app/gone")]
      assert_empty Reconcile.orphans(live, [], ["sb/app/"], current: "sb/app/gone", now: NOW),
                   "never prune the session we're sitting in (no self-eject)"
    end

    def test_orphans_keeps_sessions_with_an_unparsable_created_stamp
      # A blank/garbled session_created parses to 0; treating it as ancient would
      # bypass the grace guard. Fail safe: keep it rather than prune on bad input.
      live = [sess("sb/app/gone", 0)]
      assert_empty Reconcile.orphans(live, [], ["sb/app/"], current: nil, now: NOW),
                   "created=0 (parse failure) is too-fresh-to-judge, not ancient"
    end

    def test_orphans_does_not_claim_nested_project_sessions
      # project "app" (prefix sb/app/) must NOT prune a nested project "app/x"'s
      # session sb/app/x/feat — the extra "/" means a different project owns it.
      live = [sess("sb/app/x/feat")]
      assert_empty Reconcile.orphans(live, [], ["sb/app/"], current: nil, now: NOW),
                   "a nested project's session is left alone, not wrongly pruned"
    end

    def test_orphans_collision_union_protects_both_projects
      # app.dev and app-dev both sanitize to the sb/app-dev/ prefix. With the
      # union of BOTH projects' valid names, neither's live session is an orphan.
      live = [sess("sb/app-dev/from-dotted"), sess("sb/app-dev/from-dashed")]
      valid = ["sb/app-dev/from-dotted", "sb/app-dev/from-dashed"]
      prefixes = ["sb/app-dev/", "sb/app-dev/"]
      assert_empty Reconcile.orphans(live, valid, prefixes, current: nil, now: NOW)
    end

    # --- prune (real git, stubbed tmux) --------------------------------------

    def test_prune_kills_only_the_unbacked_session
      setup_app_project
      live = [sess("sb/app/app"), sess("sb/app/feat"), sess("sb/app/gone"), sess("sb/home")]
      killed = run_prune(live)
      assert_equal ["sb/app/gone"], killed
    end

    # The headline scenario: a worktree removed via git (the `d` action / a bare
    # `git worktree remove`) drops out of `git worktree list`, so its still-live
    # session becomes an orphan and gets pruned.
    def test_prune_kills_the_session_of_a_removed_worktree
      setup_app_project
      git(path("app"), "worktree", "remove", path("worktrees", "app", "feat"))
      live = [sess("sb/app/app"), sess("sb/app/feat")]
      assert_equal ["sb/app/feat"], run_prune(live),
                   "a removed worktree's session is no longer backed → pruned"
    end

    def test_prune_dry_run_kills_nothing_but_reports
      setup_app_project
      live = [sess("sb/app/gone"), sess("sb/app/app"), sess("sb/app/feat")]
      killed = []
      report = with_tmux(live, current: nil, killer: ->(n) { killed << n }) do
        Reconcile.prune(Config.new, dry_run: true, now: NOW)
      end
      assert_empty killed, "dry run never kills"
      assert_equal ["sb/app/gone"], report.orphans
      assert report.reachable
    end

    # CRITICAL (F1): a project whose repo dir is gone is dropped by Model, so its
    # live sessions match no verified prefix and are LEFT ALONE.
    def test_prune_leaves_unverifiable_projects_alone
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "ghost", "path" => path("missing-repo") }]))
      live = [sess("sb/ghost/x"), sess("sb/home")]
      killed = run_prune(live)
      assert_empty killed, "a missing-dir project's sessions are never pruned"
    end

    def test_prune_reports_unreachable_when_no_tmux_server
      setup_app_project
      killed = []
      report = with_tmux(nil, current: nil, killer: ->(n) { killed << n }) do
        Reconcile.prune(Config.new, now: NOW)
      end
      refute report.reachable
      assert_empty report.orphans
      assert_empty killed
    end

    def test_prune_reachable_with_no_sb_sessions
      setup_app_project
      killed = []
      report = with_tmux([], current: nil, killer: ->(n) { killed << n }) do
        Reconcile.prune(Config.new, now: NOW)
      end
      assert report.reachable, "[] means the server is up, just no sb/ sessions"
      assert_equal 0, report.sb_count
      assert_empty report.orphans
      assert_empty killed
    end

    private

    # A verified project "app" with the primary checkout + one real worktree
    # ("feat"), registered in the sandbox config. Yields session names
    # sb/app/app (primary) and sb/app/feat.
    def setup_app_project
      repo = temp_git_repo("app")
      wt = path("worktrees", "app", "feat")
      FileUtils.mkdir_p(File.dirname(wt))
      git(repo, "worktree", "add", "-q", "-b", "feat", wt)
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
    end

    def run_prune(live)
      killed = []
      with_tmux(live, current: nil, killer: ->(n) { killed << n }) do
        Reconcile.prune(Config.new, now: NOW)
      end
      killed
    end

    def with_tmux(live, current:, killer:)
      stub_method(Tmux, :sessions, -> { live }) do
        stub_method(Tmux, :session_of, ->(*) { current }) do
          stub_method(Tmux, :kill_session, ->(name) { killer.call(name); true }) do
            return yield
          end
        end
      end
    end
  end
end
