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
    def ws_names(sb)   = rows_of(sb).select { |n| n.kind == "ws" }.map(&:name)
    def current_node(sb) = rows_of(sb)[cursor_of(sb)]

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

    # The fold is shared, not per-process: toggling writes through to the on-disk
    # store so every other window's sidebar reflects it on its next reload.
    def test_toggle_collapse_writes_through_to_the_shared_store
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:toggle_collapse, "app")
      assert_includes Collapse.collapsed, "app", "collapse persists to the shared store"
      sb.send(:toggle_collapse, "app")
      refute_includes Collapse.collapsed, "app", "expand clears it from the shared store"
    end

    # The other half: a fresh sidebar hydrates its folds from the shared store on
    # rebuild — so a project you collapsed in one window comes up collapsed here.
    def test_rebuild_hydrates_folds_from_the_shared_store
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      Collapse.collapse("app") # as if folded by another window's sidebar

      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert_includes sb.instance_variable_get(:@collapsed), "app",
                      "rebuild picks up a fold another sidebar wrote"
    end

    # Same store-hydration contract for the full-header toggle: a flip in one
    # window is picked up by every other sidebar on its next rebuild.
    def test_rebuild_hydrates_the_full_header_flag_from_the_shared_store
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      FullHeader.enable # as if another window's sidebar pressed H

      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert sb.instance_variable_get(:@full_header),
             "rebuild picks up the full-header flag another sidebar wrote"
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
      sb.send(:dispatch, "\e[B") # ↓
      assert_equal 1, cursor_of(sb)
      sb.send(:dispatch, "\x0E") # ^N
      assert_equal 2, cursor_of(sb)
      sb.send(:dispatch, "\e[A") # ↑
      assert_equal 1, cursor_of(sb)
      sb.send(:dispatch, "\x10") # ^P
      assert_equal 0, cursor_of(sb)
      sb.send(:dispatch, "G")
      assert_equal 2, cursor_of(sb)
      sb.send(:dispatch, "g")
      assert_equal 0, cursor_of(sb)
    end

    # j/k are vi movers in normal mode (down/up). They're NOT movers while
    # filtering — there a printable key is query input (test below) — so motion in
    # the tree is arrows / ^N / ^P / j / k, and in the filter arrows / ^N / ^P.
    def test_j_and_k_move_in_normal_mode
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:dispatch, "j")
      assert_equal 1, cursor_of(sb), "j moves down"
      sb.send(:dispatch, "j")
      assert_equal 2, cursor_of(sb), "...clamping at the last row"
      sb.send(:dispatch, "j")
      assert_equal 2, cursor_of(sb)
      sb.send(:dispatch, "k")
      assert_equal 1, cursor_of(sb), "k moves up"
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

    # A confirmed q wipes agent state before tearing down — killing every agent
    # at once leaves their last hook states stale, and a lingering :thinking would
    # otherwise read as a live, working agent on the next launch. An unconfirmed q
    # touches nothing.
    def test_q_clears_agent_state_before_teardown_only_when_confirmed
      sb = sidebar(nodes: [proj("app")])
      cleared = false
      stub_method(AgentState, :clear_all, -> { cleared = true }) do
        stub_method(Tmux, :kill_all, ->(*) { [] }) do
          stub_method(sb, :confirm, ->(*) { true }) { sb.send(:dispatch, "q") }
          assert cleared, "a confirmed q clears stale agent state"

          cleared = false
          stub_method(sb, :confirm, ->(*) { false }) { sb.send(:dispatch, "q") }
          refute cleared, "an unconfirmed q clears nothing"
        end
      end
    end

    def test_handle_processes_every_token_in_a_key_repeat_buffer
      sb = sidebar(nodes: [proj("app"), ws("a"), ws("b")])
      sb.send(:handle, "\x0E\x0E") # a held ^N arrives as one multi-byte read
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

    # --- cursor follows "you are here" ---------------------------------------
    # Returning to the sidebar selects the workspace the session is in, not
    # wherever the cursor last sat (cursor_to_current). Edge-triggered on
    # focus-in / first paint, so it never fights j/k while you navigate.

    def test_cursor_to_current_lands_on_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")],
                   cursor: 0, current_path: "/wt/b")
      sb.send(:cursor_to_current)
      assert_equal 2, cursor_of(sb), "the cursor snaps to the workspace we're in"
    end

    def test_cursor_to_current_is_a_noop_at_home
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], cursor: 1, current_path: nil)
      sb.send(:cursor_to_current)
      assert_equal 1, cursor_of(sb), "no current workspace (home) -> leave the cursor put"
    end

    # A collapsed project hides its workspace rows, so there's no row to select —
    # leave the cursor where it is rather than jumping it somewhere arbitrary.
    def test_cursor_to_current_leaves_the_cursor_when_the_row_is_hidden
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], collapsed: ["app"],
                   cursor: 0, current_path: "/wt/a")
      sb.send(:cursor_to_current)
      assert_equal 0, cursor_of(sb), "a hidden (collapsed) workspace row can't be selected"
    end

    # The headline behavior: refocusing the sidebar selects "here". @visible is
    # already true so focus_in won't reload — just the cursor snap is exercised.
    def test_focus_in_selects_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a"), ws("b", path: "/wt/b")],
                   cursor: 1, current_path: "/wt/b", focused: false)
      sb.instance_variable_set(:@visible, true)
      sb.send(:dispatch, "\e[I")
      assert_equal 2, cursor_of(sb), "going back to the sidebar lands on the workspace we're in"
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

    # --- "you are here" pointer ----------------------------------------------
    # The current workspace also carries a SHAPE cue — a » gutter pointer — so it
    # reads without relying on the cyan color alone (the accessibility win).

    def test_colored_points_at_the_current_workspace
      sb = sidebar(current_path: "/wt/a")
      out = sb.send(:colored, ws("a", path: "/wt/a"), "  ● a", current: true)
      assert_includes out, Sidebar::CURRENT_MARK, "the current workspace gets the » pointer"
    end

    def test_colored_leaves_other_workspaces_unmarked
      sb = sidebar(current_path: "/wt/a")
      out = sb.send(:colored, ws("b", path: "/wt/b"), "  ● b", current: false)
      refute_includes out, Sidebar::CURRENT_MARK, "a non-current workspace keeps a blank gutter"
    end

    # plain() carries the pointer too, so the cue survives under the reverse-video
    # cursor bar (where color is stripped but shape isn't).
    def test_plain_points_at_the_current_workspace
      sb = sidebar(current_path: "/wt/a")
      assert sb.send(:plain, ws("a", path: "/wt/a")).start_with?(Sidebar::CURRENT_MARK),
             "the current workspace's plain row leads with the » pointer"
      refute sb.send(:plain, ws("b", path: "/wt/b")).start_with?(Sidebar::CURRENT_MARK),
             "another workspace's plain row does not"
    end

    # The pointer is one column, so a workspace name still starts at the same
    # offset whether or not the row is current — no reflow between rows.
    def test_pointer_preserves_name_alignment
      sb = sidebar(current_path: "/wt/a")
      here  = sb.send(:plain, ws("a", path: "/wt/a"))
      other = sb.send(:plain, ws("b", path: "/wt/b"))
      assert_equal other.index("b"), here.index("a"), "names line up regardless of the pointer"
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

    # In filter mode a header's children show regardless of fold, so it reads ▾
    # even for a project that's collapsed in the normal tree.
    def test_plain_shows_expanded_glyph_for_a_collapsed_project_while_filtering
      sb = sidebar(collapsed: ["app"])
      sb.instance_variable_set(:@filter, "a")
      assert_equal "▾ app", sb.send(:plain, proj("app"))
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
      assert foot[0].start_with?(Sidebar::NAV_PROJ), "line 1 leads with the project nav keys"
      assert_includes foot[0], "/ filter", "the filter hint rides the nav line"
      assert foot.any? { |l| l.include?("d remove") }, "d removes the project"
      refute foot.any? { |l| l.include?("o PR") },   "PR is workspace-only"
      refute foot.any? { |l| l.include?("r rename") }, "rename is workspace-only"
    end

    def test_footer_for_a_workspace_row_shows_the_per_workspace_keys
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 1)
      foot = sb.send(:footer)
      assert_equal 3, foot.size
      assert foot[0].start_with?(Sidebar::NAV_WS), "line 1 leads with the workspace nav keys"
      assert_includes foot[0], "/ filter"
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
      assert foot[0].start_with?(Sidebar::NAV_BR), "line 1 leads with the branch nav keys"
      assert_includes foot[0], "/ filter"
      assert foot.any? { |l| l.include?("o PR") }, "opening the branch's PR works"
      refute foot.any? { |l| l.include?("d delete") }, "delete no-ops on a branch row"
      refute foot.any? { |l| l.include?("r rename") }, "rename no-ops on a branch row"
    end

    def test_footer_in_home_keeps_the_title_but_adapts_the_actions
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      sb.instance_variable_set(:@home, true)
      assert sb.send(:footer)[0].start_with?(Sidebar::HOME_TITLE), "home keeps its title on a project row"
      assert_includes sb.send(:footer)[0], "/ filter", "...with the filter hint trailing it"
      assert sb.send(:footer).any? { |l| l.include?("d remove") }, "...and project actions below"

      sb.instance_variable_set(:@cursor, 1) # workspace row
      assert sb.send(:footer)[0].start_with?(Sidebar::HOME_TITLE), "...and on a workspace row"
      assert sb.send(:footer).any? { |l| l.include?("d delete") }, "...with workspace actions below"
    end

    def test_footer_on_an_empty_tree_still_invites_a_first_project
      foot = sidebar(nodes: []).send(:footer)
      assert_equal 3, foot.size
      assert foot.any? { |l| l.include?("a add") }, "the fresh-install state still shows how to add"
    end

    # R (manual PR-badge refresh) is global, so its hint rides every row kind —
    # and every legend line must still fit the pinned pane width uncut, or the
    # trailing key (q quit) would be truncated away.
    def test_footer_advertises_R_on_every_kind_within_the_pin_width
      [[proj("app")], [proj("app"), ws("a")], [proj("app"), ws("a"), br("f")], []].each do |nodes|
        sb = sidebar(nodes: nodes, cursor: nodes.size - 1)
        foot = sb.send(:footer)
        assert foot.any? { |l| l.include?("R sync") }, "R sync hint present for #{nodes.map(&:kind)}"
        foot.each do |line|
          assert line.length <= Tmux::SIDEBAR_WIDTH, "legend line #{line.inspect} fits the #{Tmux::SIDEBAR_WIDTH}-col pane"
        end
      end
    end

    # --- brand header: wordmark everywhere, dashboard on home ----------------
    # Every session leads with the wordmark (the name beyond the footer); the home
    # anchor additionally seats a greeting, a one-line console, and a rule above the
    # tree. Off home it's just the minimal one-liner.

    def home(sb)
      sb.instance_variable_set(:@home, true)
      sb
    end

    def test_header_off_home_is_just_the_minimal_wordmark
      head = sidebar(nodes: [proj("app"), ws("a")]).send(:header, Tmux::SIDEBAR_WIDTH)
      assert_equal 1, head.size, "a focused worktree pane gets a minimal one-line brand header"
      assert head[0].include?(Sidebar::WORDMARK), "the name rides every session now"
      refute head.any? { |l| l.include?("good ") }, "no greeting off home — that's base-camp framing"
    end

    def test_header_on_home_leads_with_the_wordmark_then_a_full_width_rule
      sb = home(sidebar(nodes: [proj("app"), ws("a")]))
      head = sb.send(:header, Tmux::SIDEBAR_WIDTH)
      assert_equal 4, head.size, "wordmark, greeting, console, rule"
      assert head[0].include?(Sidebar::WORDMARK), "the name gets presence beyond the footer"
      assert head[0].include?(Sidebar::BRAND),    "the wordmark wears the brand accent"
      assert_equal "─" * Tmux::SIDEBAR_WIDTH, head[3].gsub(/\e\[[0-9;]*m/, ""), "a rule seats the tree below"
    end

    # The H toggle (@full_header, shared on disk) seats the home-style full header
    # on a NON-home session too — the same four lines, not just the wordmark.
    def test_full_header_toggle_seats_the_full_header_off_home
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.instance_variable_set(:@full_header, true)
      head = sb.send(:header, Tmux::SIDEBAR_WIDTH)
      assert_equal 4, head.size, "wordmark, greeting, console, rule — even off home"
      assert head.any? { |l| l.include?("good ") }, "the full header carries the greeting"
    end

    # toggle_full_header flips the in-memory flag AND writes through to the shared
    # store, so every other window's sidebar picks it up on its next rebuild.
    def test_toggle_full_header_writes_through_to_the_shared_store
      sb = sidebar(nodes: [proj("app"), ws("a")])
      sb.send(:toggle_full_header)
      assert sb.instance_variable_get(:@full_header), "the in-memory flag flips for same-frame feedback"
      assert FullHeader.enabled?, "and the shared marker is set so peers see it"

      sb.send(:toggle_full_header)
      refute sb.instance_variable_get(:@full_header)
      refute FullHeader.enabled?, "toggling off clears the shared marker"
    end

    def test_greeting_addresses_the_operator_by_name_when_known
      sb = sidebar
      sb.instance_variable_set(:@operator, "will")
      assert_match(/\Agood (morning|afternoon|evening), will\z/, sb.send(:greeting))

      sb.instance_variable_set(:@operator, nil)
      assert_match(/\Agood (morning|afternoon|evening)\z/, sb.send(:greeting), "no name → no comma")
    end

    def test_console_counts_worktrees_active_agents_and_open_prs
      open_pr  = { "identifier" => "#7", "status" => "OPEN", "is_draft" => 0 }
      draft_pr = { "identifier" => "#8", "status" => "OPEN", "is_draft" => 1 } # draft ≠ open
      nodes = [proj("app"),
               ws("a", path: "/wt/a", pr: open_pr),
               ws("b", path: "/wt/b", pr: draft_pr),
               ws("c", path: "/wt/c")]
      sb = sidebar(nodes: nodes, agents: { "/wt/a" => :thinking, "/wt/b" => :done })
      assert_equal "3 worktrees · 1 active · 1 PR open", sb.send(:console)
    end

    def test_console_quiets_the_zero_clauses
      sb = sidebar(nodes: [proj("app"), ws("a")])
      assert_equal "1 worktree", sb.send(:console), "no agents, no PRs → just the calm count"
    end

    # --- completion twinkle (the visual twin of the sound) -------------------

    def test_sparkle_fires_only_on_done
      sb = sidebar
      sb.send(:sparkle_for, ["/wt/w"], { "/wt/w" => :waiting })
      refute sb.send(:sparkling?, "/wt/w"), ":waiting already blinks — no twinkle"

      sb.send(:sparkle_for, ["/wt/a"], { "/wt/a" => :done })
      assert sb.send(:sparkling?, "/wt/a"), "a just-completed agent twinkles"
    end

    # The twinkle's lifetime is wall-clock (monotonic), NOT @pulse units — which is
    # what stops it replaying on switch-back. @pulse barely advances while a pane is
    # off-screen, so a pulse-denominated deadline would stay live ~48s hidden and
    # re-twinkle on return; a wall-clock one lapses in real time — proven here with
    # @pulse frozen entirely while a stubbed clock advances past the window.
    def test_sparkle_settles_by_wall_clock_so_it_cannot_replay_on_return
      sb = sidebar(pulse: 0)
      clock = 1000.0
      sb.define_singleton_method(:monotonic) { clock }

      sb.send(:sparkle_for, ["/wt/a"], { "/wt/a" => :done })
      assert sb.send(:sparkling?, "/wt/a"), "twinkles right after completion"

      clock += Sidebar::SPARKLE_SECS + 1 # real time passes while the pane is off-screen
      refute sb.send(:sparkling?, "/wt/a"), "expired by wall-clock with @pulse frozen — no replay"
      refute sb.instance_variable_get(:@sparkles).key?("/wt/a"), "and self-GCs"
    end

    def test_pulsing_wakes_for_an_active_sparkle_on_an_otherwise_steady_done
      sb = sidebar(nodes: [proj("app"), ws("a", path: "/wt/a")], agents: { "/wt/a" => :done })
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      refute sb.send(:pulsing?), ":done alone is steady — the pane sleeps"

      sb.send(:sparkle_for, ["/wt/a"], { "/wt/a" => :done })
      assert sb.send(:pulsing?), "an active sparkle keeps the loop animating until it settles"
    end

    # --- / filter mode (issue #60) -------------------------------------------

    # fzf-style fuzzy: a case-insensitive subsequence, order-sensitive, with an
    # empty query matching everything (so the bare-/ list is the full tree).
    def test_fuzzy_match_is_a_case_insensitive_subsequence
      assert Sidebar.fuzzy_match?("app-feat-branch", "afb"), "non-adjacent subsequence matches"
      assert Sidebar.fuzzy_match?("App-Feat", "af"), "case-insensitive"
      assert Sidebar.fuzzy_match?("anything", ""), "empty query matches everything"
      refute Sidebar.fuzzy_match?("app", "pa"), "order matters — not mere membership"
      refute Sidebar.fuzzy_match?("app", "appp"), "every query char must be consumed"
    end

    # / enters the mode with an empty query (matches everything), keeping the tree
    # grouped: project headers stay, and the cursor lands on the first row.
    def test_slash_enters_filter_mode_showing_the_grouped_tree
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta"), proj("api"), ws("gamma", project: "api")])
      sb.send(:dispatch, "/")
      assert_equal "", sb.instance_variable_get(:@filter), "/ enters filter mode with an empty query"
      assert_equal %w[proj ws ws proj ws], rows_of(sb).map(&:kind), "headers stay, grouping the matches"
      assert_equal 0, cursor_of(sb), "the cursor lands on the first row on entry"
      assert_includes sb.send(:footer)[2], "3 matches", "the count pluralizes and excludes headers"
    end

    def test_typing_narrows_to_subsequence_matches_on_project_and_name
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta"), proj("api"), ws("gamma", project: "api")])
      sb.send(:handle, "/alp")
      assert_equal %w[alpha], ws_names(sb), "the query narrows to matching workspaces"
    end

    # Matches stay under their own project header; a project with no match is dropped.
    def test_filter_keeps_matches_grouped_under_their_project_header
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta"),
                           proj("api"), ws("alpha2", project: "api"), ws("zebra", project: "api")])
      sb.send(:handle, "/alpha")
      assert_equal %w[proj ws proj ws], rows_of(sb).map(&:kind), "each match sits under its header"
      assert_equal %w[app api], rows_of(sb).select { |n| n.kind == "proj" }.map(&:project)
      assert_equal %w[alpha alpha2], ws_names(sb), "only the matching workspaces show"
    end

    def test_filter_drops_a_project_when_neither_its_name_nor_workspaces_match
      sb = sidebar(nodes: [proj("app"), ws("alpha"), proj("api"), ws("zebra", project: "api")])
      sb.send(:handle, "/alpha")
      assert_equal %w[app], rows_of(sb).select { |n| n.kind == "proj" }.map(&:project),
                   "api's name doesn't match and neither does zebra, so it's dropped"
    end

    # A project whose NAME matches shows even with no matching workspaces (or none
    # at all) — that's how you reach an empty project to create its first workspace.
    def test_filter_keeps_a_name_matching_project_with_no_workspaces
      sb = sidebar(nodes: [proj("app"), ws("alpha"), proj("api")]) # api has no workspaces
      sb.send(:handle, "/api")
      assert_equal %w[api], rows_of(sb).select { |n| n.kind == "proj" }.map(&:project),
                   "api matches by name and shows, even with nothing under it"
      assert_empty ws_names(sb), "no workspace rows — just the header"
      assert_equal "proj", current_node(sb).kind, "cursor lands on the header (nothing else to select)"
    end

    # Branch-history rows aren't separate filter targets — switching to one is
    # identical to switching to its workspace, and a lone branch would orphan under
    # a header. So a query that matches only a branch yields nothing.
    def test_filter_excludes_branch_history_rows
      sb = sidebar(nodes: [proj("app"), ws("feat"), br("feature-y", last: true)])
      sb.send(:handle, "/feature-y") # matches only the branch row's text, not the ws
      refute(rows_of(sb).any? { |n| n.kind == "br" }, "branch rows never appear as filter matches")
      assert_empty rows_of(sb), "nothing else matched, so the result is empty"
    end

    # A zero-match query is empty and inert: 0-count footer, and ↵ opens nothing and
    # stays in filter mode (no crash, no clamp to a phantom row).
    def test_filter_with_no_matches_is_empty_and_inert
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:handle, "/zzz")
      assert_empty rows_of(sb)
      assert_includes sb.send(:footer)[2], "0 matches"
      stub_method(Tmux, :go, ->(*, **) { flunk "nothing to open on a zero-match query" }) do
        assert sb.send(:dispatch, "\r"), "↵ keeps the loop alive"
      end
      refute_nil sb.instance_variable_get(:@filter), "...and stays in filter mode"
    end

    # The cursor finds the first workspace match even when it's in a later project
    # (earlier projects dropped entirely or kept header-only).
    def test_filter_lands_on_the_first_match_in_a_later_project
      sb = sidebar(nodes: [proj("app"), ws("alpha"), proj("api"), ws("gamma", project: "api")])
      sb.send(:handle, "/gam")
      assert_equal "gamma", current_node(sb).name, "cursor jumps to the match in the second project"
    end

    # Esc restores the cursor to the workspace this session is in (cursor_to_current),
    # not wherever the filtered cursor sat.
    def test_esc_restores_the_cursor_to_the_current_workspace
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha"), ws("beta", path: "/wt/beta")],
                   current_path: "/wt/beta")
      sb.send(:dispatch, "/") # cursor lands on the first row (the app header)
      assert_equal "proj", current_node(sb).kind
      sb.send(:dispatch, "\e")
      assert_nil sb.instance_variable_get(:@filter)
      assert_equal "beta", current_node(sb).name, "Esc lands back on the session's current workspace"
    end

    # The filter spans the whole tree, folds included — the whole point is reaching
    # any workspace fast, even one tucked inside a collapsed project.
    def test_filter_searches_across_collapsed_projects
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")], collapsed: ["app"])
      assert_equal 1, rows_of(sb).size, "collapsed: only the header shows in the normal tree"
      sb.send(:handle, "/beta")
      assert_equal %w[beta], ws_names(sb), "filter reaches into the folded project"
    end

    def test_esc_cancels_filter_and_restores_the_full_tree
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      assert_equal %w[beta], ws_names(sb)
      sb.send(:dispatch, "\e")
      assert_nil sb.instance_variable_get(:@filter), "Esc leaves filter mode"
      assert_equal 3, rows_of(sb).size, "the full collapse-aware tree is back"
    end

    def test_backspace_past_the_start_exits_filter_mode
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      sb.send(:dispatch, "\x7F")
      assert_equal "b", sb.instance_variable_get(:@filter), "backspace drops the last char"
      sb.send(:dispatch, "\x7F")
      assert_equal "", sb.instance_variable_get(:@filter), "...down to an empty query, still filtering"
      sb.send(:dispatch, "\x7F") # backspace past the start
      assert_nil sb.instance_variable_get(:@filter), "...and one more exits, like erasing the /"
      assert_equal 3, rows_of(sb).size, "the full tree is restored"
    end

    def test_enter_switches_to_the_match_and_leaves_filter_mode
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha"), ws("beta", path: "/wt/beta")])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:handle, "/beta")
      target = nil
      stub_method(Tmux, :go, ->(wt, start:) { target = wt }) { sb.send(:dispatch, "\r") }
      assert_equal "/wt/beta", target.path, "↵ switches to the highlighted match"
      assert_nil sb.instance_variable_get(:@filter), "...and drops back out of filter mode"
    end

    # The crux of the fzf-standard choice (#60): printable keys — j and k included —
    # are query input, so any name is reachable by typing. Motion is the arrows/^N^P.
    def test_j_and_k_are_query_input_not_motion_while_filtering
      sb = sidebar(nodes: [proj("app"), ws("jkl"), ws("beta")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "j")
      assert_equal "j", sb.instance_variable_get(:@filter), "j extends the query rather than moving"
      assert_equal "jkl", current_node(sb).name, "and it narrowed to the jkl workspace"
    end

    # Only printable bytes extend the query — a stray control byte (e.g. a \f poke
    # that lands while you're filtering) is ignored, never appended or a crash.
    def test_filter_ignores_non_printable_bytes
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "a")
      sb.send(:dispatch, "\f")   # Ctrl-L poke byte
      sb.send(:dispatch, "\x01") # Ctrl-A
      sb.send(:dispatch, " ")    # space — the lower printable boundary (0x20), DOES append
      assert_equal "a ", sb.instance_variable_get(:@filter), "control bytes are ignored, space is kept"
    end

    def test_arrows_and_ctrl_np_move_within_the_filtered_set
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:dispatch, "/") # empty query: cursor on the header (first row)
      assert_equal "proj", current_node(sb).kind, "starts on the first row, the header"
      sb.send(:dispatch, "\e[B")
      assert_equal "alpha", current_node(sb).name, "↓ moves onto the first workspace"
      sb.send(:dispatch, "\x0E")
      assert_equal "beta", current_node(sb).name, "^N moves to the next workspace"
      sb.send(:dispatch, "\x0E")
      assert_equal "beta", current_node(sb).name, "^N clamps at the last workspace"
      sb.send(:dispatch, "\e[A")
      assert_equal "alpha", current_node(sb).name, "↑ moves back up"
    end

    # Entry lands on the first row (the header); a query keystroke then snaps to the
    # first workspace match (fast type-then-↵ jump). Headers stay selectable via ↑.
    def test_filter_enters_on_the_first_row_then_snaps_to_a_match_on_typing
      sb = sidebar(nodes: [proj("app"), ws("a1"), ws("a2")])
      sb.send(:dispatch, "/")
      assert_equal "proj", current_node(sb).kind, "entry lands on the first row, the header"
      sb.send(:dispatch, "a") # a query keystroke snaps to the first match
      assert_equal "a1", current_node(sb).name, "typing snaps to the first workspace match"
      sb.send(:dispatch, "\e[A") # up onto the project header
      assert_equal "proj", current_node(sb).kind, "↑ can land on the project header"
      assert_equal "app", current_node(sb).project
    end

    # ↵ on a workspace switches; ↵ on a project header creates a new workspace there
    # (the project-level action) and leaves filter mode.
    def test_enter_on_a_project_header_in_filter_creates_a_workspace
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:dispatch, "/")
      sb.send(:dispatch, "\e[A") # up onto the app header
      assert_equal "proj", current_node(sb).kind, "cursor is on the project header"
      created_for = nil
      sb.define_singleton_method(:create) { |node = nil| created_for = node&.project }
      stub_method(Tmux, :go, ->(*, **) { flunk "should create, not switch" }) do
        sb.send(:dispatch, "\r")
      end
      assert_equal "app", created_for, "↵ on a project creates a new workspace there"
      assert_nil sb.instance_variable_get(:@filter), "...and leaves filter mode"
    end

    # No destructive key fires mid-search: q is just a query char, not a teardown.
    def test_q_does_not_quit_while_filtering
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:dispatch, "/")
      killed = false
      stub_method(Tmux, :kill_all, ->(*) { killed = true; [] }) do
        assert sb.send(:dispatch, "q"), "q keeps the loop alive in filter mode"
      end
      refute killed, "q types a query char rather than tearing down"
      assert_equal "q", sb.instance_variable_get(:@filter)
    end

    def test_filter_footer_echoes_the_query_and_the_in_mode_legend
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      foot = sb.send(:footer)
      assert_equal 3, foot.size, "three lines, like the normal footer — no reflow entering the mode"
      assert_equal "/be", foot[0], "line 1 echoes the live query"
      assert_includes foot[1], "↵ open", "on a workspace, ↵ opens"
      assert_includes foot[1], "esc cancel"
      assert_includes foot[2], "1 match", "the count is workspaces only (header excluded), unpluralized at 1"
      foot.each { |l| assert l.length <= Tmux::SIDEBAR_WIDTH, "#{l.inspect} fits the #{Tmux::SIDEBAR_WIDTH}-col pane" }

      sb.send(:dispatch, "\e[A") # up onto the project header
      assert_includes sb.send(:footer)[1], "↵ new workspace", "on a project, ↵ creates"
    end

    # A background reload (tick/poke) rebuilds @nodes then recomputes — the active
    # filter must re-apply, not silently drop you back to the full tree.
    def test_a_rebuild_reapplies_the_active_filter
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/be")
      sb.send(:recompute_rows) # as a reload would, after rebuilding @nodes
      assert_equal %w[beta], ws_names(sb), "the filter still applies after a reload recompute"
    end

    # --- inline name prompts: raw-mode edit, Esc/Ctrl-C cancel (issue #68) ----

    # Drive prompt_line over a scripted key stream. draw_prompt is silenced so the
    # test never paints to the real tty; read_prompt_key pops the next scripted key.
    def drive_prompt(sb, keys)
      keys = keys.dup
      result = nil
      capture_stdout do # swallow prompt_line's ensure cursor-restore escape
        stub_method(sb, :draw_prompt, ->(*) {}) do
          stub_method(sb, :read_prompt_key, -> { keys.shift }) do
            result = sb.send(:prompt_line, "name")
          end
        end
      end
      result
    end

    def capture_stdout
      orig = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = orig
    end

    def test_prompt_line_returns_the_typed_name_on_enter
      assert_equal "feat-x", drive_prompt(sidebar, ["f", "e", "a", "t", "-", "x", "\r"])
    end

    # The crux of #68: Esc reaches us as a byte in raw mode and cancels — the old
    # cooked gets swallowed it, leaving the prompt with no way out but killing the pane.
    def test_prompt_line_esc_cancels_returning_nil
      assert_nil drive_prompt(sidebar, ["a", "b", "\e"]), "Esc aborts the prompt"
    end

    def test_prompt_line_ctrl_c_cancels_returning_nil
      assert_nil drive_prompt(sidebar, ["a", "\x03"]), "Ctrl-C aborts (raw mode: a byte, not a signal)"
    end

    def test_prompt_line_backspace_trims_the_buffer
      assert_equal "ab", drive_prompt(sidebar, ["a", "b", "c", "\x7F", "\r"])
    end

    # An arrow key is a 3-byte burst — neither a bare Esc (cancel) nor a printable
    # byte (append) — so it's dropped, never mistaken for an Esc that would cancel.
    def test_prompt_line_ignores_escape_sequence_bursts
      assert_equal "ab", drive_prompt(sidebar, ["a", "\e[A", "b", "\r"])
    end

    # A paste (or fast key-repeat) lands as ONE multi-byte read — it must contribute
    # all its printable bytes, not be dropped whole. The `a` clone-URL / local-path
    # prompts are pasted, never typed; cooked gets buffered them, raw mode must too.
    def test_prompt_line_accepts_a_pasted_multibyte_chunk
      url = "git@github.com:wvmitchell/switchboard.git"
      assert_equal url, drive_prompt(sidebar, [url, "\r"])
    end

    # An arrow burst embedded mid-paste still drops whole — its "[A" bytes must not
    # leak into the name even though they're individually printable.
    def test_prompt_line_drops_an_arrow_burst_within_a_chunk
      assert_equal "ab", drive_prompt(sidebar, ["a\e[Ab", "\r"])
    end

    # A stray non-printable byte (a high 0x80, a lone control char) is dropped, never
    # appended or a crash — the same byte-level printable? guard the filter uses.
    def test_prompt_line_drops_a_stray_non_printable_byte
      assert_equal "ab", drive_prompt(sidebar, ["a", "\x80".b, "b", "\r"])
    end

    # Ctrl-U wipes the buffer; what's typed after is all that submits.
    def test_prompt_line_ctrl_u_clears_the_line
      assert_equal "new", drive_prompt(sidebar, ["o", "l", "d", "\x15", "n", "e", "w", "\r"])
    end

    # \n submits like \r (a pasted line ends in \n, not \r).
    def test_prompt_line_submits_on_a_bare_newline
      assert_equal "feat", drive_prompt(sidebar, ["f", "e", "a", "t", "\n"])
    end

    # A bare ↵ (and whitespace-only, stripped) yields "" — blank_input? treats that
    # as cancel too, so the old empty-enter escape hatch survives alongside Esc.
    def test_prompt_line_empty_enter_is_a_blank_cancel
      sb = sidebar
      assert_equal "", drive_prompt(sb, [" ", " ", "\r"]), "whitespace is stripped away"
      assert sb.send(:blank_input?, ""), "...and an empty result cancels"
    end

    def test_read_prompt_key_returns_nil_on_a_dead_pane
      sb = Sidebar.new
      r, w = IO.pipe
      w.close # reader at EOF — select wakes, read_nonblock raises EOFError
      with_stdin(r) { assert_nil sb.send(:read_prompt_key), "a closed pane cancels, never spins" }
    ensure
      r.close
    end

    def test_draw_prompt_advertises_esc_cancel_until_you_type
      sb = sidebar
      empty = capture_stdout { sb.send(:draw_prompt, "new workspace in app", "") }
      typed = capture_stdout { sb.send(:draw_prompt, "new workspace in app", "feat") }
      assert_includes empty, "esc cancel", "the escape hatch is advertised on an empty prompt (#68)"
      assert_includes empty, "new workspace in app", "...alongside the label"
      refute_includes typed, "esc cancel", "the hint clears once you start typing"
      assert_includes typed, "feat", "...showing the typed name instead"
    end

    # create aborts cleanly on a cancelled prompt: nothing built, just a reload back
    # to the tree (no more killing the sidebar to back out — issue #68).
    def test_create_aborts_when_the_prompt_is_cancelled
      sb = sidebar(nodes: [proj("app")], cursor: 0)
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Creator, :create, ->(*) { flunk "nothing is created on cancel" }) do
            stub_method(Tmux, :go, ->(*, **) { flunk "no switch on cancel" }) do
              sb.send(:create)
            end
          end
        end
      end
      assert reloaded, "a cancelled create returns to the tree"
    end

    def test_rename_aborts_when_the_prompt_is_cancelled
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app"), ws("alpha", path: "/wt/alpha")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Git, :move_worktree, ->(*, **) { flunk "no move on cancel" }) do
            sb.send(:rename)
          end
        end
      end
      assert reloaded, "a cancelled rename returns to the tree"
    end

    def test_add_local_aborts_when_the_prompt_is_cancelled
      sb = sidebar
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Registrar, :register, ->(*) { flunk "nothing is registered on cancel" }) do
            sb.send(:add_local)
          end
        end
      end
      assert reloaded, "a cancelled add-local returns to the tree"
    end

    def test_add_clone_aborts_when_the_prompt_is_cancelled
      sb = sidebar
      reloaded = false
      stub_method(sb, :prompt_line, ->(*) { nil }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          stub_method(Registrar, :clone, ->(*) { flunk "nothing is cloned on cancel" }) do
            sb.send(:add_clone)
          end
        end
      end
      assert reloaded, "a cancelled add-clone returns to the tree"
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

    # --- R: force a PR refresh now (T4 manual trigger) -----------------------
    # A PR merged/closed on GitHub fires no local trigger, so R fans a refresh
    # across every registered project (bypassing the staleness gates) and notifies
    # so the keypress is felt even when nothing changed.
    def test_R_refreshes_every_registered_project_and_notifies
      ENV["SWITCHBOARD_BIN"] = "/opt/sb" # the wrapper is what lets a refresh spawn
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" },
                                                        { "name" => "lib", "path" => "/y" }]))
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@config, Config.new)
      refreshed = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| refreshed << p }
      notified = nil
      stub_method(Tmux, :notify, ->(msg) { notified = msg }) do
        sb.send(:dispatch, "R")
      end
      assert_equal %w[app lib], refreshed, "R refreshes every project, not just the highlighted one"
      assert_match(/refreshing PRs/, notified.to_s, "R confirms the keypress on the status line")
    end

    # Without the wrapper, maybe_refresh_prs can't spawn — so R must not claim a
    # refresh on the status line either.
    def test_R_is_silent_without_the_wrapper
      ENV.delete("SWITCHBOARD_BIN")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      sb = sidebar(nodes: [proj("app")])
      sb.instance_variable_set(:@config, Config.new)
      refreshed = []
      sb.define_singleton_method(:maybe_refresh_prs) { |p| refreshed << p }
      notified = false
      stub_method(Tmux, :notify, ->(_msg) { notified = true }) do
        sb.send(:dispatch, "R")
      end
      assert_empty refreshed, "no wrapper ⇒ nothing spawns"
      refute notified, "...and no misleading 'refreshing' notify"
    end

    # --- O / open_repo: open the row's repo in the browser (issue #63) ---------
    # browse_args is the pure decision behind O: the `gh browse` sub-args, with
    # --branch only when the row has an OPEN PR. An open (or draft) PR guarantees
    # its head branch is still on the remote (GitHub closes a PR the instant its
    # branch is deleted), so /tree/<branch> resolves; a merged/closed PR keeps its
    # badge after the branch is gone, so it must NOT deep-link (it would 404).

    def tree_node(kind:, path: "/wt/x", branch: nil, pr: nil)
      Tree::Node.new(kind: kind, project: "app", path: path, branch: branch, pr: pr)
    end

    def test_browse_args_project_header_opens_repo_home
      assert_equal ["browse"], Sidebar.browse_args(tree_node(kind: "proj", path: "/repos/app"))
    end

    def test_browse_args_open_pr_deep_links_the_branch
      n = tree_node(kind: "ws", branch: "feat", pr: { "identifier" => "#7", "status" => "OPEN", "is_draft" => 0 })
      assert_equal ["browse", "--branch", "feat"], Sidebar.browse_args(n)
    end

    # A draft PR is OPEN (is_draft just flags the badge color), so its branch is on
    # the remote — deep-link it too.
    def test_browse_args_draft_pr_still_deep_links
      n = tree_node(kind: "ws", branch: "feat", pr: { "identifier" => "#8", "status" => "OPEN", "is_draft" => 1 })
      assert_equal ["browse", "--branch", "feat"], Sidebar.browse_args(n)
    end

    # The load-bearing correctness case: a merged PR's branch is often deleted, so
    # --branch would 404. Fall back to the repo home.
    def test_browse_args_merged_pr_falls_back_to_repo_home
      n = tree_node(kind: "br", branch: "feat", pr: { "identifier" => "#9", "status" => "MERGED", "is_draft" => 0 })
      assert_equal ["browse"], Sidebar.browse_args(n)
    end

    # A fresh, unpushed branch has no PR badge — repo home, never a 404.
    def test_browse_args_no_pr_falls_back_to_repo_home
      assert_equal ["browse"], Sidebar.browse_args(tree_node(kind: "ws", branch: "feat", pr: nil))
    end

    # Defensive: an OPEN PR with an empty branch (e.g. a detached-HEAD worktree)
    # must not emit `--branch ""` — fall back to repo home.
    def test_browse_args_open_pr_but_empty_branch_falls_back
      assert_equal ["browse"], Sidebar.browse_args(tree_node(kind: "ws", branch: "", pr: { "status" => "OPEN" }))
    end

    def test_browse_args_nil_or_pathless_returns_nil
      assert_nil Sidebar.browse_args(nil)
      assert_nil Sidebar.browse_args(tree_node(kind: "ws", path: nil, branch: "feat",
                                               pr: { "status" => "OPEN" }))
    end

    def test_dispatch_O_opens_the_repo
      sb = sidebar(nodes: [proj("app")])
      called = false
      sb.define_singleton_method(:open_repo) { called = true }
      sb.send(:dispatch, "O")
      assert called, "O routes to open_repo"
    end

    def test_dispatch_H_toggles_the_full_header
      sb = sidebar(nodes: [proj("app")])
      sb.send(:dispatch, "H")
      assert sb.instance_variable_get(:@full_header), "H routes to toggle_full_header"
      assert FullHeader.enabled?, "and writes through to the shared store"
    end

    # open_repo wires browse_args into the detached gh spawn, chdir'd to the row.
    def test_open_repo_spawns_gh_browse_in_the_rows_dir
      sb = sidebar(nodes: [proj("app")]) # proj path "/repos/app" → repo home
      captured = nil
      stub_method(Process, :spawn, ->(*a, **k) { captured = [a, k]; 4242 }) do
        stub_method(Process, :detach, ->(pid) { pid }) do
          sb.send(:open_repo)
        end
      end
      assert_equal ["gh", "browse"], captured[0]
      assert_equal "/repos/app", captured[1][:chdir]
    end

    # The UI-never-crashes guarantee: a missing dir / no `gh` raises SystemCallError
    # from spawn, which spawn_gh swallows — open_repo returns nil, never raises.
    def test_open_repo_survives_a_missing_dir_or_gh
      sb = sidebar(nodes: [proj("app")])
      stub_method(Process, :spawn, ->(*_a, **_k) { raise Errno::ENOENT }) do
        assert_nil sb.send(:open_repo)
      end
    end

    # O on the empty-tree home (no row → current nil → browse_args nil) must do
    # nothing — never spawn gh. Pins the open_repo early-return contract.
    def test_open_repo_on_empty_tree_does_not_spawn
      sb = sidebar(nodes: [])
      spawned = false
      stub_method(Process, :spawn, ->(*_a, **_k) { spawned = true; 0 }) do
        assert_nil sb.send(:open_repo)
      end
      refute spawned, "O on an empty tree must not spawn gh"
    end

    # Regression: open_pr now routes through the shared spawn_gh helper. It had no
    # test before; pin that the refactor preserves its exact gh invocation.
    def test_open_pr_still_spawns_gh_pr_view
      sb = sidebar(nodes: [proj("app"), tree_node(kind: "ws", path: "/wt/feat", branch: "feat")], cursor: 1)
      captured = nil
      stub_method(Process, :spawn, ->(*a, **k) { captured = [a, k]; 7 }) do
        stub_method(Process, :detach, ->(pid) { pid }) do
          sb.send(:open_pr)
        end
      end
      assert_equal ["gh", "pr", "view", "feat", "--web"], captured[0]
      assert_equal "/wt/feat", captured[1][:chdir]
    end

    # O (open the row's repo) needs no branch, so its hint rides EVERY row kind —
    # including the project header, unlike o/PR. (The empty tree has no row to open.)
    def test_footer_advertises_O_repo_on_every_row_kind
      [[proj("app")], [proj("app"), ws("a")], [proj("app"), ws("a"), br("f")]].each do |nodes|
        sb = sidebar(nodes: nodes, cursor: nodes.size - 1)
        assert sb.send(:footer).any? { |l| l.include?("O repo") },
               "O repo present for #{nodes.map(&:kind)}"
      end
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
