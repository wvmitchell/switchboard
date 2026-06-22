# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The sidebar is now the only navigator (#17 removed the fzf picker), so its
  # navigation + rendering logic is the whole UX and worth pinning. It's a
  # stateful TUI with no E2E hook (needs a real tty), so we test white-box:
  # construct an instance, set the ivars the loop would, and drive the private
  # methods directly. The raw-tty primitives (read_key/setup/teardown/render-to-
  # stdout) stay out of scope — only the pure decisions are tested.
  #
  # Also covers the pure class-method helpers behind the background PR refresh
  # (issue #19): which agent transitions count as "a turn finished"
  # (completion_edges) and the per-project spawn debounce (spawn_due?).
  class SidebarTest < SandboxTest
    # --- node + sidebar builders --------------------------------------------

    def proj(name)
      Tree::Node.new(kind: "proj", project: name, path: "/repos/#{name}")
    end

    def ws(name, project: "app", path: nil, pr: nil)
      Tree::Node.new(kind: "ws", project: project, path: path || "/wt/#{name}", name: name, pr: pr)
    end

    def br(branch, active: false, last: false)
      Tree::Node.new(kind: "br", project: "app", branch: branch, active: active, last: last)
    end

    def sidebar(nodes: [], collapsed: [], cursor: 0, agents: {}, focused: true,
                current_path: nil, pulse: 0)
      sb = Sidebar.new
      sb.instance_variable_set(:@nodes, nodes)
      sb.instance_variable_set(:@collapsed, Set.new(collapsed))
      sb.instance_variable_set(:@agents, agents)
      sb.instance_variable_set(:@focused, focused)
      sb.instance_variable_set(:@current_path, current_path)
      sb.instance_variable_set(:@pulse, pulse)
      sb.send(:recompute_rows)                      # derive @rows from @nodes/@collapsed
      sb.instance_variable_set(:@cursor, cursor)    # set after: recompute_rows clamps it
      sb
    end

    def cursor_of(sb)  = sb.instance_variable_get(:@cursor)
    def rows_of(sb)    = sb.instance_variable_get(:@rows)
    def offset_of(sb)  = sb.instance_variable_get(:@offset)

    # --- navigation ----------------------------------------------------------

    def test_move_clamps_to_the_visible_rows
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:move, -1)
      assert_equal 0, cursor_of(sb), "can't move above the first row"
      sb.send(:move, 99)
      assert_equal 2, cursor_of(sb), "can't move past the last row"
    end

    def test_move_is_a_noop_with_no_rows
      sb = sidebar(nodes: [])
      sb.send(:move, 1)
      assert_equal 0, cursor_of(sb)
    end

    def test_toggle_collapse_hides_then_shows_a_projects_children
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      assert_equal 3, rows_of(sb).size
      sb.send(:toggle_collapse, "app")
      assert_equal 1, rows_of(sb).size, "collapsed project hides its workspaces"
      sb.send(:toggle_collapse, "app")
      assert_equal 3, rows_of(sb).size
    end

    def test_enter_on_a_project_header_collapses_it
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      sb.send(:enter)
      assert_includes sb.instance_variable_get(:@collapsed), "app"
    end

    def test_enter_on_a_workspace_switches_to_it_threading_the_session_command
      # Pin that switch() threads the project's resolved session_command into
      # Tmux.go(start:), not just the worktree.
      File.write(Config.path, YAML.dump("session_command" => "claude",
                                        "projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      target = nil
      started = :unset
      stub_method(Tmux, :go, ->(worktree, start:) { target = worktree; started = start }) do
        sb.send(:enter)
      end
      assert_equal "/wt/a", target.path
      assert_equal "claude", started
    end

    def test_dispatch_routes_movement_and_jump_keys
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:dispatch, "j")
      assert_equal 1, cursor_of(sb)
      sb.send(:dispatch, "k")
      assert_equal 0, cursor_of(sb)
      sb.send(:dispatch, "G")
      assert_equal 2, cursor_of(sb)
      sb.send(:dispatch, "g")
      assert_equal 0, cursor_of(sb)
    end

    def test_jump_keys_stay_in_bounds_on_an_empty_tree
      sb = sidebar(nodes: [])
      sb.send(:dispatch, "G")
      assert_equal 0, cursor_of(sb), "G on an empty tree must not go negative"
      sb.send(:dispatch, "g")
      assert_equal 0, cursor_of(sb)
    end

    def test_dispatch_q_signals_exit_other_keys_keep_running
      sb = sidebar(nodes: [proj("app")])
      # Stub the session lookup so q's hide path never touches a real tmux.
      stub_method(Tmux, :session_of, ->(*) { nil }) do
        refute sb.send(:dispatch, "q"), "q exits the loop"
        assert sb.send(:dispatch, "j"), "movement keeps the loop alive"
      end
    end

    # q hides session-wide (like prefix-s): persists @sb_sidebar off and
    # reconciles the session closed, sparing its own pane for the loop to close.
    def test_q_hides_the_whole_session_and_persists_the_off_flag
      sb = sidebar(nodes: [proj("app")])
      flag = nil
      reconciled = nil
      stub_method(Tmux, :session_of, ->(*) { "sb/app/x" }) do
        stub_method(Tmux, :set_sidebar_flag, ->(s, v) { flag = [s, v] }) do
          stub_method(Tmux, :reconcile_sidebars, ->(s, on, **kw) { reconciled = [s, on, kw] }) do
            refute sb.send(:dispatch, "q"), "q still exits the loop"
          end
        end
      end
      assert_equal ["sb/app/x", "off"], flag, "persists the off intent on the session"
      assert_equal "sb/app/x", reconciled[0]
      refute reconciled[1], "reconciles the session closed"
      assert reconciled[2].key?(:except), "spares its own pane from the kill sweep"
    end

    def test_handle_processes_every_token_in_a_key_repeat_buffer
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:handle, "jj") # a held 'j' arrives as one multi-byte read
      assert_equal 2, cursor_of(sb)
    end

    def test_handle_returns_false_when_a_token_quits
      sb = sidebar(nodes: [proj("app")])
      refute sb.send(:handle, "q")
    end

    def test_locate_marks_the_workspace_the_pane_sits_in
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")])
      stub_method(Tmux, :pane_path, ->(_pane) { "/wt/b/sub" }) do
        sb.send(:locate)
      end
      assert_equal "/wt/b", sb.instance_variable_get(:@current_path)
    end

    # --- scrolling -----------------------------------------------------------

    def test_scroll_keeps_the_cursor_within_the_window
      nodes = [proj("app")] + Array.new(20) { |i| ws("w#{i}") }
      sb = sidebar(nodes: nodes, cursor: 15)
      sb.send(:scroll, 10) # window height 10
      off = offset_of(sb)
      assert off <= 15 && 15 < off + 10, "cursor 15 should be visible in [#{off}, #{off + 10})"
    end

    def test_scroll_offset_never_goes_negative
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      sb.send(:scroll, 10)
      assert_equal 0, offset_of(sb)
    end

    # --- render primitives ---------------------------------------------------

    def test_trunc_ellipsizes_and_handles_zero_width
      sb = sidebar
      assert_equal "ab…", sb.send(:trunc, "abcdef", 3)
      assert_equal "abc", sb.send(:trunc, "abc", 3)
      assert_equal "", sb.send(:trunc, "abc", 0)
    end

    def test_dot_for_maps_state_to_a_glyph
      sb = sidebar(pulse: 0)
      assert_equal Sidebar::DONE, sb.send(:dot_for, :done)
      assert_equal Sidebar::WANTS_ON, sb.send(:dot_for, :waiting), "blink starts lit at pulse 0"
      assert_equal Sidebar::SPIN_COLORED[0], sb.send(:dot_for, :thinking)
      assert_equal " ", sb.send(:dot_for, nil), "idle is a blank slot"
    end

    def test_spinner_advances_with_pulse
      frames = Sidebar::SPIN_COLORED
      assert_equal frames[1], sidebar(pulse: 1).send(:dot_for, :thinking), "next pulse, next frame"
      refute_equal frames[0], frames[1], "frames are distinct"
      assert_equal frames[0], sidebar(pulse: frames.size).send(:dot_for, :thinking), "wraps around"
    end

    def test_waiting_blink_toggles
      assert_equal Sidebar::WANTS_ON, sidebar(pulse: 0).send(:dot_for, :waiting)
      assert_equal Sidebar::WANTS_OFF, sidebar(pulse: Sidebar::BLINK_PERIOD).send(:dot_for, :waiting),
                   "flips to hollow one BLINK_PERIOD later"
    end

    # The bare (uncolored) glyph backs both plain and the reverse-video selected row.
    def test_glyph_for_is_the_bare_shape
      sb = sidebar(pulse: 0)
      assert_equal Sidebar::SPIN_FRAMES[0], sb.send(:glyph_for, :thinking), "no color escape"
      assert_equal "◆", sb.send(:glyph_for, :waiting)
      assert_equal "◇", sidebar(pulse: Sidebar::BLINK_PERIOD).send(:glyph_for, :waiting)
      assert_equal "●", sb.send(:glyph_for, :done)
      assert_equal " ", sb.send(:glyph_for, nil)
    end

    def test_plain_renders_each_node_kind
      sb = sidebar(agents: { "/wt/a" => :done })
      assert_equal "▾ app", sb.send(:plain, proj("app"))
      assert_equal "  ● a", sb.send(:plain, ws("a", path: "/wt/a")), "agent fills the dot slot"
      assert_equal "    b", sb.send(:plain, ws("b", path: "/wt/b")), "no agent leaves it blank"
      assert_equal "     └●main", sb.send(:plain, br("main", active: true, last: true))
      assert_equal "     ├ feat", sb.send(:plain, br("feat"))
    end

    def test_plain_uses_the_collapsed_glyph
      sb = sidebar(collapsed: ["app"])
      assert_equal "▸ app", sb.send(:plain, proj("app"))
    end

    def test_colored_project_is_bold
      sb = sidebar
      assert_equal "\e[1m▾ app\e[0m", sb.send(:colored, proj("app"), "▾ app")
    end

    def test_line_draws_a_reverse_video_bar_only_for_the_focused_cursor_row
      focused = sidebar(focused: true)
      assert_includes focused.send(:line, proj("app"), true, 20), "\e[7m"
      unfocused = sidebar(focused: false)
      refute_includes unfocused.send(:line, proj("app"), true, 20), "\e[7m",
                      "off-focus, the cursor row renders like any other"
    end

    # --- reconcile_on_launch (issue #7) --------------------------------------

    def test_reconcile_on_launch_prunes_with_the_sidebar_config
      sb = sidebar
      cfg = sb.instance_variable_get(:@config)
      got = :unset
      stub_method(Reconcile, :prune, ->(c, **) { got = c; nil }) do
        sb.send(:reconcile_on_launch)
      end
      assert_same cfg, got, "reconcile_on_launch passes the sidebar's @config to prune"
    end

    def test_reconcile_on_launch_swallows_errors
      sb = sidebar
      stub_method(Reconcile, :prune, ->(*) { raise "tmux exploded" }) do
        assert_nil sb.send(:reconcile_on_launch), "a prune failure must never crash the sidebar"
      end
    end

    # --- session-switch poke throttle (reload storm) -------------------------

    def test_reload_due_initially_then_throttled_then_due_again
      sb = sidebar
      assert sb.send(:reload_due?), "first reload (no prior) is always due"
      sb.instance_variable_set(:@last_reload, sb.send(:monotonic))
      refute sb.send(:reload_due?), "a reload within POKE_TTL is throttled"
      sb.instance_variable_set(:@last_reload, sb.send(:monotonic) - Sidebar::POKE_TTL - 1)
      assert sb.send(:reload_due?), "after the window it's due again"
    end

    # Resuming several sessions at once pokes each sidebar in quick succession;
    # the heavy git+capture-pane reload must fire at most once per POKE_TTL.
    def test_rapid_switch_pokes_coalesce_into_one_reload
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { reloads += 1; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }            # neutralize the tmux call
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      sb.send(:reload_and_refresh) # due -> reloads
      sb.send(:reload_and_refresh) # within POKE_TTL -> locate only, no reload
      sb.send(:reload_and_refresh)
      assert_equal 1, reloads, "rapid switch pokes coalesce into a single heavy reload"
    end

    def test_poke_reloads_again_once_the_window_passes
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { reloads += 1; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      sb.send(:reload_and_refresh)                                    # reload #1
      sb.instance_variable_set(:@last_reload, sb.send(:monotonic) - Sidebar::POKE_TTL - 1)
      sb.send(:reload_and_refresh)                                    # window passed -> reload #2
      assert_equal 2, reloads
    end

    # --- live-state icons (#23) ----------------------------------------------

    def test_plain_shows_live_state_glyph_for_workspaces
      sb = sidebar(agents: { "/wt/a" => :thinking }, pulse: 0)
      assert_equal "  #{Sidebar::SPIN_FRAMES[0]} a", sb.send(:plain, ws("a", path: "/wt/a")),
                   "plain carries the bare spinner glyph (not a static dot)"
    end

    # Review D3 / Codex: the new icons must survive on the focused cursor row,
    # which is drawn from plain() under reverse-video (color stripped, shape kept).
    def test_focused_row_shows_live_state_glyph
      sb = sidebar(nodes: [ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking },
                   focused: true, pulse: 0)
      line0 = sb.send(:line, ws("a", path: "/wt/a"), true, 30)
      assert_includes line0, "\e[7m", "focused cursor row is a reverse-video bar"
      assert_includes line0, Sidebar::SPIN_FRAMES[0], "live spinner shows even on the selected row"
      refute_includes line0, "\e[1;34m", "shape only — color is stripped under reverse video"

      sb.instance_variable_set(:@pulse, 1)
      assert_includes sb.send(:line, ws("a", path: "/wt/a"), true, 30), Sidebar::SPIN_FRAMES[1],
                      "and it advances with @pulse"
    end

    # --- pulsing?: animate only for thinking/waiting dots actually on screen ----

    def test_pulsing_wakes_for_thinking_or_waiting
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@was_visible, true)
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      assert sb.send(:pulsing?), "a visible thinking dot pulses"

      sb.instance_variable_set(:@agents, { "/wt/a" => :waiting })
      assert sb.send(:pulsing?), "a visible waiting dot pulses (the blink)"

      sb.instance_variable_set(:@agents, { "/wt/a" => :done })
      refute sb.send(:pulsing?), "a done dot is steady — no pulse"
    end

    def test_pulsing_ignores_offscreen_agents
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")],
                   agents: { "/wt/b" => :thinking })
      sb.instance_variable_set(:@was_visible, true)
      on_screen = ->(p) { rows_of(sb).select { |n| n.path == p } }

      sb.instance_variable_set(:@visible_rows, on_screen.call("/wt/a"))
      refute sb.send(:pulsing?), "a thinking dot scrolled off screen doesn't pulse"

      sb.instance_variable_set(:@visible_rows, on_screen.call("/wt/b"))
      assert sb.send(:pulsing?), "...but it pulses once it's on screen"
    end

    def test_pulsing_is_false_when_pane_hidden
      sb = sidebar(nodes: [ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      sb.instance_variable_set(:@was_visible, false)
      refute sb.send(:pulsing?), "a hidden pane never pulses, even with a thinking dot"
    end

    # --- completion_edges: a worktree newly at a resting state (issue #19) ----

    def test_thinking_to_done_is_an_edge
      assert_equal ["/a"], Sidebar.completion_edges({ "/a" => :thinking }, { "/a" => :done })
    end

    def test_entering_waiting_is_an_edge
      assert_equal ["/a"], Sidebar.completion_edges({ "/a" => :thinking }, { "/a" => :waiting })
    end

    def test_first_appearance_at_done_is_not_an_edge
      # A path absent from prev is the agent announcing presence (SessionStart on a
      # freshly-created workspace reports :done) — it seeds the baseline, it does
      # not ring the completion sound or spawn a PR refresh. (The post-seed
      # completion sequence is covered by the on_agent_edges integration tests.)
      assert_empty Sidebar.completion_edges({}, { "/a" => :done })
    end

    def test_steady_done_is_not_an_edge
      assert_empty Sidebar.completion_edges({ "/a" => :done }, { "/a" => :done })
    end

    def test_returning_to_thinking_is_not_an_edge
      assert_empty Sidebar.completion_edges({ "/a" => :done }, { "/a" => :thinking })
    end

    def test_aging_out_is_not_an_edge
      assert_empty Sidebar.completion_edges({ "/a" => :done }, {})
    end

    def test_only_changed_paths_count
      prev = { "/a" => :done, "/b" => :thinking }
      now  = { "/a" => :done, "/b" => :done }
      assert_equal ["/b"], Sidebar.completion_edges(prev, now)
    end

    # --- spawn_due?: per-project debounce (issue #19) ------------------------

    def test_spawn_due_when_never_spawned
      assert Sidebar.spawn_due?(nil, 100.0)
    end

    def test_not_spawn_due_within_window
      refute Sidebar.spawn_due?(100.0, 102.0, 5)
    end

    def test_spawn_due_after_window
      assert Sidebar.spawn_due?(100.0, 106.0, 5)
    end

    def test_spawn_due_exactly_at_window
      assert Sidebar.spawn_due?(100.0, 105.0, 5)
    end

    # --- on_agent_edges: PR refresh + sound ride the same edge ----------------
    #
    # The refactor that folded the sound trigger in must not break the existing
    # PR-refresh trigger (which the suite only covered statically via
    # completion_edges). These drive the integration: first-scan skip, dual
    # dispatch, and the load-bearing guarantee that @prev_hook_states ALWAYS
    # advances so a fault can't corrupt the next edge diff.

    # Feed on_agent_edges a fixed hook-state snapshot (stands in for AgentState).
    def set_hook_states(sb, states)
      sb.instance_variable_set(:@agent_state, Struct.new(:last_hook_states).new(states))
    end

    def test_on_agent_edges_skips_the_first_scan
      sb = sidebar(nodes: [ws("a", path: "/wt/a")])
      set_hook_states(sb, { "/wt/a" => :done })
      sb.instance_variable_set(:@prev_hook_states, nil) # no baseline yet
      prs = []
      sounds = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| prs << p }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        sb.send(:on_agent_edges)
      end
      assert_empty prs, "no baseline -> no PR refresh on first scan"
      assert_empty sounds, "no baseline -> no sound on first scan"
      assert_equal({ "/wt/a" => :done }, sb.instance_variable_get(:@prev_hook_states))
    end

    def test_on_agent_edges_dispatches_pr_and_sound_on_an_edge
      sb = sidebar(nodes: [ws("a", project: "app", path: "/wt/a")])
      set_hook_states(sb, { "/wt/a" => :done })
      sb.instance_variable_set(:@prev_hook_states, { "/wt/a" => :thinking })
      prs = []
      sounds = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| prs << p }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        sb.send(:on_agent_edges)
      end
      assert_equal ["app"], prs            # PR trigger survives the refactor
      assert_equal ["train"], sounds       # :done -> default train
      assert_equal({ "/wt/a" => :done }, sb.instance_variable_get(:@prev_hook_states))
    end

    def test_on_agent_edges_advances_baseline_even_when_sound_raises
      sb = sidebar(nodes: [ws("a", path: "/wt/a")])
      set_hook_states(sb, { "/wt/a" => :waiting })
      sb.instance_variable_set(:@prev_hook_states, { "/wt/a" => :thinking })
      sb.define_singleton_method(:maybe_refresh_prs) { |_p| }
      stub_method(Sound, :play, ->(*) { raise "boom" }) do
        sb.send(:on_agent_edges) # must not raise — play_sounds_for rescues
      end
      assert_equal({ "/wt/a" => :waiting }, sb.instance_variable_get(:@prev_hook_states))
    end

    def test_completion_fires_after_a_worktree_ages_out_and_returns
      # A tool running longer than PRESENCE_TTL ages the :thinking report out of
      # the live scan; then Stop reports :done. The sticky baseline keeps
      # :thinking, so the completion still fires — not mistaken for a first
      # appearance and swallowed.
      sb = sidebar(nodes: [ws("a", project: "app", path: "/wt/a")])
      sb.instance_variable_set(:@prev_hook_states, nil)
      sb.define_singleton_method(:maybe_refresh_prs) { |_p| }
      sounds = []
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        set_hook_states(sb, { "/wt/a" => :thinking }); sb.send(:on_agent_edges) # seen thinking
        set_hook_states(sb, {});                       sb.send(:on_agent_edges) # aged out of scan
        set_hook_states(sb, { "/wt/a" => :done });     sb.send(:on_agent_edges) # completes
      end
      assert_equal ["train"], sounds
    end

    def test_restarted_session_after_aging_out_stays_silent
      # First appearance at :done (SessionStart) is silent and seeds the baseline.
      # After it ages out, a NEW session's SessionStart :done matches the
      # remembered :done — a non-change, so no spurious sound.
      sb = sidebar(nodes: [ws("a", project: "app", path: "/wt/a")])
      sb.instance_variable_set(:@prev_hook_states, nil)
      sb.define_singleton_method(:maybe_refresh_prs) { |_p| }
      sounds = []
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        set_hook_states(sb, { "/wt/a" => :done }); sb.send(:on_agent_edges) # SessionStart (first)
        set_hook_states(sb, {});                   sb.send(:on_agent_edges) # aged out
        set_hook_states(sb, { "/wt/a" => :done }); sb.send(:on_agent_edges) # SessionStart (restart)
      end
      assert_empty sounds
    end

    def test_play_sounds_for_one_sound_per_worktree_mapped_by_state
      sb = sidebar(nodes: [ws("a", project: "app", path: "/wt/a"),
                           ws("b", project: "app", path: "/wt/b")])
      sounds = []
      now = { "/wt/a" => :done, "/wt/b" => :waiting }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        sb.send(:play_sounds_for, ["/wt/a", "/wt/b"], now)
      end
      assert_equal %w[train chime], sounds # each distinct worktree heard, by state
    end

    def test_play_sounds_for_silent_when_muted
      File.write(Config.path, YAML.dump("sounds" => { "enabled" => false }))
      sb = sidebar(nodes: [ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@config, Config.new)
      played = []
      stub_method(Sound, :play, ->(spec, **) { played << spec if spec }) do
        sb.send(:play_sounds_for, ["/wt/a"], { "/wt/a" => :done })
      end
      assert_empty played # sound_for -> nil, so nothing is actually played
    end

    # --- reload_config_and_rebuild: the post-edit (Ctrl-R) reload -------------
    # `e` lets you hand-edit raw YAML, so a syntax slip is expected. A bad save
    # must NOT tear the sidebar down: keep the last good @config and surface the
    # error on tmux's status line (Tmux.notify) instead.

    def test_reload_config_and_rebuild_keeps_last_good_config_on_bad_yaml
      File.write(Config.path, YAML.dump("worktree_root" => "~/wt", "projects" => []))
      sb = sidebar(nodes: [])
      good = Config.new
      sb.instance_variable_set(:@config, good)

      File.write(Config.path, "a: : :\n  - broken") # now invalid YAML
      captured = nil
      stub_method(Tmux, :notify, ->(msg) { captured = msg }) do
        sb.send(:reload_config_and_rebuild)
      end

      assert_same good, sb.instance_variable_get(:@config), "kept the last good config on a parse error"
      assert_match(/config not reloaded/, captured.to_s, "surfaced the error via tmux notify")
    end
  end
end
