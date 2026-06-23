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
                current_path: nil, pulse: 0, attention: [])
      sb = Sidebar.new
      sb.instance_variable_set(:@nodes, nodes)
      sb.instance_variable_set(:@collapsed, Set.new(collapsed))
      sb.instance_variable_set(:@agents, agents)
      sb.instance_variable_set(:@attention, Set.new(attention))
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

    # A non-stop-token returns true so the buffer loop keeps running. Hide/show is
    # now prefix-s (Tmux.toggle_sidebar), so the sidebar has no in-loop hide key.
    def test_dispatch_movement_keeps_the_loop_alive
      sb = sidebar(nodes: [proj("app")])
      assert sb.send(:dispatch, "j"), "a non-stop-token keeps the loop alive"
    end

    # q tears down every sb/ session — but only after a y/N confirm. A confirmed
    # q kills all and exits the loop; an unconfirmed q kills nothing and keeps
    # the loop alive (so a stray q can't nuke everything by muscle memory).
    def test_q_quits_all_sessions_only_when_confirmed
      sb = sidebar(nodes: [proj("app")])
      killed = false
      stub_method(Tmux, :kill_all, ->(*) { killed = true; [] }) do
        stub_method(sb, :confirm, ->(*) { true }) do
          refute sb.send(:dispatch, "q"), "a confirmed q exits the loop"
        end
        assert killed, "a confirmed q tears down every session"

        killed = false
        stub_method(sb, :confirm, ->(*) { false }) do
          assert sb.send(:dispatch, "q"), "an unconfirmed q keeps the loop alive"
        end
        refute killed, "an unconfirmed q kills nothing"
      end
    end

    def test_handle_processes_every_token_in_a_key_repeat_buffer
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:handle, "jj") # a held 'j' arrives as one multi-byte read
      assert_equal 2, cursor_of(sb)
    end

    def test_handle_returns_false_when_a_token_quits
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :kill_all, ->(*) { [] }) do
        stub_method(sb, :confirm, ->(*) { true }) do
          refute sb.send(:handle, "q"), "a confirmed q exits the loop"
        end
      end
    end

    # A stop-token (a confirmed q) must END the buffer loop — a key buffered after
    # it must NOT dispatch, so a fast `qd` can't fall through into delete.
    def test_handle_stops_at_a_stop_token_and_skips_the_rest
      sb = sidebar(nodes: [proj("app")])
      deleted = false
      stub_method(Tmux, :kill_all, ->(*) { [] }) do
        stub_method(sb, :confirm, ->(*) { true }) do
          stub_method(sb, :delete, ->(*) { deleted = true }) do
            refute sb.send(:handle, "qd"), "the stop-token still exits the loop"
          end
        end
      end
      refute deleted, "a key buffered after a confirmed q must not dispatch"
    end

    def test_locate_marks_the_workspace_the_pane_sits_in
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")])
      stub_method(Tmux, :pane_path, ->(_pane) { "/wt/b/sub" }) do
        sb.send(:locate)
      end
      assert_equal "/wt/b", sb.instance_variable_get(:@current_path)
    end

    # --- bold until viewed (attention markers) -------------------------------
    # A completion edge bolds the workspace until you switch into it. The markers
    # are real files in the sandbox, so the canonicalization runs for real.

    def real_dir(sub)
      d = path(sub)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    # The edge marks every newly-resting workspace EXCEPT the one you're sitting in
    # — you're watching that one finish, so it needs no nudge.
    def test_mark_attention_for_marks_edges_except_the_viewed_one
      a = real_dir("a")
      b = real_dir("b")
      sb = sidebar(nodes: [ws("a", path: a), ws("b", path: b)], current_path: a)
      sb.send(:mark_attention_for, [a, b])
      marked = Attention.marked([a, b])
      refute_includes marked, a, "the workspace you're watching isn't bolded"
      assert_includes marked, b, "another workspace's completion is bolded"
    end

    # Viewing a workspace clears its bold immediately — on disk AND in the
    # in-memory set, so the un-bold shows this frame, not on the next scan.
    def test_locate_clears_the_viewed_workspaces_attention
      w = real_dir("w")
      Attention.mark(w)
      sb = sidebar(nodes: [proj("app"), ws("w", path: w)], attention: [w])
      stub_method(Tmux, :pane_path, ->(_pane) { w }) do
        sb.send(:locate)
      end
      refute_includes sb.instance_variable_get(:@attention), w, "cleared from memory this frame"
      assert_empty Attention.marked([w]), "and cleared on disk"
    end

    # The completion edge (T1) wires through to a mark, the visual twin of the dot.
    def test_on_agent_edges_marks_attention_on_an_edge
      w = real_dir("wt")
      sb = sidebar(nodes: [ws("w", project: "app", path: w)])
      set_hook_states(sb, { w => :done })
      sb.instance_variable_set(:@prev_hook_states, { w => :thinking })
      sb.define_singleton_method(:maybe_refresh_prs) { |_p| }
      stub_method(Sound, :play, ->(*) {}) do
        sb.send(:on_agent_edges)
      end
      assert_includes Attention.marked([w]), w, "a completion edge bolds the workspace"
    end

    def test_colored_bolds_a_workspace_with_an_unviewed_completion
      sb = sidebar(attention: ["/wt/a"])
      assert_includes sb.send(:colored, ws("a", path: "/wt/a"), "  ● a"), "\e[1;33m",
                      "an unviewed completion renders bold yellow"
    end

    # The current ("you are here") row is always cleared, so it's cyan, never bold —
    # even if a marker lingered, current takes precedence.
    def test_colored_does_not_bold_the_current_workspace
      sb = sidebar(attention: ["/wt/a"], current_path: "/wt/a")
      out = sb.send(:colored, ws("a", path: "/wt/a"), "  ● a", current: true)
      assert_includes out, "\e[36m", "the current workspace is cyan"
      refute_includes out, "\e[1;33m", "...and never also the attention highlight"
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

    # --- footer: context-sensitive legend ------------------------------------
    # The legend adapts to the highlighted row's kind, but stays three lines so
    # the tree never reflows as the cursor crosses the project/workspace boundary.

    def test_footer_for_a_project_row_foregrounds_remove
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      foot = sb.send(:footer)
      assert_equal 3, foot.size, "always three lines — the tree must not reflow on cursor move"
      assert_equal Sidebar::NAV_PROJ, foot[0]
      assert foot.any? { |l| l.include?("d remove") }, "d removes the project"
      refute foot.any? { |l| l.include?("o PR") },   "PR is workspace-only"
      refute foot.any? { |l| l.include?("r rename") }, "rename is workspace-only"
    end

    def test_footer_for_a_workspace_row_shows_the_per_workspace_keys
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 1)
      foot = sb.send(:footer)
      assert_equal 3, foot.size
      assert_equal Sidebar::NAV_WS, foot[0]
      assert foot.any? { |l| l.include?("d delete") }, "d deletes the worktree"
      assert foot.any? { |l| l.include?("o PR") }
      assert foot.any? { |l| l.include?("r rename") }
    end

    # A branch child row only advertises keys that actually fire on it (↵ switch,
    # o PR) — d/r guard on `ws`, so they'd be no-ops and are dropped.
    def test_footer_for_a_branch_row_drops_the_workspace_only_keys
      sb = sidebar(nodes: [proj("app"), ws("a"), br("feat")], cursor: 2)
      foot = sb.send(:footer)
      assert_equal 3, foot.size
      assert_equal Sidebar::NAV_BR, foot[0]
      assert foot.any? { |l| l.include?("o PR") }, "opening the branch's PR works"
      refute foot.any? { |l| l.include?("d delete") }, "delete no-ops on a branch row"
      refute foot.any? { |l| l.include?("r rename") }, "rename no-ops on a branch row"
    end

    def test_footer_in_home_keeps_the_title_but_adapts_the_actions
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      sb.instance_variable_set(:@home, true)
      assert_equal Sidebar::HOME_TITLE, sb.send(:footer)[0], "home keeps its title on a project row"
      assert sb.send(:footer).any? { |l| l.include?("d remove") }, "...with project actions below"

      sb.instance_variable_set(:@cursor, 1) # workspace row
      assert_equal Sidebar::HOME_TITLE, sb.send(:footer)[0], "...and on a workspace row"
      assert sb.send(:footer).any? { |l| l.include?("d delete") }, "...with workspace actions below"
    end

    def test_footer_on_an_empty_tree_still_invites_a_first_project
      foot = sidebar(nodes: []).send(:footer)
      assert_equal 3, foot.size
      assert foot.any? { |l| l.include?("a add") }, "the fresh-install state still shows how to add"
    end

    # --- remove: d routes by row kind ----------------------------------------

    def test_remove_routes_project_to_remove_project_and_workspace_to_delete
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      routed = nil
      sb.define_singleton_method(:remove_project) { |node| routed = [:project, node.project] }
      sb.define_singleton_method(:delete) { routed = [:delete] }

      sb.send(:remove)
      assert_equal [:project, "app"], routed, "a project row removes the project"

      sb.instance_variable_set(:@cursor, 1) # workspace row
      sb.send(:remove)
      assert_equal [:delete], routed, "a workspace row deletes the worktree"
    end

    # --- remove_project: confirm -> unregister + close sessions ----------------

    def test_remove_project_unregisters_and_closes_sessions_when_confirmed
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      killed = nil
      reloaded = false
      sb.define_singleton_method(:reload) { |**| reloaded = true }
      stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do            # not in the project: no eject
        stub_method(Tmux, :kill_project_sessions, ->(name) { killed = name; [] }) do
          stub_method(sb, :confirm, ->(*) { true }) do
            sb.send(:remove_project, proj("app"))
          end
        end
      end
      assert_equal "app", killed, "closes the project's sessions"
      assert reloaded, "refreshes the tree in-process"
      refute Config.new.project("app"), "and unregisters it from the config"
    end

    def test_remove_project_is_a_noop_when_not_confirmed
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      killed = false
      stub_method(Tmux, :kill_project_sessions, ->(*) { killed = true; [] }) do
        stub_method(sb, :confirm, ->(*) { false }) do
          sb.send(:remove_project, proj("app"))
        end
      end
      refute killed, "an unconfirmed remove closes nothing"
      assert Config.new.project("app"), "...and keeps the project registered"
    end

    # Removing the project whose session we're in would kill this sidebar's own
    # pane: fall back to home first, poke home to re-read the smaller config
    # (its git reload won't show it), and DON'T reload in-process — home drives.
    def test_remove_project_ejects_to_home_when_removing_the_session_were_in
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      sb.instance_variable_set(:@config, Config.new)
      went_home = false
      poked = nil
      reloaded = false
      sb.define_singleton_method(:reload) { |**| reloaded = true }
      stub_method(Tmux, :session_of, ->(*) { "sb/app/feat" }) do        # we're inside the project
        stub_method(Tmux, :go_home, ->(*) { went_home = true }) do
          stub_method(Tmux, :poke_sidebar_of, ->(s, **kw) { poked = [s, kw] }) do
            stub_method(Tmux, :kill_project_sessions, ->(*) { [] }) do
              stub_method(sb, :confirm, ->(*) { true }) do
                sb.send(:remove_project, proj("app"))
              end
            end
          end
        end
      end
      assert went_home, "removing the session we're in falls back to home first"
      assert_equal [Tmux::HOME, { reload_config: true }], poked, "pokes home to re-read the smaller config"
      refute reloaded, "the dying sidebar doesn't reload in-process"
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
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }            # neutralize the tmux call
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do        # poked while on screen (session switch-in)
        sb.send(:reload_and_refresh) # due -> reloads
        sb.send(:reload_and_refresh) # within POKE_TTL -> locate only, no reload
        sb.send(:reload_and_refresh)
      end
      assert_equal 1, reloads, "rapid switch pokes coalesce into a single heavy reload"
    end

    # The switch-in poke is a catch-up: it must reload SILENTLY so stale
    # completions don't re-ring as you move between sessions (sound-chorus).
    def test_switch_poke_reloads_without_announcing_sounds
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      announced = :unset
      sb.define_singleton_method(:reload) { |announce_sounds: true| announced = announce_sounds; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do
        sb.send(:reload_and_refresh)
      end
      refute announced, "a switch-in re-baselines silently, not ringing prior completions"
    end

    def test_poke_reloads_again_once_the_window_passes
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1; @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do
        sb.send(:reload_and_refresh)                                    # reload #1
        sb.instance_variable_set(:@last_reload, sb.send(:monotonic) - Sidebar::POKE_TTL - 1)
        sb.send(:reload_and_refresh)                                    # window passed -> reload #2
      end
      assert_equal 2, reloads
    end

    # --- tick: the catch-up vs continuous reload split (sound-chorus) ----------
    # tick is the headline entry point: switching INTO a session reappears its
    # sidebar (off-screen -> on-screen), and that reload must be SILENT. A
    # continuously-visible tick stays loud. Tmux.visible?/focused? are stubbed —
    # the raw tmux calls stay out of scope, the branch decision is what we pin.

    def test_tick_reappearing_from_offscreen_reloads_silently
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false) # was off-screen, baseline frozen
      announced = :unset
      sb.define_singleton_method(:reload) { |announce_sounds: true| announced = announce_sounds }
      stub_method(Tmux, :focused?, ->(*) { false }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do # now back on screen
          sb.send(:tick)
        end
      end
      refute announced, "reappearing re-baselines silently — stale completions don't re-ring"
      assert sb.instance_variable_get(:@visible), "tick records that we're now visible"
    end

    def test_tick_while_continuously_visible_keeps_ringing
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true) # already on screen, never slept
      sb.instance_variable_set(:@ticks, 0)          # < TREE_TICKS -> refresh_agents path
      announce = :unset
      sb.define_singleton_method(:pin_width) { nil }
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| announce = announce_sounds }
      stub_method(Tmux, :focused?, ->(*) { true }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do
          sb.send(:tick)
        end
      end
      assert announce, "a live, continuously-visible scan still announces completions"
    end

    # --- visibility-aware loop (off-screen dormancy) --------------------------
    # @visible is the single on-screen flag: it gates render + pulse, and the poke
    # path re-samples it because C-l is overloaded (session switch-in vs background
    # PR-refresh to a pane we may have navigated away from).

    # The background PR-refresh poke can land on an OFF-screen pane (it's built to
    # survive navigation). A hidden poke must not reload or mark the pane visible —
    # that would reintroduce the off-screen work the whole change removes.
    def test_reload_and_refresh_skips_a_hidden_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.define_singleton_method(:locate) { nil }
      stub_method(Tmux, :visible?, ->(*) { false }) do
        sb.send(:reload_and_refresh)
      end
      assert_equal 0, reloads, "a poke to a hidden pane never reloads"
      refute sb.instance_variable_get(:@visible), "...and never marks the hidden pane visible"
    end

    def test_reload_and_refresh_marks_a_visible_poke_on_screen
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, false)
      sb.define_singleton_method(:reload) { |announce_sounds: true| @last_reload = monotonic }
      sb.define_singleton_method(:locate) { nil }
      sb.define_singleton_method(:maybe_refresh_prs) { |*| nil }
      stub_method(Tmux, :visible?, ->(*) { true }) do
        sb.send(:reload_and_refresh)
      end
      assert sb.instance_variable_get(:@visible), "a session switch-in poke marks the pane visible"
    end

    # Dedup: a poke switch-in already set @visible=true and reloaded, so the next
    # tick must NOT reload again. The off->on edge is consumed by the flag itself,
    # not a POKE_TTL window (POKE_TTL < REFRESH, so a window-based guard was racy).
    def test_tick_does_not_double_reload_after_a_poke
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@visible, true) # poke already marked us visible
      sb.instance_variable_set(:@ticks, 0)
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.define_singleton_method(:pin_if_resized) { nil }
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| nil }
      stub_method(Tmux, :focused?, ->(*) { true }) do
        stub_method(Tmux, :visible?, ->(*) { true }) do
          sb.send(:tick)
        end
      end
      assert_equal 0, reloads, "no catch-up reload when the poke already consumed the off->on edge"
    end

    # Off screen, tick must not spend a tmux call on focused? — that's half a dormant
    # pane's per-tick cost. focused? is short-circuited behind the visibility sample.
    def test_tick_skips_the_focused_shellout_when_offscreen
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@visible, false)
      called = false
      stub_method(Tmux, :focused?, ->(*) { called = true; true }) do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          sb.send(:tick)
        end
      end
      refute called, "off screen, tick must not call focused?"
      refute sb.instance_variable_get(:@focused), "off screen is never focused"
    end

    def test_frame_timeout_pulse_refresh_idle
      sb = sidebar(nodes: [ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      sb.instance_variable_set(:@visible, false)
      assert_equal Sidebar::IDLE, sb.send(:frame_timeout), "off screen sleeps on the long IDLE backstop"
      sb.instance_variable_set(:@visible, true)
      assert_equal Sidebar::PULSE, sb.send(:frame_timeout), "visible + a thinking dot pulses fast"
      sb.instance_variable_set(:@agents, { "/wt/a" => :done })
      assert_equal Sidebar::REFRESH, sb.send(:frame_timeout), "visible + a steady dot sits on REFRESH"
    end

    def test_recheck_visibility_samples_the_pane
      sb = sidebar
      sb.instance_variable_set(:@visible, true)
      stub_method(Tmux, :visible?, ->(*) { false }) do
        sb.send(:recheck_visibility)
      end
      refute sb.instance_variable_get(:@visible), "recheck flips @visible off when the pane left the screen"
    end

    def test_vis_poll_due_throttles
      sb = sidebar
      assert sb.send(:vis_poll_due?), "first visibility re-check is always due"
      refute sb.send(:vis_poll_due?), "...then throttled within VIS_POLL"
    end

    def test_focus_in_marks_visible_focused_and_catches_up_when_reappearing
      sb = sidebar(focused: false)
      sb.instance_variable_set(:@visible, false)
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.send(:dispatch, "\e[I")
      assert sb.instance_variable_get(:@visible), "focus-in proves the pane is on screen"
      assert sb.instance_variable_get(:@focused), "focus-in lights the cursor bar"
      assert_equal 1, reloads, "focus-in on a hidden pane (un-poked reappearance) silently catches up"
    end

    # focus-in on an already-visible pane is just a cursor-bar change — it must NOT
    # reload (the off->on edge isn't there), or every click into the tree would rescan.
    def test_focus_in_when_already_visible_does_not_reload
      sb = sidebar(focused: false)
      sb.instance_variable_set(:@visible, true)
      reloads = 0
      sb.define_singleton_method(:reload) { |announce_sounds: true| reloads += 1 }
      sb.send(:dispatch, "\e[I")
      assert_equal 0, reloads, "no reload when the pane was already on screen"
    end

    def test_pin_if_resized_pins_only_when_geometry_changes
      sb = sidebar
      pins = 0
      sb.define_singleton_method(:winsize) { [50, 40] }
      sb.define_singleton_method(:pin_width) { pins += 1; true }
      sb.send(:pin_if_resized) # @geom nil -> changed -> pin
      sb.send(:pin_if_resized) # same size -> no pin
      assert_equal 1, pins, "re-pins only when winsize differs from the cached geometry"
      sb.define_singleton_method(:winsize) { [50, 60] } # client resized
      sb.send(:pin_if_resized)
      assert_equal 2, pins, "a real geometry change re-pins"
    end

    # A failed pin (resize-pane errored, or tmux can't satisfy the width) must NOT
    # cache the drifted geometry, or we'd never retry.
    def test_pin_if_resized_does_not_cache_on_failure
      sb = sidebar
      attempts = 0
      sb.define_singleton_method(:winsize) { [50, 40] }
      sb.define_singleton_method(:pin_width) { attempts += 1; false }
      sb.send(:pin_if_resized)
      sb.send(:pin_if_resized)
      assert_equal 2, attempts, "a failed pin retries next tick instead of poisoning the cache"
    end

    # --- pane ownership: exit an orphaned sidebar (duplicate-sound fix) --------
    # tmux recycles %ids, so a sidebar that outlives its pane (the loop never died)
    # can have ENV["TMUX_PANE"] come to name a DIFFERENT, live pane. Left running it
    # reads that pane's visibility and rings completions in parallel with the real
    # owner — duplicate sounds. owns_pane? compares the pane's current pty against the
    # one captured at startup; tick returns false (→ loop exits) once they diverge.

    def test_tick_exits_when_pane_id_was_recycled_onto_another_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@pane_tty, "/dev/ttys007") # the pty we started on
      announced = false
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| announced = true }
      # tmux now reports a different tty for our %id — it was handed to a new pane
      stub_method(Tmux, :pane_tty, ->(*) { "/dev/ttys099" }) do
        refute sb.send(:tick), "a recycled-id orphan asks the loop to exit"
      end
      refute announced, "...and never runs an announcing scan (no duplicate ring)"
    end

    # A nil pane_tty is ambiguous — pane gone OR a transient display-message failure —
    # so owns_pane? must NOT exit on it (that would self-terminate a healthy sidebar
    # whenever a tmux shell-out flakes). A dead-but-not-recycled pane reads visible?
    # false (silent), and gets reaped on a CONFIRMED tty mismatch once its id recycles.
    def test_tick_does_not_exit_on_a_nil_pane_tty
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@pane_tty, "/dev/ttys007")
      sb.instance_variable_set(:@visible, false)
      stub_method(Tmux, :pane_tty, ->(*) { nil }) do # transient miss / pane gone, not recycled
        stub_method(Tmux, :focused?, ->(*) { false }) do
          stub_method(Tmux, :visible?, ->(*) { false }) do
            assert sb.send(:tick), "nil pane_tty is not proof of disownership — keep running"
          end
        end
      end
    end

    def test_tick_keeps_running_while_it_still_owns_its_pane
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")])
      sb.instance_variable_set(:@pane_tty, "/dev/ttys007")
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@ticks, 0)
      sb.define_singleton_method(:pin_if_resized) { nil }
      sb.define_singleton_method(:refresh_agents) { |announce_sounds: true| nil }
      stub_method(Tmux, :pane_tty, ->(*) { "/dev/ttys007" }) do # still our pty
        stub_method(Tmux, :focused?, ->(*) { true }) do
          stub_method(Tmux, :visible?, ->(*) { true }) do
            assert sb.send(:tick), "the real owner keeps ticking"
          end
        end
      end
    end

    # No startup tty (launched outside tmux, or a unit test) ⇒ ownership is a no-op
    # and we never shell out to tmux to second-guess it.
    def test_tick_without_a_captured_pane_tty_never_self_exits
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@visible, false)
      called = false
      stub_method(Tmux, :pane_tty, ->(*) { called = true; nil }) do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          assert sb.send(:tick), "no captured pty -> tick never asks to exit"
        end
      end
      refute called, "owns_pane? short-circuits without a tmux call when @pane_tty is nil"
    end

    # read_key separates a closed pane (EOF) from a spurious wakeup (nothing ready):
    # the run loop turns :eof into a clean exit so a dead pane can't busy-spin forever.
    def test_read_key_signals_eof_when_the_stream_is_closed
      sb = Sidebar.new
      r, w = IO.pipe
      w.close # reader is now at end-of-stream
      with_stdin(r) { assert_equal :eof, sb.send(:read_key) }
    ensure
      r.close
    end

    def test_read_key_is_nil_when_nothing_is_ready
      sb = Sidebar.new
      r, w = IO.pipe # open + empty -> read_nonblock raises WaitReadable
      with_stdin(r) { assert_nil sb.send(:read_key) }
    ensure
      r.close
      w.close
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
      sb.instance_variable_set(:@visible, true)
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
      sb.instance_variable_set(:@visible, true)
      on_screen = ->(p) { rows_of(sb).select { |n| n.path == p } }

      sb.instance_variable_set(:@visible_rows, on_screen.call("/wt/a"))
      refute sb.send(:pulsing?), "a thinking dot scrolled off screen doesn't pulse"

      sb.instance_variable_set(:@visible_rows, on_screen.call("/wt/b"))
      assert sb.send(:pulsing?), "...but it pulses once it's on screen"
    end

    def test_pulsing_is_false_when_pane_hidden
      sb = sidebar(nodes: [ws("a", path: "/wt/a")], agents: { "/wt/a" => :thinking })
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      sb.instance_variable_set(:@visible, false)
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

    # A catch-up scan (switch-in / reappear) must NOT ring for a completion that
    # finished while this sidebar was off-screen — another sidebar already rang it.
    # The PR refresh and the baseline advance still ride: announce_sounds gates the
    # sound alone. This is the duplicate-notification fix (sound-chorus).
    def test_on_agent_edges_silent_catch_up_holds_the_sound_but_keeps_pr_and_baseline
      sb = sidebar(nodes: [ws("a", project: "app", path: "/wt/a")])
      set_hook_states(sb, { "/wt/a" => :done })
      sb.instance_variable_set(:@prev_hook_states, { "/wt/a" => :thinking })
      prs = []
      sounds = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| prs << p }
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        sb.send(:on_agent_edges, announce_sounds: false)
      end
      assert_empty sounds, "a catch-up re-baselines silently — another sidebar already rang"
      assert_equal ["app"], prs, "...but the PR refresh still rides the edge"
      assert_equal({ "/wt/a" => :done }, sb.instance_variable_get(:@prev_hook_states),
                   "baseline advances so the next genuine completion still fires")
    end

    # After a silent switch-in, a completion that lands while we're actually here
    # rings as normal — the suppression is one scan, not a permanent mute.
    def test_silent_catch_up_then_a_live_completion_rings
      sb = sidebar(nodes: [ws("a", project: "app", path: "/wt/a")])
      sb.instance_variable_set(:@prev_hook_states, { "/wt/a" => :thinking })
      sb.define_singleton_method(:maybe_refresh_prs) { |_p| }
      sounds = []
      stub_method(Sound, :play, ->(spec, **) { sounds << spec }) do
        set_hook_states(sb, { "/wt/a" => :done })
        sb.send(:on_agent_edges, announce_sounds: false)     # switch-in: stale completion, silent
        set_hook_states(sb, { "/wt/a" => :thinking })
        sb.send(:on_agent_edges)                              # a new turn begins
        set_hook_states(sb, { "/wt/a" => :done })
        sb.send(:on_agent_edges)                              # finishes while we watch -> rings
      end
      assert_equal ["train"], sounds
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

    # --- edit_config: the `e` command handed to edit_in_home ------------------
    # The editor is left UNescaped so the spawned shell resolves $EDITOR at run
    # time (the nvim fix); the path is escaped; the trailer returns to origin and
    # pokes that sidebar to re-read config.
    def test_edit_config_builds_a_runtime_resolved_editor_command
      ENV["SWITCHBOARD_BIN"] = "/opt/sb"
      captured = nil
      stub_method(Tmux, :session_of, -> { "sb/app/feat" }) do
        stub_method(Tmux, :edit_in_home, ->(cmd) { captured = cmd }) do
          sidebar(nodes: []).send(:edit_config)
        end
      end
      assert captured.start_with?("${VISUAL:-${EDITOR:-vi}} "), "editor resolved by the spawned shell, not baked"
      assert_includes captured, Shellwords.escape(Config.path)
      assert_match(%r{/opt/sb reload-config sb/app/feat\z}, captured, "returns to origin + reloads on :q")
    end

    # Pressing `e` from outside tmux (or with no TMUX_PANE) makes Tmux.session_of
    # nil; .to_s collapses it to "", so the trailer still emits a reload-config
    # with an empty origin — which reload_config_poke special-cases back to HOME.
    # Must not raise and must still carry the trailer.
    def test_edit_config_tolerates_a_nil_origin_session
      captured = nil
      stub_method(Tmux, :session_of, -> { nil }) do
        stub_method(Tmux, :edit_in_home, ->(cmd) { captured = cmd }) do
          sidebar(nodes: []).send(:edit_config)
        end
      end
      assert_match(/reload-config\s*('')?\z/, captured.to_s, "empty origin still produces a reload trailer")
    end
  end
end
