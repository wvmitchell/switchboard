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

    # A click on the lit row, then the newer intent before its open runs.
    def pending_open(sb)
      light(sb, 1)
      at(sb, 100.0)
      sb.send(:handle, click(3))
    end

    def test_a_key_after_a_click_cancels_its_pending_open
      sb = clicky(cursor: 1)
      with_tmux do |log|
        pending_open(sb)
        sb.send(:handle, "j")
        at(sb, 101.0)
        sb.send(:open_due_click)
        assert_empty log[:go]
      end
    end

    def test_a_focus_out_cancels_a_pending_open
      sb = clicky(cursor: 1)
      with_tmux do |log|
        pending_open(sb)
        sb.send(:handle, "\e[O")
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

    # Value: protects=a click split by a full read types nothing in a real prompt; fails_when=
    # whole_escape's completion read can't run against the real reads (escape_rest);
    # why_new=with_reads stubs both reads; seam=none;
    # no_claim=tmux's own write boundaries (a pipe stands in for the pty)
    def test_a_click_split_by_a_full_read_types_nothing_through_the_real_reads
      sb = sidebar
      name = "a" * (Sidebar::Input::READ_BYTES - 1)
      r, w = IO.pipe
      w.write("#{name}#{click(12)}\r") # the first full read ends on the click's \e
      result = nil
      capture_stdout do
        stub_method(sb, :winsize, ->(*) { [24, 40] }) do
          with_stdin(r) { result = sb.send(:prompt_line, "name") }
        end
      end
      assert_equal name, result
    ensure
      r&.close
      w&.close
    end

    # Value: protects=the tree's read_key completes an escape a full read split, and a lone Esc or
    # a dead pane doesn't hang it; fails_when=escape_rest stops reading the queued rest, blocks
    # with nothing queued, or raises on EOF; why_new=tests stub escape_rest, and the wheel-flood
    # test only counts renders; seam=none; no_claim=tmux's write boundaries (a pipe stands in)
    def test_read_key_completes_a_split_escape_from_the_real_pipe
      sb = sidebar
      head = ("j" * (Sidebar::Input::READ_BYTES - 1)) + "\e"
      [["#{head}[<0;5;3M", "#{head}[<0;5;3M", false], [head, head, false], [head, head, true]].each do |bytes, want, eof|
        r, w = IO.pipe
        w.write(bytes)
        w.close if eof
        with_stdin(r) { assert_equal want, sb.send(:read_key), "#{bytes.bytesize} bytes, eof: #{eof}" }
      ensure
        r&.close
        w&.close unless w&.closed?
      end
    end

    # Value: protects=a held open whose row is gone by its settle does nothing; fails_when=the
    # missing-row guard goes, so @cursor turns nil and enter runs on nothing (or a stale row);
    # why_new=every held-open test keeps the row; seam=none; no_claim=a real rebuild (rows set directly)
    def test_a_held_open_whose_row_vanished_does_nothing
      sb = clicky(cursor: 1)
      light(sb, 1)
      with_tmux do |log|
        at(sb, 100.0)
        sb.send(:handle, click(3))
        sb.instance_variable_set(:@nodes, [proj("app"), ws("b")]) # a deleted between press and settle
        sb.send(:recompute_rows)
        at(sb, 101.0)
        sb.send(:open_due_click)
        assert_empty log[:go]
        assert_nil sb.instance_variable_get(:@mouse_open)
        assert_equal "b", current_node(sb).name
      end
    end

    # Value: protects=the hit test maps a screen line to the row render painted there, scrolled or
    # not, and only a focused sidebar's bar counts as lit; fails_when=@painted_top or the slice drift
    # from what's drawn, or the focus gate on @painted_bar goes; why_new=other tests set these ivars by
    # hand; seam=none; no_claim=tmux's pane offset (smoke)
    def test_render_records_what_it_painted_on_each_line
      nodes = [proj("app"), *%w[a b c d e f].map { |n| ws(n) }]
      [[30, 1], [6, 6]].each do |rows, cursor|
        sb = sidebar(nodes: nodes, cursor: cursor)
        out = nil
        stub_method(sb, :winsize, ->(*) { [rows, 40] }) { out = capture_stdout { sb.send(:render) } }
        painted = out.scan(/\e\[(\d+);1H\e\[K((?:(?!\e\[\d+;1H).)*)/m).to_h { |y, text| [y.to_i, strip_ansi(text).strip] }
        hits = painted.filter_map do |y, text|
          node = rows_of(sb).find { |n| row_key(sb, n) == sb.send(:row_key_at, y) } or next
          assert_equal (node.kind == "proj" ? "▾ #{node.project}" : node.name), text, "line #{y} (#{rows} rows)"
        end
        assert_operator hits.size, :>=, 3, "rows were hit (#{rows} rows)"
        assert_operator sb.instance_variable_get(:@offset), :>, 0 if rows == 6
        assert_equal row_key(sb, current_node(sb)), sb.instance_variable_get(:@painted_bar)
      end
      sb = sidebar(nodes: nodes, cursor: 1, focused: false)
      stub_method(sb, :winsize, ->(*) { [30, 40] }) { capture_stdout { sb.send(:render) } }
      assert_nil sb.instance_variable_get(:@painted_bar), "an unfocused sidebar shows no bar to click"
    end

    def row_key(sb, node) = sb.send(:row_key, node)

    # Value: protects=a sidebar_mouse edit reaches a visible sidebar at its next rebuild, never a
    # hidden one; fails_when=rebuild stops syncing, syncs before refresh_config, or writes to a
    # hidden pane; why_new=sync tests call sync_mouse directly; seam=none; no_claim=tmux's mouse (stubbed)
    def test_a_rebuild_applies_a_sidebar_mouse_edit_only_while_visible
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }], "sidebar_mouse" => false))
      [[true, true], [false, false]].each do |visible, writes|
        sb = sidebar(nodes: [])
        sb.instance_variable_set(:@config, Config.new)
        sb.instance_variable_set(:@mouse, true)
        sb.instance_variable_set(:@visible, visible)
        out = stub_method(Tmux, :mouse?, ->(*) { true }) { capture_stdout { sb.send(:rebuild) } }
        assert_equal writes, out.include?(Sidebar::Mouse::MOUSE_OFF), "visible: #{visible}"
        assert_equal !writes, sb.instance_variable_get(:@mouse), "visible: #{visible}"
      end
    end

    def test_escape_tail_spots_the_start_of_an_escape
      ["a\e", "a\e[", "a\e[<", "a\e[<0;", "a\e[<0;12"].each { |s| assert Sidebar::Input.escape_tail?(s), s.inspect }
      ["a", "\e[A", "a\e[<0;1;2M", "a\e[2"].each { |s| refute Sidebar::Input.escape_tail?(s), s.inspect }
    end
  end
end
