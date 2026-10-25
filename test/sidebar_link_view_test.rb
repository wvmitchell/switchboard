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
        sb.instance_variable_set(:@cursor, 2) # beta, no link
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
  end
end
