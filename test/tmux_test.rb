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

    # --- work_dir: the pure pane-cwd pick (drives the sidebar's -c) -----------
    # spawn_sidebar pins the sidebar pane's cwd to the worktree by reading the
    # window's work-pane path; if it picked the client's path instead the "you
    # are here" highlight wouldn't fire (locate matches the pane path to a node).

    def test_work_dir_picks_the_first_non_sidebar_panes_cwd
      raw = "#{Tmux::SIDEBAR_TITLE}\t/repo/primary\nbash\t/wt/feature\n"
      assert_equal "/wt/feature", Tmux.work_dir(raw)
    end

    def test_work_dir_preserves_paths_with_spaces
      raw = "vim\t/wt/feature one\n#{Tmux::SIDEBAR_TITLE}\t/repo/primary\n"
      assert_equal "/wt/feature one", Tmux.work_dir(raw)
    end

    def test_work_dir_is_nil_when_only_the_sidebar_is_present
      assert_nil Tmux.work_dir("#{Tmux::SIDEBAR_TITLE}\t/repo/primary\n")
      assert_nil Tmux.work_dir(""), "no panes (server gone) -> nil, so -c is just omitted"
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

    # --- toggle_sidebar: prefix-s is the one summon/dismiss verb --------------

    # Visible in the current window → dismiss session-wide: persist @sb_sidebar
    # off and reconcile the session closed. No focus move (nothing to focus).
    def test_toggle_sidebar_dismisses_when_the_tree_is_visible
      flag = nil
      reconciled = nil
      focused = false
      with_toggle_stubs(current_pane: "%9", on_flag: ->(s, v) { flag = [s, v] },
                        on_reconcile: ->(s, on) { reconciled = [s, on] },
                        on_focus: -> { focused = true }) do
        Tmux.toggle_sidebar
      end
      assert_equal ["sb/app/x", "off"], flag, "persists the off intent on the session"
      assert_equal ["sb/app/x", false], reconciled, "reconciles the session closed"
      refute focused, "dismiss never moves focus"
    end

    # Hidden in the current window → summon every window AND focus the new tree,
    # so prefix-s is the whole round-trip (the retired `h` left focus on the work
    # pane).
    def test_toggle_sidebar_summons_and_focuses_when_the_tree_is_hidden
      flag = nil
      reconciled = nil
      focused = false
      with_toggle_stubs(current_pane: nil, on_flag: ->(s, v) { flag = [s, v] },
                        on_reconcile: ->(s, on) { reconciled = [s, on] },
                        on_focus: -> { focused = true }) do
        Tmux.toggle_sidebar
      end
      assert_equal ["sb/app/x", "on"], flag, "persists the on intent on the session"
      assert_equal ["sb/app/x", true], reconciled, "reconciles the session open"
      assert focused, "summon drops focus into the tree"
    end

    private

    # Stub the seams toggle_sidebar drives: the session it reads, whether the
    # current window already shows a sidebar, and the three effects.
    def with_toggle_stubs(current_pane:, on_flag:, on_reconcile:, on_focus:)
      stub_method(Tmux, :current_session, -> { "sb/app/x" }) do
        stub_method(Tmux, :current_sidebar_pane, -> { current_pane }) do
          stub_method(Tmux, :set_sidebar_flag, ->(s, v) { on_flag.call(s, v) }) do
            stub_method(Tmux, :reconcile_sidebars, ->(s, on) { on_reconcile.call(s, on) }) do
              stub_method(Tmux, :focus_current_sidebar, -> { on_focus.call }) do
                return yield
              end
            end
          end
        end
      end
    end

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
