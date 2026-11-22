# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # A left click on a row acts like ↵ (Sidebar::Mouse). Rows are painted under a one-line
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

    def at(sb, now)
      sb.define_singleton_method(:monotonic) { now }
    end

    # Records the switches and focus hand-backs; no marker unless one is given.
    def with_tmux(marker: nil)
      log = { go: [], focus: 0, marker_reads: 0 }
      stub_method(Tmux, :click_switch_at, ->(*) { log[:marker_reads] += 1; marker }) do
        stub_method(Tmux, :focus_work, ->(*) { log[:focus] += 1 }) do
          stub_method(Tmux, :session_of, ->(*) { "sb/app/b" }) do
            stub_method(Tmux, :broadcast_warm, ->(**) {}) do
              stub_method(Tmux, :go, ->(wt, start:, click_stamp: false) { log[:go] << [wt.path, click_stamp] }) do
                yield log
              end
            end
          end
        end
      end
    end

    def test_a_click_on_a_workspace_switches_there_and_stamps_the_switch
      sb = clicky
      with_tmux do |log|
        sb.send(:handle, click(3))
        assert_equal [[wt("a"), true]], log[:go]
      end
    end

    def test_a_click_on_a_project_folds_it
      sb = clicky
      with_tmux do |log|
        sb.send(:handle, click(2))
        assert_includes sb.instance_variable_get(:@collapsed), "app"
        assert_empty log[:go]
      end
    end

    def test_keyboard_enter_never_stamps
      sb = clicky(cursor: 1)
      with_tmux do |log|
        sb.send(:handle, "\r")
        assert_equal [[wt("a"), false]], log[:go]
      end
    end

    def test_a_press_moves_the_cursor_and_a_release_elsewhere_cancels
      sb = clicky
      with_tmux do |log|
        sb.send(:handle, press(3) + release(4))
        assert_empty log[:go], "a drag off the row cancels"
        assert_equal 1, cursor_of(sb), "the press still moved the cursor"
      end
    end

    def test_lines_without_a_row_do_nothing
      sb = clicky(cursor: 1)
      with_tmux do |log|
        [1, 0, 5, 40].each { |y| sb.send(:handle, click(y)) } # header, out of range, past the rows
        assert_empty log[:go]
        assert_equal 1, cursor_of(sb)
      end
    end

    def test_nothing_is_hit_before_the_first_render
      sb = clicky
      sb.instance_variable_set(:@painted_top, nil)
      with_tmux do |log|
        sb.send(:handle, click(3))
        assert_empty log[:go]
      end
    end

    def test_a_scrolled_view_hits_the_painted_slice
      sb = clicky
      sb.instance_variable_set(:@visible_rows, sb.instance_variable_get(:@rows)[1..]) # scrolled one down
      with_tmux do |log|
        sb.send(:handle, click(2))
        assert_equal [[wt("a"), true]], log[:go]
      end
    end

    def test_other_buttons_the_wheel_and_modifiers_do_nothing_and_keep_a_count
      sb = clicky
      sb.instance_variable_set(:@count, "3")
      with_tmux do |log|
        [2, 64, 65, 32, 4, 8, 16].each { |b| sb.send(:handle, press(3, button: b) + release(3, button: b)) }
        assert_empty log[:go]
        assert_equal "3", sb.instance_variable_get(:@count)
        assert sb.instance_variable_get(:@idle_read), "a read of only ignored reports skips its repaint"
      end
    end

    def test_reports_are_ignored_while_mouse_is_off
      sb = clicky
      sb.instance_variable_set(:@mouse, false)
      with_tmux do |log|
        assert sb.send(:handle, click(3)), "a report never ends the loop"
        assert_empty log[:go]
        assert sb.instance_variable_get(:@idle_read)
      end
    end

    def test_a_report_leaves_overlays_open_and_a_typed_search_alone
      sb = clicky
      sb.instance_variable_set(:@help, true)
      with_tmux { sb.send(:handle, click(3)) }
      assert sb.instance_variable_get(:@help), "? stays open"

      sb.instance_variable_set(:@help, false)
      sb.send(:start_search)
      with_tmux do |log|
        sb.send(:handle, click(3))
        assert_empty log[:go]
      end
      assert_equal "", sb.instance_variable_get(:@search).query
    end

    def test_a_click_under_a_committed_search_opens_like_enter
      sb = clicky
      sb.send(:handle, "/b\t")
      assert sb.instance_variable_get(:@search).committed?
      with_tmux do |log|
        sb.send(:handle, click(3))
        assert_equal [[wt("a"), true]], log[:go]
      end
      refute sb.instance_variable_get(:@search).active?, "it ends the search, as ↵ does"
    end

    def test_a_header_click_under_a_committed_search_only_ends_it
      sb = clicky
      sb.send(:handle, "/b\t")
      with_tmux { sb.send(:handle, click(2)) }
      refute sb.instance_variable_get(:@search).active?
      refute_includes sb.instance_variable_get(:@collapsed), "app", "no fold written"
    end

    def test_a_double_click_on_a_header_folds_once
      sb = clicky
      at(sb, 100.0)
      with_tmux do
        sb.send(:handle, click(2))
        at(sb, 100.2)
        sb.send(:handle, click(2))
      end
      assert_includes sb.instance_variable_get(:@collapsed), "app", "the second click didn't unfold it"
    end

    def test_the_quiet_window_is_the_line_not_the_row
      sb = clicky(nodes: [proj("app"), ws("a"), proj("lib"), ws("z", project: "lib")])
      at(sb, 100.0)
      with_tmux do
        sb.send(:handle, click(2)) # fold app
        rows = sb.instance_variable_get(:@rows)
        sb.instance_variable_set(:@visible_rows, rows[1..]) # a scroll clamp puts lib on line 2
        sb.send(:handle, click(2)) # the double-click's second half, within 0.4 s
      end
      refute_includes sb.instance_variable_get(:@collapsed), "lib", "dropped, though another row is there now"
    end

    def test_after_the_quiet_window_the_same_line_acts_again
      sb = clicky
      at(sb, 100.0)
      with_tmux do
        sb.send(:handle, click(2))
        at(sb, 100.5)
        sb.send(:handle, click(2))
      end
      refute_includes sb.instance_variable_get(:@collapsed), "app"
    end

    def test_expanding_a_project_then_clicking_its_workspace_at_once_opens_it
      sb = clicky
      sb.instance_variable_set(:@collapsed, Set.new(["app"]))
      sb.send(:recompute_rows)
      paint(sb)
      at(sb, 100.0)
      with_tmux do |log|
        sb.send(:handle, click(2))
        paint(sb)
        at(sb, 100.1)
        sb.send(:handle, click(3))
        assert_equal [[wt("a"), true]], log[:go]
      end
    end

    def test_the_release_opens_the_pressed_row_even_if_rows_moved
      sb = clicky
      with_tmux do |log|
        sb.send(:handle, press(3))
        sb.instance_variable_set(:@nodes, [proj("app"), ws("new"), ws("a"), ws("b")]) # a rebuild between
        sb.send(:recompute_rows)
        paint(sb)
        sb.send(:handle, release(3))
        assert_equal [[wt("a"), true]], log[:go], "the pressed row, not what's on the line now"
      end
    end

    def test_a_stale_press_is_forgotten
      sb = clicky
      at(sb, 100.0)
      with_tmux do |log|
        sb.send(:handle, press(3))
        at(sb, 101.5)
        sb.send(:handle, release(3))
        assert_empty log[:go]
      end
    end

    def test_focus_out_forgets_a_press
      sb = clicky
      with_tmux do |log|
        sb.send(:handle, press(3) + "\e[O" + release(3))
        assert_empty log[:go]
      end
    end

    def test_a_new_press_forgets_the_old_one
      sb = clicky
      with_tmux do |log|
        sb.send(:handle, press(3)) # drag off, no release
        sb.send(:handle, press(1)) # a header press
        sb.send(:handle, release(3))
        assert_empty log[:go]
      end
    end

    # The second half of a double-click that switched the client here.
    def test_a_report_just_after_a_click_switch_is_dropped_and_focus_goes_back
      sb = clicky(cursor: 2)
      sb.instance_variable_set(:@read_at, 50.2)
      sb.instance_variable_set(:@input_since, 50.2)
      with_tmux(marker: 50.0) do |log|
        sb.send(:handle, click(3))
        assert_empty log[:go]
        assert_equal 2, cursor_of(sb), "the press didn't move the cursor"
        assert_equal 1, log[:focus], "focus handed back once for the batch"
        assert_equal 1, log[:marker_reads], "one tmux read a batch"
      end
    end

    def test_a_guarded_report_on_a_blank_line_still_hands_focus_back
      sb = clicky
      sb.instance_variable_set(:@read_at, 50.2)
      with_tmux(marker: 50.0) do |log|
        sb.send(:handle, click(30))
        assert_equal 1, log[:focus]
      end
    end

    def test_a_click_queued_behind_a_slow_reload_is_still_dropped
      sb = clicky
      sb.instance_variable_set(:@read_at, 51.0)    # read a second after the switch...
      sb.instance_variable_set(:@input_since, 49.9) # ...but it could have arrived any time since
      with_tmux(marker: 50.0) do |log|
        sb.send(:handle, click(3))
        assert_empty log[:go]
      end
    end

    def test_a_later_click_in_that_session_opens
      sb = clicky
      sb.instance_variable_set(:@read_at, 51.0)
      sb.instance_variable_set(:@input_since, 51.0)
      with_tmux(marker: 50.0) do |log|
        sb.send(:handle, click(3))
        assert_equal [[wt("a"), true]], log[:go]
      end
    end

    def test_no_or_garbage_marker_lets_a_click_through
      sb = clicky
      sb.instance_variable_set(:@read_at, 50.1)
      with_tmux(marker: nil) do |log|
        sb.send(:handle, click(3))
        assert_equal 1, log[:go].size
      end
    end

    def test_a_click_that_raises_a_flash_leaves_it_up
      sb = clicky
      rec = { "id" => "r1", "state" => "building", "path" => wt("a") }
      sb.instance_variable_set(:@creation_for, { wt("a") => rec })
      shown = nil
      stub_method(sb, :flash, ->(msg) { shown = msg }) do
        stub_method(Tmux, :session_for, ->(*) { nil }) do
          with_tmux { |log| sb.send(:handle, click(3)) && assert_empty(log[:go]) }
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
        assert_equal ["click", "same as ↵"], rows[enter + 1], "in ↵'s section, right after it"
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
