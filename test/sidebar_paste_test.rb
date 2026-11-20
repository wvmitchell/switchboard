# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # A bracketed paste is never keys anywhere in the sidebar (PasteFrame and its readers):
  # the tree drops it and says so once, a `/` search and the line prompts take it as text, a
  # one-key prompt reads it as no, and a lost end marker heals on silence.
  class SidebarPasteTest < SidebarCase
    TREE_NOTICE = "switchboard: paste ignored — press n first to paste a task"
    STALL_NOTICE = "switchboard: paste still open: stop typing, keys work again about 5s after the last one"

    # --- the tree ------------------------------------------------------------

    def test_a_paste_across_reads_is_dropped_whole_and_notified_once
      sb = three_rows
      said = notices do
        stub_method(Workspaces, :quit_all, -> { flunk "a pasted q y quit" }) do
          ["\e[200~jjq", " y dy", "kk\e[201~"].each { |r| assert sb.send(:handle, r) }
        end
      end
      assert_equal 1, cursor_of(sb), "no pasted move ran"
      assert_equal [TREE_NOTICE], said
      assert_equal 1, notices { sb.send(:handle, "\e[200~jj\e[201~") }.size, "a second paste notifies again"
    end

    def test_pokes_in_the_same_read_still_run
      sb = three_rows
      pokes = 0
      notices do
        stub_method(sb, :reload_and_refresh, -> { pokes += 1 }) { sb.send(:handle, "\f\e[200~jj\e[201~\f") }
      end
      assert_equal 2, pokes
    end

    def test_keys_after_the_end_marker_act
      sb = three_rows
      notices { sb.send(:handle, "\e[200~kk\e[201~j") }
      assert_equal 2, cursor_of(sb)
    end

    def test_a_poke_inside_an_open_paste_is_paste_text_and_restarts_the_quiet_period
      sb = three_rows
      at(0) { notices { sb.send(:handle, "\e[200~x") } }
      stub_method(sb, :reload_and_refresh, -> { flunk "a poke inside a paste ran" }) { at(4) { sb.send(:handle, "\f") } }
      refute frame(sb).expire(now: 8)
      assert frame(sb).expire(now: 9)
    end

    def test_help_stays_open_and_its_notice_says_to_close_it_first
      sb = three_rows
      sb.send(:show_help)
      said = notices { sb.send(:handle, "\e[200~q\e[201~") }
      assert sb.instance_variable_get(:@help), "help stays open"
      assert_equal ["switchboard: paste ignored — close this view, then press n to paste a task"], said

      opened = 0
      stub_method(sb, :create, -> { opened += 1 }) { sb.send(:handle, "x"); sb.send(:handle, "n") }
      assert_equal 1, opened, "following the notice opens the task prompt"
    end

    def test_the_link_view_stays_open
      sb = three_rows
      sb.instance_variable_set(:@link_view, { path: wt("a"), qr: {} })
      said = notices { sb.send(:handle, "\e[200~x\e[201~") }
      refute_nil sb.instance_variable_get(:@link_view)
      assert_equal ["switchboard: paste ignored — close this view, then press n to paste a task"], said
    end

    def test_a_committed_search_names_esc_first
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/alp\t")
      assert sb.instance_variable_get(:@search).committed?
      said = notices { sb.send(:handle, "\e[200~x\e[201~") }
      assert_equal ["switchboard: paste ignored — clear the search (Esc), then press n to paste a task"], said
    end

    def test_the_notice_names_a_remapped_new_workspace_key
      File.write(Config.path, YAML.dump("sidebar_keys" => { "new_workspace" => "c" }))
      sb = three_rows
      assert_equal ["switchboard: paste ignored — press c first to paste a task"], notices { sb.send(:handle, "\e[200~x\e[201~") }
    end

    def test_a_paste_clears_a_pending_count
      sb = sidebar(nodes: [proj("app"), *(1..9).map { |i| ws("w#{i}") }])
      notices { sb.send(:handle, "3\e[200~x\e[201~j") }
      assert_equal 1, cursor_of(sb)
    end

    def test_a_partial_sequence_cut_off_by_a_paste_cannot_swallow_the_next_key
      sb = three_rows
      sb.send(:handle, "\e[1;5")
      notices { sb.send(:handle, "\e[200~zz\e[201~j") }
      assert_equal 2, cursor_of(sb)
    end

    def test_a_stray_end_marker_outside_a_paste_does_nothing
      sb = three_rows
      assert_empty notices { sb.send(:handle, "\e[201~") }
      assert_equal 1, cursor_of(sb)
    end

    # --- function keys (SS3) -------------------------------------------------

    def test_f3_no_longer_refreshes_prs
      sb = three_rows
      stub_method(sb, :refresh_prs_now, -> { flunk "F3 fired R" }) { sb.send(:handle, "\eOR") }
    end

    def test_alt_shift_o_in_a_short_read_never_swallows_the_next_key
      sb = three_rows
      opened = false
      sb.define_singleton_method(:open_repo) { opened = true }
      sb.send(:handle, "\eO")
      sb.send(:handle, "j")
      refute opened
      assert_equal 2, cursor_of(sb)
    end

    def test_full_reaches_only_the_key_string_that_ends_the_read
      sb = three_rows
      read = "\eO\e[200~".b
      read += "x" * (Sidebar::Input::READ_BYTES - read.bytesize)
      items = sb.send(:input_items, read)
      assert_equal "\eO", items.first
      assert_kind_of Sidebar::PasteFrame::Text, items.last
      assert_empty sb.instance_variable_get(:@pending)
    end

    # --- / search ------------------------------------------------------------

    def test_a_paste_into_a_typed_search_is_query_text_without_newlines
      sb = sidebar(nodes: [proj("app"), ws("alpha"), ws("beta")])
      sb.send(:handle, "/")
      said = notices { sb.send(:handle, "\e[200~al\nph\r\e[201~") }
      search = sb.instance_variable_get(:@search)
      assert search.typing?, "a pasted newline doesn't commit"
      assert_equal "alph", search.query
      assert_empty said
    end

    def test_a_large_search_paste_recomputes_the_rows_once
      sb = sidebar(nodes: [proj("app"), ws("alpha")])
      sb.send(:handle, "/")
      calls = 0
      real = sb.method(:recompute_rows)
      sb.define_singleton_method(:recompute_rows) { |*a, **k| calls += 1; real.call(*a, **k) }
      sb.send(:handle, "\e[200~#{'a' * 5000}\e[201~")
      assert_equal 1, calls
    end

    # --- one-key prompts -----------------------------------------------------

    def test_a_paste_closes_a_confirm_as_no_and_its_tail_in_the_tree_says_nothing_more
      sb = three_rows
      said = notices do
        stub_method(Workspaces, :quit_all, -> { flunk "quit on a pasted y" }) do
          with_reads(sb, "\e[200~yyy") { |left| assert sb.send(:handle, "q"); assert_empty left }
        end
        sb.send(:handle, "jj\e[201~")
      end
      assert_equal ["switchboard: paste ignored, so the prompt closed with no answer"], said
      assert_equal 1, cursor_of(sb), "nothing in the paste fired after the confirm closed"
    end

    def test_a_paste_into_the_add_menu_falls_through_to_reload
      sb = three_rows
      reloads = 0
      notices do
        stub_method(sb, :add_local, -> { flunk "the pasted l chose local" }) do
          stub_method(sb, :reload, ->(**) { reloads += 1 }) { with_reads(sb, "\e[200~l\e[201~") { sb.send(:add) } }
        end
      end
      assert_equal 1, reloads
    end

    def test_a_paste_dismisses_a_flash
      sb = three_rows
      notices { with_reads(sb, "\e[200~x\e[201~") { |left| assert_equal "", sb.send(:flash, "boom"); assert_empty left } }
    end

    def test_a_switch_drops_a_queued_paste_without_a_notice
      sb = three_rows
      sb.instance_variable_set(:@typeahead, [])
      said = notices { with_pipe("\e[200~nn\e[201~\f") { sb.send(:drop_queued_keys) } }
      assert_equal ["\f"], sb.instance_variable_get(:@typeahead)
      assert_empty said
    end

    # --- line prompts --------------------------------------------------------

    def test_a_name_prompt_takes_a_paste_as_ascii_text_and_never_submits_on_its_newline
      sb = three_rows
      result = nil
      with_reads(sb, "\e[200~caf\xC3\xA9 one\ntwo\e[201~".b, "\r") { |left| result = sb.send(:prompt_line, "name"); assert_empty left }
      assert_equal "caf one two", result
    end

    def test_prompt_grammar_splits_by_tokenize
      sb = three_rows
      assert_equal :edit, sb.send(:edit_buffer, "\e[", +"")
      assert_equal :submit, sb.send(:edit_buffer, "\r", +""), "a held \\e[ then ↵ still submits"

      buf = +"ab"
      sb.send(:edit_buffer, "\e[1;5D", buf)
      assert_equal "ab", buf, "Ctrl-← drops whole"
      sb.send(:edit_buffer, "\e[1;", buf)
      sb.send(:edit_buffer, "5Dc", buf)
      assert_equal "abc", buf, "a CSI split across reads drops whole"
      sb.send(:edit_buffer, "\eOP\eOAd", buf)
      assert_equal "abcd", buf, "F1 and an SS3 arrow drop whole"
      assert_equal :cancel, sb.send(:edit_buffer, "\e", buf), "a lone Esc still cancels"
    end

    def test_a_partial_sequence_cut_off_by_a_paste_keeps_the_next_key_in_a_name
      sb = three_rows
      buf = +"ab"
      sb.send(:edit_buffer, "\e[1;5", buf)
      sb.send(:edit_buffer, "\e[200~cd\e[201~x", buf)
      assert_equal "abcdx", buf
    end

    def test_a_long_task_paste_survives_its_end_marker_split_at_every_offset
      body = "x" * 1500
      whole = "\e[200~#{body}\e[201~".b
      (1..5).each do |k|
        cut = whole.bytesize - 6 + k
        reads = [whole.byteslice(0, 1024), whole.byteslice(1024, cut - 1024), whole.byteslice(cut..), "\r"]
        sb = three_rows
        result = nil
        stub_method(sb, :draw_prompt, ->(*, **) {}) do
          with_reads(sb, *reads) { result = sb.send(:prompt_line, "task", task: true) }
        end
        assert_equal body, result, "end marker split after #{k} bytes"
      end
    end

    def test_a_pasted_c1_control_never_reaches_the_drawn_task_line
      sb = three_rows
      draws = []
      result = nil
      stub_method(sb, :draw_prompt, ->(_l, text, **) { draws << text.dup }) do
        with_reads(sb, "\e[200~a\xC2\x9Bb\e[201~".b, "\r") { result = sb.send(:prompt_line, "task", task: true) }
      end
      assert_equal "ab", result
      draws.each { |d| refute_includes d.b, "\xC2\x9B".b }
    end

    def test_a_full_read_ending_in_ss3_lead_joins_its_final_byte_from_the_next_read
      sb = sidebar(nodes: [proj("app")])
      tasks = []
      read = "n" + ("a" * (Sidebar::Input::READ_BYTES - 3)) + "\eO"
      stub_method(Creator, :dispatch, ->(_c, _p, task) { tasks << task; :no_name }) do
        stub_method(sb, :flash, ->(*) {}) { with_reads(sb, "P", "\r") { sb.send(:handle, read) } }
      end
      assert_equal ["a" * (Sidebar::Input::READ_BYTES - 3)], tasks, "F1 stayed whole: no P in the task"
    end

    def test_typeahead_items_are_not_framed_twice
      sb = sidebar(nodes: [proj("app")])
      tasks = []
      stub_method(Creator, :dispatch, ->(_c, _p, task) { tasks << task; :no_name }) do
        stub_method(sb, :flash, ->(*) {}) { with_reads(sb, "\r") { sb.send(:handle, "n\e[200~one\e[201~") } }
      end
      assert_equal ["one"], tasks
      assert_equal 1, frame(sb).pastes
    end

    # --- drains --------------------------------------------------------------

    def test_drain_input_frames_what_it_discards_and_clears_pending
      sb = three_rows
      sb.instance_variable_set(:@pending, +"\e[1")
      full = ("j" * (Sidebar::Input::READ_BYTES - 1)) + "\e"
      with_pipe(full + "[200~yy\e[201~") { sb.send(:drain_input) }
      assert_equal 1, frame(sb).pastes, "a full read's trailing \\e joined the next read's [200~"
      assert frame(sb).idle?
      assert_empty sb.instance_variable_get(:@pending)
    end

    def test_a_paste_cut_by_the_task_prompts_drain_is_noticed_once_in_the_tree
      sb = three_rows
      said = notices do
        stub_method(Creator, :dispatch, ->(*) { :no_name }) do
          stub_method(sb, :flash, ->(*) {}) do
            with_pipe("\e[200~abc") { with_reads(sb, "fix\r") { sb.send(:handle, "n") } }
          end
        end
        sb.send(:handle, "kk")
        sb.send(:handle, "jj\e[201~")
      end
      assert_equal [TREE_NOTICE], said
      assert_equal 1, cursor_of(sb)
    end

    def test_the_delete_confirm_drain_frames_a_paste_in_flight_and_reads_it_as_no
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 1)
      sb.instance_variable_set(:@config, Config.new)
      sb.instance_variable_set(:@pending, +"\e[1")
      planned = [WorkspaceBranches::Entry.new(name: "feature", sha: "abc", merged: true)]
      notices do
        stub_method(WorkspaceBranches, :plan, ->(*) { planned }) do
          stub_method(Git, :clean?, ->(*) { flunk "the pasted y was an answer" }) do
            with_pipe("\e[200~yy") { with_reads(sb, "y\e[201~") { sb.send(:delete) } }
          end
        end
      end
      assert frame(sb).idle?
    end

    # --- recovery and the stall notice ----------------------------------------

    def test_handle_never_ends_a_paste
      sb = three_rows
      at(0) { notices { sb.send(:handle, "\e[200~x") } }
      at(100) { notices { sb.send(:handle, "jj") } }
      assert frame(sb).open?
      assert_equal 1, cursor_of(sb)
    end

    def test_the_wait_is_capped_at_quiet_while_the_frame_is_not_idle
      sb = three_rows
      assert_equal Sidebar::IDLE, sb.send(:frame_timeout)
      at(0) { notices { sb.send(:handle, "\e[200~x") } }
      assert_equal Sidebar::PasteFrame::QUIET, sb.send(:frame_timeout)
      frame(sb).expire(now: 5)
      assert_equal Sidebar::IDLE, sb.send(:frame_timeout)
    end

    def test_no_hot_reload_mid_paste_or_while_bytes_are_held
      sb = three_rows
      notices { sb.send(:handle, "\e[200~x") }
      refute sb.send(:reexec_allowed?), "mid-paste"

      sb = three_rows
      sb.send(:handle, ("k" * (Sidebar::Input::READ_BYTES - 1)) + "\e")
      refute sb.send(:reexec_allowed?), "a held lone \\e"
      assert sb.instance_variable_get(:@pending).empty?
    end

    def test_check_builds_a_frame
      File.write(Config.path, YAML.dump("projects" => []))
      built = 0
      real = Sidebar::PasteFrame.method(:new)
      stub_method(Sidebar::PasteFrame, :new, ->(*) { built += 1; real.call }) { assert Sidebar.check }
      assert_equal 1, built
    end

    def test_a_steady_stream_into_an_open_paste_says_once_that_it_stalled
      sb = three_rows
      said = notices do
        at(0) { sb.send(:handle, "\e[200~x") }
        (1..8).each { |i| at(i * 0.5) { sb.send(:handle, "\e") } }
      end
      assert_equal [TREE_NOTICE, STALL_NOTICE], said
      assert frame(sb).open?, "the Esc presses kept it open"
      refute frame(sb).expire(now: 8.9)
      assert frame(sb).expire(now: 9)
    end

    def test_a_paste_in_one_write_never_stalls
      sb = three_rows
      assert_equal [TREE_NOTICE], notices { at(0) { sb.send(:handle, "\e[200~#{'x' * 900}\e[201~") } }
    end

    def test_a_lost_end_marker_in_a_prompt_heals_after_silence
      [["\r", "fix it"], ["\e", nil]].each do |key, want|
        sb = three_rows
        events = [[0, "\e[200~fix it"], [1, "\e"], [2, "\r"], [nil, nil], [0.1, key]]
        result = nil
        said = notices do
          scripted_stdin(events) do
            stub_method(sb, :draw_prompt, ->(*, **) {}) do
              capture_stdout { result = sb.send(:prompt_line, "task", task: true) }
            end
          end
        end
        want ? assert_equal(want, result) : assert_nil(result, "Esc cancels again")
        assert_equal [STALL_NOTICE], said, "the line prompt says the paste is still open"
        assert_empty events, "every scripted event was read"
      end
    end

    private

    def three_rows = sidebar(nodes: [proj("app"), ws("a"), ws("b"), ws("c")], cursor: 1)
    def frame(sb) = sb.instance_variable_get(:@paste_frame)

    def notices
      said = []
      stub_method(Tmux, :notify, ->(msg) { said << msg }) { yield }
      said
    end

    def at(time, &block)
      stub_method(Sidebar::PasteFrame, :clock, -> { time }, &block)
    end

    def with_pipe(bytes)
      r, w = IO.pipe
      w.write(bytes.b)
      with_stdin(r) { yield }
    ensure
      r&.close
      w&.close
    end

    # Drives the real read_prompt_key: each event is [seconds later, bytes], and [nil, nil] is
    # a select that times out, the clock moving by its timeout.
    def scripted_stdin(events)
      r, w = IO.pipe
      now = 0.0
      select = lambda do |_r, _w = nil, _e = nil, timeout = nil|
        dt, bytes = events.shift || raise(IOError, "script ran out")
        if bytes.nil?
          now += timeout
          next nil
        end
        now += dt
        w.write(bytes.b)
        [[r]]
      end
      with_stdin(r) do
        stub_method(IO, :select, select) { stub_method(Sidebar::PasteFrame, :clock, -> { now }) { yield } }
      end
    ensure
      r&.close
      w&.close
    end
  end
end
