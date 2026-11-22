# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # A left click selects a row, and a click on the lit row (or a double-click) acts like ↵ (Sidebar::Mouse). Rows are painted under a one-line
  # header here: the project on line 2, workspace a on 3, b on 4.
  class SidebarMouseTest < SidebarCase
    def press(y, button: 0) = "\e[<#{button};5;#{y}M"
    def release(y, button: 0) = "\e[<#{button};5;#{y}m"
    def click(y) = press(y) + release(y)

    def clicky(nodes: [proj("app"), ws("a"), ws("b")], cursor: 0)
      sb = sidebar(nodes: nodes, cursor: cursor)
      sb.instance_variable_set(:@mouse, true)
      paint(sb)
      sb
    end

    # What render records, without a terminal.
    def paint(sb, top: 1)
      sb.instance_variable_set(:@painted_top, top)
      sb.instance_variable_set(:@visible_rows, sb.instance_variable_get(:@rows).dup)
    end

    # What render records when the focused sidebar's bar sits on row i.
    def light(sb, i)
      sb.instance_variable_set(:@painted_bar, sb.send(:row_key, sb.instance_variable_get(:@rows)[i]))
    end

    def at(sb, now)
      sb.define_singleton_method(:monotonic) { now }
    end

    # Records the switches.
    def with_tmux
      log = { go: [] }
      stub_method(Tmux, :broadcast_warm, ->(**) {}) do
        stub_method(Tmux, :go, ->(wt, start:) { log[:go] << wt.path }) do
          yield log
        end
      end
    end

    # Two clicks on line y, 0.2 s apart, then the run loop once tmux's own double-click has run.
    def double_click(sb, y, from: 100.0)
      at(sb, from)
      sb.send(:handle, click(y))
      at(sb, from + 0.2)
      sb.send(:handle, click(y))
      at(sb, from + 0.2 + Sidebar::Mouse::CLICK_SETTLE)
      sb.send(:open_due_click)
    end

    def test_a_click_selects_the_row_and_opens_nothing
      sb = clicky
      with_tmux do |log|
        assert sb.send(:handle, click(3))
        assert_equal 1, cursor_of(sb)
        assert_empty log[:go]
      end
    end

    def test_a_double_click_on_a_workspace_switches_there
      sb = clicky
      with_tmux do |log|
        double_click(sb, 3)
        assert_equal [wt("a")], log[:go]
      end
    end

    def test_a_double_click_on_a_project_folds_it_once
      sb = clicky
      with_tmux do |log|
        double_click(sb, 2)
        assert_includes sb.instance_variable_get(:@collapsed), "app"
        assert_empty log[:go]
      end
    end

    def test_a_click_on_a_project_does_not_fold_it
      sb = clicky
      with_tmux { sb.send(:handle, click(2)) }
      refute_includes sb.instance_variable_get(:@collapsed), "app"
    end

    def test_a_triple_click_opens_once
      sb = clicky
      with_tmux do
        at(sb, 100.0)
        sb.send(:handle, click(2))
        at(sb, 100.2)
        sb.send(:handle, click(2))
        at(sb, 100.4)
        sb.send(:handle, click(2))
        at(sb, 100.5)
        sb.send(:open_due_click)
        refute_includes sb.instance_variable_get(:@collapsed), "app", "the third click pushed the open back"
        at(sb, 100.4 + Sidebar::Mouse::CLICK_SETTLE)
        sb.send(:open_due_click)
      end
      assert_includes sb.instance_variable_get(:@collapsed), "app", "folded once, not back open"
    end

    def test_one_click_on_the_lit_row_opens_it
      sb = clicky(cursor: 1)
      light(sb, 1)
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        assert_empty log[:go], "it waits out a possible double-click"
        at(sb, 100.0 + Sidebar::Mouse::CLICK_SETTLE)
        sb.send(:open_due_click)
        assert_equal [wt("a")], log[:go]
      end
    end

    def test_a_double_click_on_the_lit_row_opens_it_once
      sb = clicky(cursor: 1)
      light(sb, 1)
      with_tmux do |log|
        double_click(sb, 3)
        sb.send(:open_due_click)
        assert_equal [wt("a")], log[:go]
      end
    end

    # tmux focuses the sidebar as part of the click, so the bar wasn't showing when it landed.
    def test_a_click_that_focused_the_sidebar_only_selects
      sb = clicky(cursor: 1)
      light(sb, 1)
      sb.instance_variable_set(:@focused_at, 100.0)
      with_tmux do |log|
        at(sb, 100.01)
        sb.send(:handle, click(3))
        at(sb, 101.0)
        sb.send(:open_due_click)
        assert_empty log[:go]
      end
    end

    def test_a_click_on_another_row_cancels_a_pending_open
      sb = clicky(cursor: 1)
      light(sb, 1)
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        at(sb, 100.1)
        sb.send(:handle, click(4))
        at(sb, 101.0)
        sb.send(:open_due_click)
        assert_empty log[:go]
        assert_equal 2, cursor_of(sb)
      end
    end

    def test_clicks_too_far_apart_are_two_selects
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        at(sb, 100.6)
        sb.send(:handle, click(3))
        assert_empty log[:go]
        at(sb, 100.8)
        sb.send(:handle, click(3))
        at(sb, 101.2)
        sb.send(:open_due_click)
        assert_equal [wt("a")], log[:go], "the late click starts a new pair"
      end
    end

    def test_two_clicks_on_different_rows_open_nothing
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        at(sb, 100.2)
        sb.send(:handle, click(4))
        assert_empty log[:go]
        assert_equal 2, cursor_of(sb)
      end
    end

    # A repaint moved another row under the line between the two clicks.
    def test_the_second_click_must_hit_the_same_row
      sb = clicky(nodes: [proj("app"), ws("a"), proj("lib"), ws("z", project: "lib")])
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3)) # a
        sb.instance_variable_set(:@visible_rows, sb.instance_variable_get(:@rows)[1..]) # lib now on 3
        at(sb, 100.2)
        sb.send(:handle, click(3))
        assert_empty log[:go]
        refute_includes sb.instance_variable_get(:@collapsed), "lib"
      end
    end

    # The same row, scrolled to another line: a different click target, so no double-click.
    def test_the_second_click_must_be_on_the_same_line
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3)) # a on line 3
        paint(sb, top: 2)          # a now on line 4
        at(sb, 100.2)
        sb.send(:handle, click(4))
        assert_empty log[:go]
      end
    end

    # Value: protects=focus lands on the agent after a double-click switch; fails_when=the open
    # runs before tmux's DoubleClick1Pane binding (which selects the new session's sidebar) or
    # the loop sleeps past it; why_new=found live in the smoke test; seam=none; no_claim=tmux's
    # exact delay (smoke)
    def test_the_open_waits_out_tmuxs_double_click_and_the_loop_wakes_for_it
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        at(sb, 100.2)
        sb.send(:handle, click(3))
        sb.send(:open_due_click)
        assert_empty log[:go], "held"
        assert_in_delta Sidebar::Mouse::CLICK_SETTLE, sb.send(:frame_timeout), 0.001, "the select wakes for it"
        at(sb, 100.2 + Sidebar::Mouse::CLICK_SETTLE)
        sb.send(:open_due_click)
        assert_equal [wt("a")], log[:go]
        sb.send(:open_due_click)
        assert_equal 1, log[:go].size, "once"
        assert_nil sb.send(:mouse_open_wait), "the loop goes back to its own sleep"
      end
    end

    def test_a_held_open_yields_to_an_overlay_or_search_opened_meanwhile
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        at(sb, 100.2)
        sb.send(:handle, click(3) + "?")
        at(sb, 101.0)
        sb.send(:open_due_click)
        assert_empty log[:go]
      end
    end

    def test_a_press_moves_the_cursor_and_a_release_elsewhere_cancels
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, press(3) + release(4))
        assert_equal 1, cursor_of(sb), "the press moved the cursor"
        at(sb, 100.2)
        sb.send(:handle, click(3))
        assert_empty log[:go], "a drag off the row isn't a click, so this is the first"
      end
    end

    def test_lines_without_a_row_do_nothing
      sb = clicky(cursor: 1)
      with_tmux do |log|
        [1, 0, 5, 40].each { |y| double_click(sb, y) } # header, out of range, past the rows
        assert_empty log[:go]
        assert_equal 1, cursor_of(sb)
      end
    end

    def test_nothing_is_hit_before_the_first_render
      sb = clicky
      sb.instance_variable_set(:@painted_top, nil)
      with_tmux do |log|
        double_click(sb, 3)
        assert_empty log[:go]
        assert_equal 0, cursor_of(sb)
      end
    end

    def test_a_scrolled_view_hits_the_painted_slice
      sb = clicky
      sb.instance_variable_set(:@visible_rows, sb.instance_variable_get(:@rows)[1..]) # scrolled one down
      with_tmux do |log|
        double_click(sb, 2)
        assert_equal [wt("a")], log[:go]
      end
    end

    def test_other_buttons_the_wheel_and_modifiers_do_nothing_and_keep_a_count
      sb = clicky
      sb.instance_variable_set(:@count, "3")
      with_tmux do |log|
        2.times { [2, 64, 65, 32, 4, 8, 16].each { |b| sb.send(:handle, press(3, button: b) + release(3, button: b)) } }
        assert_empty log[:go]
        assert_equal 0, cursor_of(sb)
        assert_equal "3", sb.instance_variable_get(:@count)
        assert sb.instance_variable_get(:@idle_read), "a read of only ignored reports skips its repaint"
      end
    end

    def test_a_click_clears_a_half_typed_count
      sb = clicky
      sb.instance_variable_set(:@count, "3")
      with_tmux { sb.send(:handle, click(3)) }
      assert_nil sb.instance_variable_get(:@count)
    end

    def test_reports_are_ignored_while_mouse_is_off
      sb = clicky
      sb.instance_variable_set(:@mouse, false)
      with_tmux do |log|
        assert sb.send(:handle, click(3)), "a report never ends the loop"
        double_click(sb, 3)
        assert_empty log[:go]
        assert_equal 0, cursor_of(sb)
        assert sb.instance_variable_get(:@idle_read)
      end
    end

    def test_a_report_leaves_overlays_open_and_a_typed_search_alone
      sb = clicky
      sb.instance_variable_set(:@help, true)
      with_tmux { double_click(sb, 3) }
      assert sb.instance_variable_get(:@help), "? stays open"

      sb.instance_variable_set(:@help, false)
      sb.send(:start_search)
      with_tmux do |log|
        double_click(sb, 3)
        assert_empty log[:go]
      end
      assert_equal "", sb.instance_variable_get(:@search).query
    end

    def test_a_click_under_a_committed_search_selects_and_keeps_it
      sb = clicky
      sb.send(:handle, "/b\t")
      with_tmux { sb.send(:handle, click(3)) }
      assert sb.instance_variable_get(:@search).committed?
    end

    def test_a_double_click_under_a_committed_search_opens_like_enter
      sb = clicky
      sb.send(:handle, "/b\t")
      assert sb.instance_variable_get(:@search).committed?
      with_tmux do |log|
        double_click(sb, 3)
        assert_equal [wt("a")], log[:go]
      end
      refute sb.instance_variable_get(:@search).active?, "it ends the search, as ↵ does"
    end

    def test_a_header_double_click_under_a_committed_search_only_ends_it
      sb = clicky
      sb.send(:handle, "/b\t")
      with_tmux { double_click(sb, 2) }
      refute sb.instance_variable_get(:@search).active?
      refute_includes sb.instance_variable_get(:@collapsed), "app", "no fold written"
    end

    def test_the_release_opens_the_pressed_row_even_if_rows_moved
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        at(sb, 100.2)
        sb.send(:handle, press(3))
        sb.instance_variable_set(:@nodes, [proj("app"), ws("new"), ws("a"), ws("b")]) # a rebuild between
        sb.send(:recompute_rows)
        paint(sb)
        sb.send(:handle, release(3))
        at(sb, 101.0)
        sb.send(:open_due_click)
        assert_equal [wt("a")], log[:go], "the pressed row, not what's on the line now"
      end
    end

    def test_a_stale_press_is_forgotten
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        sb.send(:handle, press(3))
        at(sb, 101.5)
        sb.send(:handle, release(3))
        assert_empty log[:go]
      end
    end

    def test_focus_out_forgets_a_press
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        sb.send(:handle, press(3) + "\e[O" + release(3))
        assert_empty log[:go]
      end
    end

    def test_a_press_off_the_rows_forgets_the_old_one
      sb = clicky
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        sb.send(:handle, press(3)) # drag off, no release
        sb.send(:handle, press(1)) # a header press
        sb.send(:handle, release(3))
        assert_empty log[:go]
      end
    end

    def test_a_double_click_that_raises_a_flash_leaves_it_up
      sb = clicky
      rec = { "id" => "r1", "state" => "building", "path" => wt("a") }
      sb.instance_variable_set(:@creation_for, { wt("a") => rec })
      shown = nil
      stub_method(sb, :flash, ->(msg) { shown = msg }) do
        stub_method(Tmux, :session_for, ->(*) { nil }) do
          with_tmux { |log| double_click(sb, 3) && assert_empty(log[:go]) }
        end
      end
      assert_equal "still creating…", shown
    end

    # --- turning reports on and off ------------------------------------------

    def test_sync_writes_on_its_first_call_even_when_off
      sb = sidebar
      stub_method(Tmux, :mouse?, ->(*) { false }) do
        assert_equal Sidebar::Mouse::MOUSE_OFF, capture_stdout { sb.send(:sync_mouse) }
        assert_equal "", capture_stdout { sb.send(:sync_mouse) }, "only on a change"
      end
      stub_method(Tmux, :mouse?, ->(*) { true }) do
        assert_equal Sidebar::Mouse::MOUSE_ON, capture_stdout { sb.send(:sync_mouse) }
      end
    end

    def test_sidebar_mouse_false_keeps_reports_off_without_asking_tmux
      File.write(Config.path, YAML.dump("sidebar_mouse" => false))
      sb = sidebar
      sb.instance_variable_set(:@config, Config.new)
      sb.instance_variable_set(:@mouse, true)
      stub_method(Tmux, :mouse?, ->(*) { flunk "no tmux read with the key off" }) do
        assert_equal Sidebar::Mouse::MOUSE_OFF, capture_stdout { sb.send(:sync_mouse) }
      end
    end

    def test_focus_in_rereads_tmux_at_most_once_a_second
      sb = sidebar
      sb.instance_variable_set(:@visible, true)
      reads = 0
      at(sb, 100.0)
      stub_method(Tmux, :mouse?, ->(*) { reads += 1; false }) do
        stub_method(sb, :lone_pane_handled, ->(*) { false }) do
          capture_stdout do
            sb.send(:focus_in)
            sb.send(:focus_in)
            at(sb, 101.5)
            sb.send(:focus_in)
          end
        end
      end
      assert_equal 2, reads
    end

    def test_teardown_turns_reports_off_unless_they_already_are
      sb = sidebar
      [[nil, true], [true, true], [false, false]].each do |state, writes|
        sb.instance_variable_set(:@mouse, state)
        out = stub_method($stdin, :cooked!, -> {}) { capture_stdout { sb.send(:teardown) } }
        assert_equal writes, out.include?(Sidebar::Mouse::MOUSE_OFF), "@mouse=#{state.inspect}"
      end
    end

    def test_the_help_overlay_lists_the_click_beside_enter_only_while_clicks_are_live
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { [] }) do
        refute(sb.send(:help_lines, 40).any? { |l| strip_ansi(l).start_with?("click") })
        sb.instance_variable_set(:@mouse, true)
        rows = sb.send(:help_key_rows)
        enter = rows.index { |k, _| k == "↵" }
        assert_equal ["click", "select; again = ↵"], rows[enter + 1], "in ↵'s section, right after it"
      end
    end

    # --- a split escape at a read boundary -------------------------------------

    def typed(*reads, task: false)
      out = nil
      with_reads(sb = sidebar, *reads) { out = sb.send(:prompt_line, "name", task: task) }
      out
    end

    def test_a_click_in_a_prompt_types_nothing
      assert_equal "abcd", typed("ab#{click(3)}cd\r")
    end

    def test_a_click_split_at_any_read_boundary_types_nothing
      ["\e", "\e[", "\e[<", "\e[<0;", "\e[<0;5;1"].each do |head|
        tail = click(12).delete_prefix(head)
        assert_equal "ab", typed("ab#{head}", tail, "\r"), head.inspect
      end
    end

    def test_a_lone_esc_at_the_end_of_a_read_still_cancels
      assert_nil typed("ab\e")
    end

    def test_report_shaped_text_inside_a_paste_is_kept
      assert_includes typed("\e[200~x#{press(3)}y\e[201~", "\r", task: true), "[<0;5;3My"
    end

    def test_a_click_cannot_answer_a_confirm
      said = nil
      with_reads(sb = sidebar, click(3), "y") { said = sb.send(:confirm, "delete x?") }
      assert_equal true, said
      with_reads(sb = sidebar, "\e", "[<0;5;3M", "y") { said = sb.send(:confirm, "delete x?") }
      assert_equal true, said, "a split report isn't an Esc"
    end

    def test_escape_tail_spots_the_start_of_an_escape
      ["a\e", "a\e[", "a\e[<", "a\e[<0;", "a\e[<0;12"].each { |s| assert Sidebar::Input.escape_tail?(s), s.inspect }
      ["a", "\e[A", "a\e[<0;1;2M", "a\e[2"].each { |s| refute Sidebar::Input.escape_tail?(s), s.inspect }
    end
  end
end
