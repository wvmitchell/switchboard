# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Tmux is almost all shell-outs, so the unit-testable surface is the pure
  # parse (sb_sessions), the name builders (session_name/session_prefix sharing
  # one sanitization), and the orchestration whose ORDER matters (kill_all kills
  # the current session last). The raw `tmux ...` calls themselves are covered by
  # the manual verification in the plan, not here.
  class TmuxTest < SandboxTest
    # --- sb_sessions: the pure list parse ------------------------------------

    def test_sb_sessions_keeps_only_sb_prefixed_and_parses_created
      raw = "sb/app/feat\t1700000000\nother\t1700000001\nsb/home\t1700000002\n"
      got = Tmux.sb_sessions(raw)
      assert_equal [{ name: "sb/app/feat", created: 1_700_000_000 },
                    { name: "sb/home", created: 1_700_000_002 }], got
    end

    def test_sb_sessions_drops_blank_lines_and_handles_missing_created
      raw = "\nsb/app/x\t\n"
      assert_equal [{ name: "sb/app/x", created: 0 }], Tmux.sb_sessions(raw)
    end

    def test_sb_sessions_does_not_match_bare_sb_without_slash
      # "sbx/..." must not be mistaken for one of ours — the boundary is "sb/".
      assert_empty Tmux.sb_sessions("sbx/app/x\t1\n")
    end

    def test_sb_sessions_empty_input
      assert_empty Tmux.sb_sessions("")
    end

    # --- name builders share one sanitization --------------------------------

    def test_session_prefix_matches_session_name_under_sanitization
      wt = Worktree.new(project: "app.dev", path: "/wt/feature one")
      prefix = Tmux.session_prefix("app.dev")
      assert_equal "sb/app-dev/", prefix
      assert Tmux.session_name(wt).start_with?(prefix),
             "session_name must start with its project's prefix (collision-safe diffing depends on it)"
    end

    def test_session_prefix_trailing_slash_disambiguates_app_from_app2
      refute Tmux.session_prefix("app2").start_with?(Tmux.session_prefix("app")),
             "the trailing / keeps app from prefix-matching app2"
    end

    # --- kill delegates to the single kill path ------------------------------

    def test_kill_delegates_to_kill_session_with_the_session_name
      wt = Worktree.new(project: "app", path: "/wt/feat")
      killed = nil
      stub_method(Tmux, :kill_session, ->(name) { killed = name; true }) do
        Tmux.kill(wt)
      end
      assert_equal "sb/app/feat", killed
    end

    # --- kill_all: current session dies LAST ---------------------------------

    def test_kill_all_kills_current_session_last_and_returns_all
      live = [{ name: "sb/app/x", created: 1 },
              { name: "sb/home", created: 2 },
              { name: "sb/cur/here", created: 3 }]
      order = []
      result = with_tmux_stubs(live, current: "sb/cur/here",
                               recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_equal %w[sb/app/x sb/home sb/cur/here], order, "current killed last"
      assert_equal %w[sb/app/x sb/home sb/cur/here], result
    end

    def test_kill_all_outside_a_session_kills_all_without_a_trailing_current
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/home", created: 2 }]
      order = []
      with_tmux_stubs(live, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_equal %w[sb/app/x sb/home], order
    end

    def test_kill_all_does_not_double_kill_when_current_is_not_a_switchboard_session
      # Run from a non-sb session: `current` is set but absent from the sb/ list,
      # so the "current last" branch must NOT fire (no second kill of a name).
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/home", created: 2 }]
      order = []
      result = with_tmux_stubs(live, current: "misc/scratch", recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_equal %w[sb/app/x sb/home], order, "a non-sb current session is never killed/double-killed"
      assert_equal %w[sb/app/x sb/home], result
    end

    def test_kill_all_is_empty_when_no_server
      order = []
      result = with_tmux_stubs(nil, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_empty result
      assert_empty order, "nothing killed when tmux is unreachable"
    end

    private

    # Stub the three Tmux seams kill_all leans on, then run the block.
    def with_tmux_stubs(live, current:, recorder:)
      stub_method(Tmux, :sessions, -> { live }) do
        stub_method(Tmux, :session_of, ->(*) { current }) do
          stub_method(Tmux, :kill_session, ->(name) { recorder.call(name); true }) do
            return yield
          end
        end
      end
    end
  end
end
