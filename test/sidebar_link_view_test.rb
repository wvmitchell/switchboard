# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # The `p` phone-link overlay: opening it, its keys, re-checking its link on every
  # scan, and the layout (header, session line, QR, URL, hint) with its fallbacks.
  # The QR's own encoding is pinned in qr_test.rb; @links is seeded directly here.
  class SidebarLinkViewTest < SidebarCase
    ID_A = "session_01AbCdEfGhJkMnPqRsTuVwXy" # a production-length id: a 55-byte URL, a v4 code
    ID_B = "session_01ZyXwVuTsRqPnMkJhGfEdCb"

    def link(id = ID_A, name: "fix the rename bug", started_at: 0, pid: 7)
      RemoteLink::Link.new(pid: pid, bridge_id: id, kind: "interactive", name: name,
                           started_at: started_at, stale: false)
    end

    def linked(links = [link], nodes: [ws("alpha", path: "/wt/a"), ws("beta", path: "/wt/b")])
      sb = sidebar(nodes: nodes)
      sb.instance_variable_set(:@links, { "/wt/a" => links })
      sb
    end

    def view(sb) = sb.instance_variable_get(:@link_view)

    def open(sb)
      sb.send(:dispatch, "p")
      sb
    end

    def lines(sb, rows: 40, cols: 40)
      body, hint = sb.send(:link_view_lines, rows, cols)
      [body.map { |l| strip_ansi(l) }, hint, body]
    end

    def qr_lines(raw) = raw.select { |l| l.include?("▀") }

    # --- opening ------------------------------------------------------------

    def test_p_on_a_linked_workspace_opens_the_newest_link
      sb = open(linked([link(ID_A), link(ID_B)]))
      assert_equal({ path: "/wt/a", bridge_id: ID_A, qr: {} }, view(sb).merge(qr: {}))
    end

    def test_p_on_an_unlinked_row_or_a_header_does_nothing
      sb = linked
      stub_method(sb, :flash, ->(*) { flunk "no flash on a row without a link" }) do
        sb.instance_variable_set(:@cursor, 1) # beta, no link
        sb.send(:dispatch, "p")
        assert_nil view(sb)
        tree = sidebar(nodes: [Tree::Node.new(kind: "proj", project: "app")])
        tree.instance_variable_set(:@links, { "/wt/a" => [link] })
        tree.send(:dispatch, "p")
        assert_nil view(tree)
      end
    end

    def test_p_on_a_branch_row_shows_its_workspaces_link
      branch = Tree::Node.new(kind: "br", project: "app", path: "/wt/a", branch: "feat", active: true)
      sb = linked(nodes: [branch])
      open(sb)
      assert_equal "/wt/a", view(sb)[:path]
    end

    # --- keys -----------------------------------------------------------------

    def test_tab_steps_through_several_links_and_the_header_counts
      sb = open(linked([link(ID_A, name: "first"), link(ID_B, name: "second")]))
      assert_match(%r{alpha\s+1/2\z}, lines(sb)[0][0])
      sb.send(:dispatch, "\t")
      assert_equal ID_B, view(sb)[:bridge_id]
      assert_match(%r{alpha\s+2/2\z}, lines(sb)[0][0])
      assert_equal "second", lines(sb)[0][1]
      sb.send(:dispatch, "\t")
      assert_equal ID_A, view(sb)[:bridge_id], "wraps around"
    end

    def test_one_link_has_no_count_and_tab_does_nothing
      sb = open(linked)
      assert_equal "app/alpha", lines(sb)[0][0].strip
      sb.send(:dispatch, "\t")
      assert_equal ID_A, view(sb)[:bridge_id]
      assert_equal "any key closes", lines(sb)[1]
    end

    def test_arrows_resize_and_keep_the_overlay_open
      sb = open(linked)
      sb.send(:dispatch, "\e[C")
      assert sb.instance_variable_get(:@resized), "→ still widens the pane"
      refute_nil view(sb)
    end

    def test_any_other_key_closes_without_firing_its_action
      sb = open(linked)
      stub_method(sb, :quit, ->(*) { flunk "q only closes the overlay" }) do
        assert sb.send(:dispatch, "q")
      end
      assert_nil view(sb)
    end

    def test_pokes_run_their_handlers_and_leave_the_overlay_open
      sb = open(linked)
      ran = []
      stub_method(sb, :reload_and_refresh, ->(*) { ran << :reload }) do
        stub_method(sb, :warm_poke, ->(*) { ran << :warm }) do
          sb.send(:dispatch, "\f")
          sb.send(:dispatch, Sidebar::WARM_POKE_BYTE)
          sb.send(:dispatch, "\e[O")
        end
      end
      assert_equal %i[reload warm], ran, "a switch-in poke still reloads (and so re-checks the link)"
      refute_nil view(sb)
    end

    # Value: protects=the #64 lone-pane fast reap still exits the loop while the p overlay is
    # open; fails_when=link_view_key calls poke but returns true (focus-in's false is dropped);
    # why_new=only focus-out was dispatched under the overlay; seam=none; no_claim=real pane death
    def test_a_lone_pane_focus_in_still_exits_the_loop_under_the_overlay
      sb = open(linked)
      stub_method(sb, :focus_in, ->(*) { true }) do
        refute sb.send(:dispatch, "\e[I"), "focus-in's exit signal passes through the overlay"
      end
    end

    # --- re-checking the link on every scan --------------------------------------

    def test_a_reordered_scan_keeps_the_same_session
      sb = open(linked([link(ID_A), link(ID_B)]))
      sb.send(:dispatch, "\t") # now on B
      sb.instance_variable_set(:@links, { "/wt/a" => [link(ID_B), link(ID_A)] })
      sb.send(:revalidate_link_view)
      assert_equal ID_B, view(sb)[:bridge_id]
    end

    def test_an_ended_link_falls_back_to_the_newest_remaining_one
      sb = open(linked([link(ID_A), link(ID_B)]))
      sb.instance_variable_set(:@links, { "/wt/a" => [link(ID_B)] })
      sb.send(:revalidate_link_view)
      assert_equal ID_B, view(sb)[:bridge_id]
    end

    def test_the_last_link_ending_closes_back_to_the_tree_without_a_flash
      sb = open(linked)
      sb.instance_variable_set(:@links, {})
      stub_method(sb, :flash, ->(*) { flunk "a scan never blocks on a keypress" }) do
        sb.send(:revalidate_link_view)
      end
      assert_nil view(sb)
    end

    # Value: protects=links refresh even when the agent-dot scan raises (eng D4); fails_when=the
    # @links hydrate moves back into refresh_agents' body (a failed scan keeps an ended link's QR
    # up); why_new=TODOS item (2) had no test; seam=none; no_claim=real session files (stubbed)
    def test_links_refresh_and_the_overlay_closes_even_when_the_dot_scan_raises
      sb = open(linked)
      as = Struct.new(:last_hook_states).new({})
      as.define_singleton_method(:scan) { |*, **| raise "hook dir vanished" }
      sb.instance_variable_set(:@agent_state, as)
      stub_method(RemoteLink, :scan, ->(*, **) { {} }) do
        refute sb.send(:refresh_agents, refresh_prs: false), "the dot scan still reports its failure"
      end
      assert_equal({}, sb.instance_variable_get(:@links))
      assert_nil view(sb)
    end

    # --- layout ---------------------------------------------------------------

    def test_layout_reads_header_session_code_url_at_the_default_width
      sb = open(linked)
      text, hint, raw = lines(sb)
      assert_equal "app/alpha", text[0].strip
      assert_equal "fix the rename bug", text[1]
      assert_equal "", text[2]
      qr = qr_lines(raw)
      assert_equal 21, qr.size, "33 modules + 4 above and below, two per row"
      assert(qr.all? { |l| strip_ansi(l).length == 39 }, "3-module margin each side at 40 cols")
      assert_equal ["https://claude.ai/code/session_01AbCdEfG", "hJkMnPqRsTuVwXy"], text.last(2)
      assert_equal "any key closes", hint
    end

    def test_the_code_uses_the_themes_black_and_bright_white
      raw = lines(open(linked))[2]
      assert(qr_lines(raw).all? { |l| l.include?("38;5;") && l =~ /38;5;(0|15);48;5;(0|15)m/ })
      refute(qr_lines(raw).any? { |l| l =~ /5;(16|231)m/ }, "not the fixed cube colors")
    end

    def test_a_wider_pane_centers_the_code_at_the_same_size
      raw = lines(open(linked), cols: 60)[2]
      row = strip_ansi(qr_lines(raw).first)
      assert_equal 9, row[/\A */].size, "41 cols wide (4-module margin) centered in 60"
      assert_equal 50, row.length
    end

    def test_the_vertical_margin_shrinks_before_the_code_gives_up
      sb = open(linked)
      assert_equal 21, qr_lines(lines(sb, rows: 28)[2]).size
      assert_equal 19, qr_lines(lines(sb, rows: 26)[2]).size, "2 modules above and below"
      text, hint = lines(sb, rows: 25)
      assert_includes text, "pane too short for the QR"
      assert_equal "pane too short · any key closes", hint
    end

    # Value: protects=a link QR can't encode degrades to the readable URL, never a raise in the
    # render loop; fails_when=the nil-matrix guard goes (nil.size) or BRIDGE_ID's bound widens
    # unguarded; why_new=no test hit the nil branch; seam=none; no_claim=what RemoteLink accepts
    def test_a_link_too_long_to_encode_shows_the_url_instead
      long = link("session_#{'x' * 100}")
      text, hint, raw = lines(open(linked([long])))
      assert_includes text, "no QR for this link"
      assert_empty qr_lines(raw)
      assert_equal long.url, text.last(4).join, "the whole URL, wrapped at the pane width"
      assert_equal "any key closes", hint
    end

    # Value: protects=with several links the 1/2 count stays visible and the header fits the pane;
    # fails_when=a long name pushes the count off or the header overflows cols; why_new=tab test
    # uses a short name only; seam=none; no_claim=wide-char names
    def test_a_long_name_gives_way_so_the_count_stays_in_the_header
      nodes = [ws("a-very-long-workspace-name-that-will-not-fit", path: "/wt/a")]
      sb = open(linked([link(ID_A), link(ID_B)], nodes: nodes))
      header = lines(sb)[0][0]
      assert_equal 40, header.length, "fills the pane exactly"
      assert header.start_with?("app/a-very"), header
      assert header.end_with?(" 1/2"), header
    end

    def test_too_narrow_shows_the_url_and_says_widen
      text, hint = lines(open(linked), cols: 30)
      assert_includes text, "too narrow for the QR"
      assert_equal "https://claude.ai/code/session", text[-2]
      assert_equal "→ widen · any key closes", hint
    end

    def test_session_label_falls_back_to_start_time_then_pid
      sb = sidebar
      started = Time.new(2026, 10, 24, 9, 5).to_i * 1000
      assert_equal "ab", sb.send(:session_label, link(name: "a​b"))
      assert_equal "started 09:05", sb.send(:session_label, link(name: "", started_at: started))
      assert_equal "pid 7", sb.send(:session_label, link(name: " ", started_at: 0)), "0 means unknown"
    end

    def test_the_code_is_built_once_while_the_overlay_is_open
      sb = open(linked)
      built = 0
      real = QR.method(:matrix)
      stub_method(QR, :matrix, ->(s, **kw) { built += 1; real.call(s, **kw) }) do
        2.times { sb.send(:link_view_lines, 40, 40) }
      end
      assert_equal 1, built
    end

    def test_the_overlay_does_not_animate
      sb = open(linked)
      sb.instance_variable_set(:@visible, true)
      sb.instance_variable_set(:@agents, { "/wt/a" => :thinking })
      refute sb.send(:pulsing?)
    end

    def test_the_help_legend_names_the_live_qr_key
      assert_includes strip_ansi(sidebar.send(:legend_lines, 80).join(" ")), "on phone · p shows a QR"
      File.write(Config.path, YAML.dump("sidebar_keys" => { "phone_link" => "x" }))
      assert_includes strip_ansi(sidebar.send(:legend_lines, 80).join(" ")), "on phone · x shows a QR"
      File.write(Config.path, YAML.dump("sidebar_keys" => { "rename" => "p" }))
      legend = strip_ansi(sidebar.send(:legend_lines, 80).join(" "))
      refute_includes legend, "shows a QR", "an unbound key gets no hint"
    end

    # Value: protects=every poke byte keeps doing its job under the p overlay; fails_when=a byte
    # is added to POKE_BYTES without an arm in poke (it would silently do nothing there);
    # why_new=maintainability review, ship of v0.54.0; seam=none; no_claim=what each handler does
    def test_every_poke_byte_has_a_handler
      handlers = %i[reload_and_refresh warm_poke reload_config_and_rebuild focus_in]
      Sidebar::POKE_BYTES.each do |byte|
        sb = sidebar
        sb.instance_variable_set(:@focused, true) # so focus-out must clear it
        ran = []
        handlers.each { |m| sb.define_singleton_method(m) { ran << m; false } }
        sb.send(:poke, byte)
        assert(ran.any? || byte == "\e[O" && sb.instance_variable_get(:@focused) == false,
               "poke has no arm for #{byte.inspect}")
      end
    end

    # Value: protects=the header still names the workspace when no ws row matches (a branch row
    # whose ws row is filtered away); fails_when=the fallback raises on a nil node or shows a
    # wrong label; why_new=the branch-row test checked only the path; seam=none; no_claim=none
    def test_the_header_falls_back_to_the_folder_name_without_a_ws_row
      branch = Tree::Node.new(kind: "br", project: "app", path: "/wt/a", branch: "feat", active: true)
      sb = open(linked(nodes: [branch]))
      assert_equal "a", lines(sb)[0][0].strip
    end

    # Value: protects=at the fit boundary (cols = n+4) the code still draws, with the 2-module
    # floor (eng D5); fails_when=the floor or the fit check moves by one; why_new=only 40 and 60
    # cols were asserted; seam=none; no_claim=how it looks (Will, sandbox)
    def test_the_margin_drops_to_two_at_the_fit_boundary
      raw = lines(open(linked), cols: 37)[2]
      assert(qr_lines(raw).all? { |l| strip_ansi(l).length == 37 }, "33 modules + 2 each side")
      assert_includes lines(open(linked), cols: 36)[0], "too narrow for the QR"
    end

    # Value: protects=switching back to a session re-checks its link at once (eng D9): the C-l poke
    # runs the reload, and a link that ended closes the overlay; fails_when=pokes are swallowed
    # under the overlay again or the reload stops reaching refresh_agents' ensure; why_new=the
    # poke test stubbed the reload; seam=none (stubs reload's heavy rebuild); no_claim=real tmux
    def test_a_switch_back_poke_closes_the_overlay_when_its_link_ended
      sb = open(linked)
      as = Struct.new(:last_hook_states).new({})
      as.define_singleton_method(:scan) { |*, **| {} }
      sb.instance_variable_set(:@agent_state, as)
      stub_method(Tmux, :visible?, ->(*) { true }) do
        stub_method(sb, :reload_due?, ->(*) { true }) do
          stub_method(sb, :reload, ->(**) { sb.send(:refresh_agents, refresh_prs: false) }) do
            stub_method(RemoteLink, :scan, ->(*, **) { {} }) { sb.send(:dispatch, "\f") }
          end
        end
      end
      assert_nil view(sb)
    end

    # Value: protects=closing the QR returns you to the row you pressed p on, even if focus moved
    # meanwhile (review D2); fails_when=focus_in jumps the cursor to the current workspace under
    # the overlay; why_new=red team, ship of v0.54.0; seam=none; no_claim=real focus events (smoke)
    def test_focus_in_under_the_overlay_keeps_the_p_row
      sb = linked
      sb.instance_variable_set(:@cursor, 1) # beta
      sb.instance_variable_set(:@links, { "/wt/b" => [link] })
      sb.instance_variable_set(:@current_path, "/wt/a")
      sb.instance_variable_set(:@visible, true)
      open(sb)
      stub_method(sb, :lone_pane_handled, ->(*) { false }) { sb.send(:dispatch, "\e[I") }
      refute_nil view(sb), "the overlay really opened on beta"
      sb.send(:dispatch, "x")
      assert_equal "/wt/b", sb.send(:current)&.path, "still on beta, where p was pressed"
    end

    # Value: protects=Tab that arrives before the next scan re-checks a vanished link still lands
    # on a live one; fails_when=cycle_link's fallback for a missing id goes (Tab then raises in the
    # input loop); why_new=testing review, ship of v0.54.0; seam=none; no_claim=none beyond protects
    def test_tab_after_the_shown_link_vanished_lands_on_the_first_live_one
      sb = open(linked([link(ID_A), link(ID_B)]))
      other = "session_01CcCcCcCcCcCcCcCcCcCcCcCc"
      sb.instance_variable_set(:@links, { "/wt/a" => [link(ID_B), link(other)] })
      sb.send(:dispatch, "\t")
      assert_equal ID_B, view(sb)[:bridge_id]
    end

    # Value: protects=a sidebar being torn down by a signal doesn't fork the link scan on its way
    # out; fails_when=the ensure runs remote_links while an Interrupt/SignalException propagates;
    # why_new=red team, ship of v0.54.0; seam=none; no_claim=real SIGTERM delivery
    def test_a_propagating_signal_skips_the_link_refresh
      sb = open(linked)
      as = Struct.new(:last_hook_states).new({})
      as.define_singleton_method(:scan) { |*, **| raise Interrupt }
      sb.instance_variable_set(:@agent_state, as)
      scans = 0
      stub_method(RemoteLink, :scan, ->(*, **) { scans += 1; {} }) do
        assert_raises(Interrupt) { sb.send(:refresh_agents, refresh_prs: false) }
      end
      assert_equal 0, scans, "no link scan during teardown"
    end

    # Value: protects=nothing the overlay or the ? legend draws runs past a 20-col pane (the
    # Width floor); fails_when=a fallback reason or the legend's QR hint skips trunc; why_new=red
    # team, ship of v0.54.0 (only 36+ cols were tested); seam=none; no_claim=how it reads
    def test_a_twenty_col_pane_never_overflows
      body, _hint = sidebar_with_links.send(:link_view_lines, 40, 20) # the hint row is trunc'd as it's drawn
      body.each { |l| assert_operator strip_ansi(l).length, :<=, 20, l.inspect }
      sidebar.send(:legend_lines, 20).each { |l| assert_operator strip_ansi(l).length, :<=, 20, l.inspect }
    end

    # Value: protects=a worktree name that isn't valid UTF-8 can't crash the overlay header;
    # fails_when=columns/fit_columns stop scrubbing (the width regex raises ArgumentError in the
    # unrescued render); why_new=red team, ship of v0.54.0; seam=none; no_claim=other byte encodings
    def test_a_non_utf8_worktree_name_still_draws_the_header
      bad = "caf\xE9".dup.force_encoding(Encoding::UTF_8)
      sb = open(linked(nodes: [ws(bad, path: "/wt/a")]))
      assert_includes lines(sb)[0][0], "app/caf"
    end

    # Value: protects=an input nobody foresaw, raising while the overlay builds its frame, closes
    # the QR and repaints the tree instead of killing the sidebar (the unrescued run loop); fails_when=
    # the backstop rescue goes or stops closing the overlay; why_new=three review passes each found a
    # new crash path here (Will, ship D4); seam=none (stubs one method to raise); no_claim=write errors
    def test_a_raise_while_building_the_overlay_closes_it_and_repaints_the_tree
      sb = open(linked)
      repainted = []
      stub_method(sb, :winsize, ->(*) { [40, 40] }) do
        stub_method(sb, :link_view_lines, ->(*) { raise ArgumentError, "unforeseen" }) do
          stub_method(sb, :render, ->(*) { repainted << :tree }) { sb.send(:render_link_view) }
        end
      end
      assert_nil view(sb), "the overlay closed"
      assert_equal [:tree], repainted
    end

    # Value: protects=p on an empty tree (no row under the cursor) is a no-op, not a crash in the
    # unrescued input loop; fails_when=open_link_view's nil-node guard goes (nil.kind raises);
    # why_new=only unlinked rows and headers were pressed; seam=none; no_claim=none beyond protects
    def test_p_on_an_empty_tree_does_nothing
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@links, { "/wt/a" => [link] })
      assert sb.send(:dispatch, "p")
      assert_nil view(sb)
    end

    # Value: protects=the drawn frame seats the hint on the pane's bottom row, truncated to the
    # pane width (the "→ widen" hint is 24 cols, wider than the 20-col floor); fails_when=the
    # frame stops trunc'ing the hint or addresses the wrong row; why_new=the 20-col test checked
    # only the body from link_view_lines, not the frame; seam=none (winsize stubbed); no_claim=tmux
    def test_the_frame_seats_a_truncated_hint_on_the_bottom_row
      sb = open(linked)
      frame = stub_method(sb, :winsize, ->(*) { [30, 20] }) { sb.send(:link_view_frame) }
      refute_nil view(sb), "the frame built without hitting the backstop"
      hint = frame[/\e\[30;1H\e\[K(.*)\z/m, 1]
      refute_nil hint, "the hint is addressed to row 30"
      assert_operator strip_ansi(hint).length, :<=, 20
      assert strip_ansi(hint).start_with?("→ widen"), strip_ansi(hint)
    end

    def sidebar_with_links = open(linked)
  end
end
