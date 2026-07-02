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

    # --- count_sidebar_panes: the pure pane-title tally (drives doctor's orphan
    # check). Counts only panes titled exactly SIDEBAR_TITLE across `list-panes -a`.

    def test_count_sidebar_panes_counts_only_exact_sidebar_titles
      raw = "#{Tmux::SIDEBAR_TITLE}\n✳ Claude Code\n#{Tmux::SIDEBAR_TITLE}\nmy-host\n"
      assert_equal 2, Tmux.count_sidebar_panes(raw)
    end

    def test_count_sidebar_panes_ignores_titles_that_merely_contain_the_marker
      # An exact match only — a work pane whose title embeds the marker can't inflate it.
      raw = "#{Tmux::SIDEBAR_TITLE}-stale\nnot-#{Tmux::SIDEBAR_TITLE}\n"
      assert_equal 0, Tmux.count_sidebar_panes(raw)
    end

    def test_count_sidebar_panes_empty_input
      assert_equal 0, Tmux.count_sidebar_panes("")
    end

    # --- parse_ttys / parse_sidebar_processes / normalize_tty: the pure inputs to
    # prune's orphaned-sidebar reap (a sidebar process whose tty is no live pane).

    def test_parse_ttys_strips_dev_prefix_and_dedupes
      raw = "/dev/ttys001\n/dev/ttys002\n/dev/ttys001\n"
      assert_equal Set["ttys001", "ttys002"], Tmux.parse_ttys(raw)
    end

    def test_parse_ttys_drops_no_tty_markers_and_blanks
      # A pane with no tty ("??"/"-") must not seed a tty that a no-tty process matches.
      assert_equal Set["pts/3"], Tmux.parse_ttys("/dev/pts/3\n??\n-\n\n")
    end

    def test_parse_sidebar_processes_keeps_only_sidebar_rows_with_pid_and_tty
      raw = +"  101 ttys005 ruby /x/bin/switchboard sidebar\n"
      raw << "  202 ttys006 ruby /x/bin/switchboard prune\n"        # not a sidebar
      raw << "  303 ?? ruby /x/bin/switchboard sidebar\n"           # no tty -> tty nil
      assert_equal [[101, "ttys005"], [303, nil]], Tmux.parse_sidebar_processes(raw)
    end

    def test_parse_sidebar_processes_ignores_a_header_or_garbled_line
      raw = "PID TTY COMMAND\n\nnotanumber ttys001 switchboard sidebar\n"
      assert_empty Tmux.parse_sidebar_processes(raw)
    end

    def test_normalize_tty_bridges_dev_prefix_and_no_tty_markers
      assert_equal "ttys048", Tmux.normalize_tty("/dev/ttys048")
      assert_equal "pts/3", Tmux.normalize_tty("pts/3")
      assert_nil Tmux.normalize_tty("??")
      assert_nil Tmux.normalize_tty("  ")
    end

    # --- parse_window_panes: the pure count parse behind the #64 lone-pane check.
    # A confirmed integer drives the "am I the only pane?" decision; anything
    # empty/garbled is "unknown" -> nil -> the caller keeps running (degrade, never
    # self-terminate on a flaky shell-out — the owns_pane? house rule).

    def test_parse_window_panes_reads_a_count
      assert_equal 1, Tmux.parse_window_panes("1\n")
      assert_equal 2, Tmux.parse_window_panes("  2  ")
    end

    def test_parse_window_panes_is_nil_on_empty_or_garbled_input
      assert_nil Tmux.parse_window_panes(""), "no reply (no server / dead pane) -> unknown"
      assert_nil Tmux.parse_window_panes("\n")
      assert_nil Tmux.parse_window_panes("nonsense"), "a non-numeric reply rescues to nil, never raises"
      assert_nil Tmux.parse_window_panes("2 panes"), "a partial/garbled line is not a usable count"
    end

    # --- parse_window_size / new_session_cmd: build a detached session at the
    # client's size so switching into it never reflows 80x24 -> client (the
    # "creating" flash). The parse is pure; the argv assembly is testable via the
    # current_window_size seam.

    def test_parse_window_size_reads_a_width_height_pair
      assert_equal [220, 50], Tmux.parse_window_size("220,50\n")
      assert_equal [80, 24], Tmux.parse_window_size("  80,24  ")
    end

    def test_parse_window_size_is_a_nil_pair_on_empty_or_garbled_input
      assert_equal [nil, nil], Tmux.parse_window_size(""), "no reply -> unknown, fall back to default sizing"
      assert_equal [nil, nil], Tmux.parse_window_size("220"), "a half pair is not a usable size"
      assert_equal [nil, nil], Tmux.parse_window_size("x,y"), "a non-numeric reply rescues to the nil pair, never raises"
    end

    def test_new_session_cmd_sizes_the_session_to_the_current_window
      stub_method(Tmux, :current_window_size, -> { [220, 50] }) do
        cmd = Tmux.new_session_cmd("sb/app/x", "/wt/x")
        assert_equal ["tmux", "new-session", "-d", "-s", "sb/app/x", "-c", "/wt/x", "-x", "220", "-y", "50"], cmd
      end
    end

    def test_new_session_cmd_omits_the_size_when_unknown
      # Off-tmux (no current window): no -x/-y, so the exec-attach path sizes the
      # window on attach exactly as before.
      stub_method(Tmux, :current_window_size, -> { [nil, nil] }) do
        cmd = Tmux.new_session_cmd("sb/app/x", "/wt/x")
        assert_equal ["tmux", "new-session", "-d", "-s", "sb/app/x", "-c", "/wt/x"], cmd
      end
    end

    def test_new_session_cmd_omits_a_zero_dimension
      # A 0 dim (an openpty that came up 0x0) would make `new-session -x 0` fail
      # ("width too small") and create NOTHING — worse than the 80x24 default.
      # Only a positive pair is applied; otherwise fall back to the default.
      stub_method(Tmux, :current_window_size, -> { [0, 50] }) do
        cmd = Tmux.new_session_cmd("sb/app/x", "/wt/x")
        assert_equal ["tmux", "new-session", "-d", "-s", "sb/app/x", "-c", "/wt/x"], cmd,
                     "a non-positive dimension is dropped, not passed as -x 0"
      end
    end

    # --- ensure_work_pane: only splits a shell when the sidebar is the SOLE pane
    # (#64 home self-heal / fall-home landing). The two short-circuits are the
    # testable guards; the actual split is a raw shell-out, covered by the smoke layer.

    def test_ensure_work_pane_noops_when_a_work_pane_already_exists
      stub_method(Tmux, :window_sidebar_pane, ->(*) { "%1" }) do
        stub_method(Tmux, :window_panes, ->(*) { 2 }) do # already has a work sibling
          assert_nil Tmux.ensure_work_pane("sb/home"), "a healthy window is left untouched"
        end
      end
    end

    def test_ensure_work_pane_noops_when_there_is_no_sidebar_pane
      stub_method(Tmux, :window_sidebar_pane, ->(*) { nil }) do
        assert_nil Tmux.ensure_work_pane("sb/home"), "nothing to sit a work pane beside"
      end
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

    # --- reusable_editor_pane: the pure `e` reuse gate ------------------------
    # `e` stashes its editor pane on home; the next `e` reuses it iff it's still
    # a live home pane, so editor panes can't pile up (the accumulation bug).

    def test_reusable_editor_pane_returns_the_stashed_id_when_still_live
      assert_equal "%3", Tmux.reusable_editor_pane("%3", ["%0", "%1", "%3"])
    end

    def test_reusable_editor_pane_is_nil_when_the_editor_pane_is_gone
      # :q closed the pane; the retired id is absent -> spawn a fresh editor.
      assert_nil Tmux.reusable_editor_pane("%3", ["%0", "%1"])
    end

    def test_reusable_editor_pane_is_nil_when_nothing_is_stashed
      # Option unset -> show-options -v yields "" -> no pane to reuse.
      assert_nil Tmux.reusable_editor_pane("", ["%0", "%1"])
      assert_nil Tmux.reusable_editor_pane("", [])
    end

    # --- pane_switch_keys: the user's own select-pane bindings, surfaced in the ?
    # overlay (issue #62). Pure given the `tmux list-keys -T prefix` output.

    def test_pane_switch_keys_collapses_arrows_and_keeps_letters
      raw = <<~KEYS
        bind-key -T prefix Left select-pane -L
        bind-key -T prefix Right select-pane -R
        bind-key -T prefix Up select-pane -U
        bind-key -T prefix Down select-pane -D
        bind-key -T prefix o select-pane -t :.+
        bind-key -T prefix h select-pane -L
        bind-key -T prefix C-Left resize-pane -L
        bind-key -T prefix x kill-pane
      KEYS
      # all four arrows collapse to one glyph token; o + h kept; resize/kill excluded
      assert_equal ["↑↓←→", "o", "h"], Tmux.pane_switch_keys(raw)
    end

    def test_pane_switch_keys_does_not_collapse_a_partial_arrow_set
      raw = "bind-key -T prefix Left select-pane -L\nbind-key -T prefix Right select-pane -R\n"
      assert_equal ["←", "→"], Tmux.pane_switch_keys(raw), "only ←→ bound -> shown separately, not collapsed"
    end

    def test_pane_switch_keys_empty_when_none_or_unparseable
      assert_empty Tmux.pane_switch_keys(""), "no server / no output -> [] (overlay omits the row)"
      assert_empty Tmux.pane_switch_keys("bind-key -T prefix o next-window\n"), "non-select-pane bindings ignored"
    end

    # Only MOVEMENT select-pane counts — mark/unmark (-m/-M) are select-pane commands
    # but not "move between panes", so they're excluded from the overlay row.
    def test_pane_switch_keys_excludes_mark_and_unmark
      raw = "bind-key -T prefix m select-pane -m\nbind-key -T prefix M select-pane -M\n" \
            "bind-key -T prefix Left select-pane -L\n"
      assert_equal ["←"], Tmux.pane_switch_keys(raw), "mark/unmark dropped; the directional move kept"
    end

    def test_pane_switch_keys_caps_the_list
      raw = %w[a b c d e f g].map { |k| "bind-key -T prefix #{k} select-pane -t :.+" }.join("\n")
      assert_equal 5, Tmux.pane_switch_keys(raw).size, "capped so the overlay row can't overrun the pane"
    end

    def test_pane_switch_keys_collapses_the_vim_cluster
      raw = %w[h j k l].map { |k| "bind-key -T prefix #{k} select-pane -L" }.join("\n")
      assert_equal ["hjkl"], Tmux.pane_switch_keys(raw), "a full hjkl set shows as one token, not four"
    end

    # --- spawn width clamp: a saved width can't starve the work pane (issue #78) ---

    def test_fit_width_returns_the_saved_width_on_a_roomy_window
      assert_equal 76, Tmux.fit_width(76, 200)
    end

    def test_fit_width_clamps_to_leave_room_for_the_work_pane
      assert_equal 68, Tmux.fit_width(76, 80), "80-col client, 76 saved -> 68 so the work pane keeps 12"
    end

    def test_fit_width_uses_the_saved_width_when_cols_is_unknown
      assert_equal 76, Tmux.fit_width(76, nil), "no window size -> the historic behavior"
    end

    def test_fit_width_stays_positive_on_a_tiny_window
      assert_operator Tmux.fit_width(40, 8), :>=, 1, "never emit a non-positive -l"
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

    # --- kill_project_sessions: only one project's sessions, current LAST -----

    def test_kill_project_sessions_kills_only_that_projects_sessions
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/app/y", created: 2 },
              { name: "sb/other/z", created: 3 }, { name: "sb/home", created: 4 }]
      order = []
      result = with_tmux_stubs(live, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_project_sessions("app")
      end
      assert_equal %w[sb/app/x sb/app/y], order, "leaves other projects and home alone"
      assert_equal %w[sb/app/x sb/app/y], result
    end

    def test_kill_project_sessions_kills_current_last
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/app/here", created: 2 }]
      order = []
      with_tmux_stubs(live, current: "sb/app/here", recorder: ->(name) { order << name }) do
        Tmux.kill_project_sessions("app")
      end
      assert_equal %w[sb/app/x sb/app/here], order, "the session we're in dies last"
    end

    # The trailing-slash prefix means project "app" never claims "app2"'s sessions.
    def test_kill_project_sessions_does_not_over_kill_a_prefix_sibling
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/app2/y", created: 2 }]
      order = []
      with_tmux_stubs(live, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_project_sessions("app")
      end
      assert_equal %w[sb/app/x], order, "app2 is a different project, untouched"
    end

    def test_kill_project_sessions_is_empty_when_no_server
      result = with_tmux_stubs(nil, current: nil, recorder: ->(_n) {}) do
        Tmux.kill_project_sessions("app")
      end
      assert_empty result
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

    # --- poke_window: the same-session window-switch poke (gated to sb/) --------

    def test_poke_window_pokes_an_sb_windows_sidebar
      poked = :unset
      stub_method(Tmux, :session_of_window, ->(_w) { "sb/app/x" }) do
        stub_method(Tmux, :window_sidebar_pane, ->(_w) { "%9" }) do
          stub_method(Tmux, :poke, ->(pane) { poked = pane }) do
            Tmux.poke_window("@3")
          end
        end
      end
      assert_equal "%9", poked, "an sb/ window's sidebar gets the C-l reload poke"
    end

    # The hook is global — it fires on EVERY window switch in EVERY session. It must
    # do ~nothing on unrelated windows: one session lookup, then bail before any poke.
    def test_poke_window_is_a_noop_for_a_non_sb_session
      poked = false
      stub_method(Tmux, :session_of_window, ->(_w) { "work" }) do
        stub_method(Tmux, :poke, ->(*) { poked = true }) do
          Tmux.poke_window("@3")
        end
      end
      refute poked, "the global hook never pokes a non-sb/ window"
    end

    def test_poke_window_is_a_noop_on_a_blank_window
      poked = false
      stub_method(Tmux, :poke, ->(*) { poked = true }) do
        Tmux.poke_window("")
      end
      refute poked
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
