# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # The / search: Sidebar::Search's state and matching, the keys over the real dispatch, what
  # it reveals, the cursor rules, its lifetime, and how matches draw. White-box via SidebarCase.
  class SidebarSearchTest < SidebarCase
    # --- Sidebar::Search -------------------------------------------------------

    def test_spans_are_case_insensitive_literal_and_non_overlapping
      s = Sidebar::Search.new
      s.start(nil)
      "aa".each_char { |c| s.append(c) }
      assert_equal [[0, 2], [2, 2]], s.spans("aAaa"), "non-overlapping, in characters"
      s.clear
      ".*".each_char { |c| s.append(c) }
      assert_empty s.spans("anything"), "regexp characters are literal"
      assert_equal [[1, 2]], s.spans("a.*b")
    end

    def test_an_empty_query_matches_nothing
      s = Sidebar::Search.new
      s.start(nil)
      assert_empty s.spans("anything")
      refute s.match?("anything")
    end

    def test_spans_count_characters_in_names_that_are_not_ascii
      s = Sidebar::Search.new
      s.start(nil)
      s.append("x")
      assert_equal [[2, 1]], s.spans("名前x"), "a wide name counts characters, not bytes"
      assert_equal [[2, 1]], s.spans("éx"), "a combining mark is a character of its own"
    end

    def test_a_query_built_from_binary_key_bytes_matches_a_scrubbed_name
      was = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII # what LC_ALL=C gives a tmux pane
      sb = sidebar(nodes: [proj("app"), ws("bad\xFFname".dup.force_encoding(Encoding::BINARY)), ws("名前name")])
      assert sb.send(:handle, "/name\r".b)
      assert_equal [1, 2], hits(sb), "an invalid-bytes name is scrubbed before matching, never raises"
      assert_includes sb.send(:line, rows_of(sb).last, false, 30), "名前\e[0m#{Sidebar::Render::SEARCH_MATCH}name"
    ensure
      Encoding.default_external = was
    end

    # --- typing ----------------------------------------------------------------

    def test_a_search_hides_no_row
      sb = tree
      sb.send(:handle, "/auth")
      assert_equal 7, rows_of(sb).size
    end

    def test_typing_previews_the_next_match_from_a_fixed_origin
      sb = tree(cursor: 3) # beta
      sb.send(:handle, "/a")
      assert_equal "beta", current_node(sb).name, "beta itself contains an a: at or after the origin"
      sb.send(:handle, "u")
      assert_equal "oauth", current_node(sb).name, "the next auth after beta, measured from the origin"
      sb.send(:handle, "t")
      assert_equal "oauth", current_node(sb).name, "more characters don't drift through matches"
    end

    def test_shortening_the_query_previews_from_the_origin_again
      sb = tree(cursor: 3) # beta
      sb.send(:handle, "/au")
      assert_equal "oauth", current_node(sb).name
      sb.send(:dispatch, "\x7F")
      assert_equal "beta", current_node(sb).name, "back to the first match from where you started"
    end

    def test_a_preview_wraps_to_the_first_match
      sb = tree(cursor: 6) # oauth, the last row
      sb.send(:handle, "/auth-")
      assert_equal "auth-fix", current_node(sb).name
    end

    def test_esc_while_typing_returns_to_the_origin
      sb = tree(cursor: 3)
      sb.send(:handle, "/auth")
      sb.send(:dispatch, "\e")
      refute active?(sb)
      assert_equal "beta", current_node(sb).name
    end

    def test_backspace_empties_the_query_then_cancels
      sb = tree(cursor: 3)
      sb.send(:handle, "/a")
      sb.send(:dispatch, "\x7F")
      assert search(sb).typing?, "emptying the query stays in typing"
      assert_equal "beta", current_node(sb).name, "...with the cursor at the origin"
      assert_includes sb.send(:footer).first, "/ · esc"
      sb.send(:dispatch, "\x7F")
      refute active?(sb), "the next backspace cancels"
    end

    def test_enter_with_nothing_typed_does_nothing
      sb = tree(cursor: 3, collapsed: ["api"])
      rows = rows_of(sb).size
      sb.send(:handle, "/\r")
      refute active?(sb)
      assert_equal "beta", current_node(sb).name
      assert_equal rows, rows_of(sb).size, "no reveal"
      assert_creates(sb)
    end

    def test_enter_with_no_match_returns_to_the_origin_and_gives_n_back
      sb = tree(cursor: 3)
      sb.send(:handle, "/zzz\r")
      refute active?(sb)
      assert_equal "beta", current_node(sb).name
      assert_creates(sb)
    end

    def test_every_printable_key_is_query_text_while_typing
      sb = tree
      stub_method(sb, :quit, -> { flunk "q must not quit" }) do
        stub_method(sb, :remove, -> { flunk "d must not delete" }) { assert sb.send(:handle, "/jkqdn?3") }
      end
      assert_equal "jkqdn?3", search(sb).query
      refute sb.instance_variable_get(:@help)
      assert_nil sb.instance_variable_get(:@count)
    end

    def test_a_space_is_query_text
      sb = tree
      sb.send(:handle, "/a b")
      assert_equal "a b", search(sb).query
    end

    def test_movement_and_control_bytes_do_nothing_while_typing
      sb = tree(cursor: 3)
      sb.send(:handle, "/")
      (["\e[A", "\e[B", "\e[C", "\e[D", "\x0E", "\x10", "\x01", "\xE2".b] + Sidebar::Input::POKE_BYTES).each do |key|
        sb.send(:dispatch, key)
        assert_equal "", search(sb).query, "#{key.inspect} isn't query text"
        assert_equal 3, cursor_of(sb), "#{key.inspect} doesn't move"
      end
    end

    def test_the_empty_tree_can_search
      sb = sidebar(nodes: [])
      assert sb.send(:handle, "/x\e[A\r")
      refute active?(sb)
      sb.send(:handle, "/x")
      sb.send(:dispatch, "\e")
      refute active?(sb), "no origin to return to is fine"
    end

    # --- committed -------------------------------------------------------------

    def test_the_normal_keys_work_with_the_matches_on
      sb = committed(tree, "auth")
      at = cursor_of(sb)
      sb.send(:dispatch, "j")
      assert_equal at + 1, cursor_of(sb), "j moves one row"
      sb.send(:dispatch, "k")
      assert_equal at, cursor_of(sb), "k moves back"
      assert search(sb).committed?, "and the search stays on"
    end

    def test_n_and_big_n_step_and_wrap
      sb = committed(tree, "auth")
      assert_equal "auth-fix", current_node(sb).name
      sb.send(:dispatch, "n")
      assert_equal "oauth", current_node(sb).name
      sb.send(:dispatch, "n")
      assert_equal "auth-fix", current_node(sb).name, "n wraps"
      sb.send(:dispatch, "N")
      assert_equal "oauth", current_node(sb).name, "N wraps"
    end

    def test_n_steps_from_wherever_the_cursor_moved_to
      sb = committed(tree, "auth")
      sb.send(:dispatch, "G")
      sb.send(:dispatch, "g")
      sb.send(:dispatch, "n")
      assert_equal "auth-fix", current_node(sb).name
    end

    def test_n_takes_a_count
      sb = committed(tree, "a") # app, alpha, auth-fix, beta, api, gamma, oauth
      sb.send(:handle, "3n")
      assert_equal 3, hits(sb).index(cursor_of(sb)), "three matches on"
      sb.send(:handle, "2N")
      assert_equal 1, hits(sb).index(cursor_of(sb)), "two matches back"
    end

    def test_headers_and_branch_rows_are_stops
      nodes = [proj("search-app"), expanded_ws("feature"), br("search-branch", active: true), ws("other")]
      sb = committed(sidebar(nodes: nodes), "search")
      assert_equal "proj", current_node(sb).kind
      sb.send(:dispatch, "n")
      assert_equal "search-branch", current_node(sb).branch
    end

    def test_with_no_search_n_creates_and_big_n_is_unbound
      sb = tree
      assert_creates(sb)
      stub_method(sb, :create, -> { flunk "N isn't new workspace" }) { sb.send(:dispatch, "N") }
    end

    def test_esc_keeps_the_cursor_and_gives_n_back
      sb = committed(tree, "oauth")
      sb.send(:dispatch, "\e")
      refute active?(sb)
      assert_equal "oauth", current_node(sb).name
      assert_creates(sb)
    end

    def test_slash_starts_a_new_search_from_the_current_row
      sb = committed(tree, "oauth")
      sb.send(:dispatch, "/")
      assert search(sb).typing?
      assert_equal "", search(sb).query
      sb.send(:handle, "zzz\r")
      assert_equal "oauth", current_node(sb).name, "the origin is where the new search started"
    end

    def test_a_new_search_keeps_a_revealed_origin_row_on_screen
      sb = committed(tree(collapsed: ["api"]), "oauth")
      sb.send(:dispatch, "/")
      assert_equal 7, rows_of(sb).size, "the old reveal ends, and the origin row stays"
      assert_equal "oauth", current_node(sb).name
      sb.send(:handle, "zzz\e")
      assert_equal "oauth", current_node(sb).name, "and Esc can come back to it"
    end

    def test_the_new_search_key_is_the_bound_one_and_n_shadows_it
      sb = committed(sidebar_with_keys(filter: "s"), "x")
      sb.send(:dispatch, "s")
      assert search(sb).typing?, "a remapped filter key starts the new search"

      sb = sidebar_with_keys(filter: "n")
      sb.send(:handle, "n")
      assert search(sb).typing?, "idle, n starts a search when bound that way"
      sb.send(:handle, "x\r") # one match: `x`
      sb.send(:dispatch, "n")
      assert search(sb).committed?, "committed, n steps instead"
    end

    # --- ↵ during a committed search -------------------------------------------

    def test_enter_opens_the_highlighted_row_even_when_ending_the_search_moves_the_rows
      sb = committed(tree(collapsed: ["api"]), "oauth")
      opened = nil
      stub_method(sb, :switch, ->(node) { opened = node.name }) { sb.send(:dispatch, "\r") }
      assert_equal "oauth", opened
      refute active?(sb)
    end

    def test_enter_opens_a_branch_row
      nodes = [proj("app"), expanded_ws("feature"), br("wip-branch", active: true), ws("other")]
      sb = committed(sidebar(nodes: nodes), "wip")
      opened = nil
      stub_method(sb, :switch, ->(node) { opened = node.branch }) { sb.send(:dispatch, "\r") }
      assert_equal "wip-branch", opened
    end

    def test_enter_on_a_row_you_cannot_switch_into_keeps_the_search
      sb = committed(tree, "auth")
      called = false
      stub_method(sb, :dispatch_pending?, ->(_) { true }) do
        stub_method(sb, :enter_dispatch, ->(_) { called = true }) { sb.send(:dispatch, "\r") }
      end
      assert called
      assert search(sb).committed?
    end

    def test_enter_on_any_header_only_ends_the_search
      [[], ["app"]].each do |collapsed|
        sb = committed(tree(collapsed: collapsed), "app")
        assert_equal "proj", current_node(sb).kind
        stub_method(Collapse, :collapse, ->(*) { flunk "no fold write" }) do
          stub_method(Collapse, :expand, ->(*) { flunk "no fold write" }) { sb.send(:dispatch, "\r") }
        end
        refute active?(sb)
        assert_equal "proj", current_node(sb).kind
      end
    end

    def test_a_further_enter_on_the_header_folds_as_usual
      sb = committed(tree, "app")
      sb.send(:dispatch, "\r")
      stub_method(Tmux, :broadcast_warm, ->(**) {}) { sb.send(:dispatch, "\r") }
      assert_includes Collapse.collapsed, "app"
    end

    # --- what a search reveals -------------------------------------------------

    def test_a_child_match_reveals_its_folded_project_and_esc_from_typing_refolds_it
      sb = tree(collapsed: ["api"])
      assert_equal 5, rows_of(sb).size
      sb.send(:handle, "/oauth")
      assert_equal 7, rows_of(sb).size
      assert_equal "oauth", current_node(sb).name
      header = rows_of(sb).find { |n| n.project == "api" }
      assert_equal "▾ api", sb.send(:plain, header), "reads expanded, with no count"
      assert_nil header.folded
      sb.send(:dispatch, "\e")
      assert_equal 5, rows_of(sb).size
    end

    def test_a_header_matching_only_by_its_own_name_reveals_nothing
      sb = committed(tree(collapsed: ["api"]), "api")
      assert_equal 5, rows_of(sb).size
      assert_equal "api", current_node(sb).project
    end

    def test_text_that_is_not_on_screen_does_not_match
      nodes = [proj("app"), Tree::Node.new(kind: "ws", project: "app", path: "/wt/a", name: "plain", branch: "hidden")]
      sb = sidebar(nodes: nodes)
      sb.send(:handle, "/hidden")
      assert_empty hits(sb), "a workspace's unshown branch isn't a match"
      sb.send(:dispatch, "\e")
      sb.send(:handle, "/app")
      assert_equal [0], hits(sb), "and its project's name doesn't match its rows"
    end

    def test_rows_being_deleted_and_folded_branches_do_not_match
      nodes = [proj("app"), expanded_ws("feature", path: "/wt/f"), br("wip", active: true).tap { _1[:path] = "/wt/f" }, ws("gone", path: "/wt/g")]
      sb = sidebar(nodes: nodes, collapsed: ["app"])
      sb.instance_variable_set(:@pending_delete, Set.new(["/wt/g"]))
      sb.send(:handle, "/gone")
      assert_empty hits(sb)
      assert_equal 1, rows_of(sb).size, "a row being deleted reveals nothing"
      sb.send(:dispatch, "\e")

      sb.instance_variable_set(:@fold_branches, true)
      sb.send(:handle, "/wip")
      assert_empty hits(sb)
      assert_equal 1, rows_of(sb).size, "a folded branch row reveals nothing"
    end

    # --- zero matches: only a key gives n back ---------------------------------

    def test_a_search_stays_on_when_its_last_match_goes_and_n_then_enter_creates_nothing
      sb = committed(tree, "oauth")
      sb.instance_variable_set(:@nodes, sb.instance_variable_get(:@nodes).reject { _1.name == "oauth" })
      sb.send(:recompute_rows)
      assert search(sb).committed?
      assert_empty hits(sb)
      assert_equal "api", current_node(sb).project
      assert_equal "proj", current_node(sb).kind, "the vanished row's header"
      assert_includes sb.send(:footer).first, "no matches · esc"
      stub_method(sb, :create, -> { flunk "n then ↵ must not create" }) do
        stub_method(Tmux, :broadcast_warm, ->(**) {}) { sb.send(:handle, "n\r") }
      end
    end

    def test_folding_branches_away_and_back_keeps_the_search
      nodes = [proj("app"), expanded_ws("feature", path: "/wt/f"), br("wip", active: true).tap { _1[:path] = "/wt/f" }, ws("other")]
      sb = committed(sidebar(nodes: nodes), "wip")
      stub_method(Tmux, :broadcast_warm, ->(**) {}) do
        sb.send(:dispatch, "z")
        assert_empty hits(sb)
        assert search(sb).committed?
        sb.send(:dispatch, "z")
      end
      assert_equal 1, hits(sb).size, "the match came back and the search is still on"
    end

    # --- the cursor ------------------------------------------------------------

    def test_the_cursor_keeps_its_row_when_rows_land_above_it
      sb = committed(tree, "oauth")
      sb.instance_variable_set(:@nodes, [proj("new"), ws("first", project: "new")] + sb.instance_variable_get(:@nodes))
      sb.send(:recompute_rows)
      assert_equal "oauth", current_node(sb).name
    end

    def test_a_vanished_origin_falls_back_to_its_header_then_the_current_workspace
      sb = tree(cursor: 6, current_path: "/wt/alpha") # oauth
      sb.send(:handle, "/x")
      sb.instance_variable_set(:@nodes, sb.instance_variable_get(:@nodes).reject { _1.name == "oauth" })
      sb.send(:recompute_rows)
      sb.send(:dispatch, "\e")
      assert_equal %w[proj api], [current_node(sb).kind, current_node(sb).project]

      sb = tree(cursor: 6, current_path: "/wt/alpha")
      sb.send(:handle, "/x")
      sb.instance_variable_set(:@nodes, sb.instance_variable_get(:@nodes).reject { _1.project == "api" })
      sb.send(:recompute_rows)
      sb.send(:dispatch, "\e")
      assert_equal "alpha", current_node(sb).name
    end

    def test_going_back_to_the_sidebar_keeps_a_committed_searchs_row
      sb = committed(tree(current_path: "/wt/alpha"), "oauth")
      sb.instance_variable_set(:@visible, true)
      stub_method(sb, :lone_pane_handled, -> { false }) { sb.send(:dispatch, "\e[I") }
      assert_equal "oauth", current_node(sb).name
    end

    # --- the sticky project ----------------------------------------------------

    def test_esc_keeps_the_cursors_folded_project_open
      sb = committed(tree(collapsed: ["api"]), "oauth")
      sb.send(:dispatch, "\e")
      assert_equal "api", search(sb).sticky
      assert_equal "oauth", current_node(sb).name
      assert_equal 7, rows_of(sb).size
      sb.send(:dispatch, "k")
      assert_equal "api", search(sb).sticky, "moving away doesn't end it"
    end

    def test_only_the_cursors_folded_project_stays_open
      sb = tree(collapsed: %w[api])
      sb.send(:handle, "/oauth\r\e")
      assert_equal "api", search(sb).sticky
      sb.send(:handle, "g") # to the top, in the unfolded project
      sb.send(:handle, "/alpha\r\e")
      assert_nil search(sb).sticky, "the next clear elsewhere folds it again"
      assert_equal 5, rows_of(sb).size
    end

    def test_esc_on_a_header_leaves_nothing_open
      sb = committed(tree(collapsed: ["api"]), "api")
      sb.send(:dispatch, "\e")
      assert_nil search(sb).sticky
    end

    def test_enter_on_the_sticky_header_folds_here_with_no_disk_write
      sb = committed(tree(collapsed: ["api"]), "oauth")
      sb.send(:dispatch, "\e")
      sb.send(:dispatch, "k")
      sb.send(:dispatch, "k")
      assert_equal "proj", current_node(sb).kind
      stub_method(Collapse, :expand, ->(*) { flunk "no shared write" }) do
        stub_method(Collapse, :collapse, ->(*) { flunk "no shared write" }) { sb.send(:dispatch, "\r") }
      end
      assert_nil search(sb).sticky
      assert_equal 5, rows_of(sb).size
      assert_equal "proj", current_node(sb).kind
    end

    def test_another_window_unfolding_the_sticky_project_drops_it
      sb = sidebar_with_config({ "projects" => [{ "name" => "app", "path" => path("no-repo") }] })
      Collapse.collapse("app")
      search(sb).sticky = "app"
      sb.send(:rebuild)
      assert_equal "app", search(sb).sticky, "still folded on disk: it stays"

      Collapse.expand("app")
      sb.send(:rebuild)
      assert_nil search(sb).sticky, "another window unfolded it: not ours to hold"
    end

    def test_a_sticky_project_that_is_no_longer_configured_goes
      sb = sidebar_with_config({ "projects" => [{ "name" => "app", "path" => path("no-repo") }] })
      search(sb).sticky = "gone"
      sb.send(:rebuild)
      assert_nil search(sb).sticky
    end

    # --- lifetime --------------------------------------------------------------

    def test_a_search_never_writes_the_shared_folds
      sb = tree(collapsed: ["api"])
      before = Collapse.collapsed
      stub_method(Collapse, :collapse, ->(*) { flunk "no shared write" }) do
        stub_method(Collapse, :expand, ->(*) { flunk "no shared write" }) do
          sb.send(:handle, "/oauth\rnN\e")
          sb.send(:handle, "/oauth")
          sb.send(:dispatch, "\e")
        end
      end
      assert_equal before, Collapse.collapsed
    end

    def test_each_hidden_visibility_sample_ends_the_search_and_repaints
      samples = {
        recheck_visibility: ->(sb) { sb.send(:recheck_visibility) },
        reload_and_refresh: ->(sb) { sb.send(:reload_and_refresh) },
        tick: ->(sb) { stub_method(Tmux, :window_panes, ->(*) { 2 }) { sb.send(:tick) } }
      }
      samples.each do |name, sample|
        sb = committed(tree(collapsed: ["api"]), "oauth")
        sb.instance_variable_set(:@visible, true)
        renders = 0
        stub_method(sb, :owns_pane?, -> { true }) do
          stub_method(sb, :locate, -> {}) do
            stub_method(sb, :warm_reload, ->(*) { false }) do
              stub_method(sb, :render, -> { renders += 1 }) do
                hidden_pane { sample.call(sb) }
              end
            end
          end
        end
        refute active?(sb), "#{name} ended it"
        assert_nil search(sb).sticky, "#{name} left nothing open"
        assert_equal 1, renders, "#{name} repainted the hidden pane once"
        assert_equal 5, rows_of(sb).size, "#{name} re-folded"
        assert_equal %w[proj api], [current_node(sb).kind, current_node(sb).project], "#{name} kept to the row's project"
      end
    end

    # Value: protects=a failed tmux query never ends a search under your hands; fails_when=end_search_if_hidden trusts the sample alone; why_new=a misread would hand n back; seam=none; no_claim=tmux failure rates
    def test_a_failed_visibility_read_keeps_the_search_on
      sb = committed(tree(collapsed: ["api"]), "oauth")
      stub_method(sb, :render, -> { flunk "nothing changed" }) do
        stub_method(Tmux, :visible?, ->(*) { false }) do
          stub_method(Tmux, :hidden?, ->(*) { false }) { sb.send(:recheck_visibility) }
        end
      end
      assert search(sb).committed?
      assert_equal "oauth", current_node(sb).name
    end

    def test_a_hidden_sidebar_with_no_search_does_not_repaint
      sb = tree
      sb.instance_variable_set(:@visible, true)
      hidden_pane { stub_method(sb, :render, -> { flunk "dormant panes don't paint" }) { sb.send(:recheck_visibility) } }
    end

    def test_a_typing_search_ended_off_screen_goes_back_to_its_origin
      sb = tree(cursor: 3)
      sb.send(:handle, "/oauth")
      sb.instance_variable_set(:@visible, true)
      hidden_pane { stub_method(sb, :render, -> {}) { sb.send(:recheck_visibility) } }
      assert_equal "beta", current_node(sb).name
    end

    def test_the_frame_left_behind_matches_one_that_never_searched
      [true, false].each do |prewarm|
        File.write(Config.path, YAML.dump({ "prewarm" => prewarm }))
        sb = committed(tree(collapsed: ["api"]), "oauth")
        sb.send(:handle, "g") # back at the top, where a fresh frame's cursor sits
        fresh = tree(collapsed: ["api"])
        [sb, fresh].each do |s|
          s.instance_variable_set(:@visible, true)
          s.instance_variable_set(:@config, Config.new)
        end
        frame = lambda do |s, &act|
          stub_method(s, :winsize, -> { [24, 40] }) do
            hidden_pane { capture_stdout { act.call } }
          end
        end
        left = frame.call(sb) { sb.send(:recheck_visibility) }
        clean = frame.call(fresh) { fresh.send(:render) }
        assert_equal clean, left, "prewarm=#{prewarm}"
      end
    end

    def test_only_typing_holds_a_hot_reload
      sb = tree
      assert sb.send(:reexec_allowed?)
      sb.send(:handle, "/a")
      refute sb.send(:reexec_allowed?), "typing holds it"
      sb.send(:dispatch, "\r")
      assert sb.send(:reexec_allowed?), "a committed search doesn't: it could stay up for hours"
    end

    # --- the footer ------------------------------------------------------------

    def test_the_footer_is_one_line_in_every_state
      sb = tree
      sb.send(:handle, "/")
      assert_equal ["/ · esc"], sb.send(:footer)
      sb.send(:handle, "auth")
      assert_equal ["/auth [1/2] · ↵ · esc"], sb.send(:footer)
      sb.send(:handle, "\r")
      assert_equal ["/auth [1/2] · n/N · esc"], sb.send(:footer)
      sb.send(:dispatch, "n")
      assert_equal ["/auth [2/2] · n/N · esc"], sb.send(:footer)
      sb.send(:dispatch, "k")
      assert_equal ["/auth [-/2] · n/N · esc"], sb.send(:footer), "the cursor is off every match"
      sb.send(:dispatch, "3")
      assert_equal ["/auth [-/2] · 3…"], sb.send(:footer), "a pending count, like the normal footer"
      sb.send(:dispatch, "\e")

      sb.send(:handle, "/zzz")
      assert_equal ["/zzz · no matches"], sb.send(:footer)
    end

    def test_a_narrow_pane_shortens_the_query_and_keeps_the_count
      sb = committed(tree, "auth")
      stub_method(sb, :winsize, -> { [24, 22] }) do
        line = sb.send(:footer).first
        assert_includes line, "[1/2] · n/N · esc"
        assert_operator line.length, :<=, 22
        assert line.start_with?("/a"), "...and whatever of the query fits"
      end
    end

    # --- the other spellings of a key, and the rarer paths ---------------------

    # Value: protects=^H erases the query as DEL does; fails_when=\b is dropped from search_key; why_new=every backspace test sent DEL; seam=none; no_claim=which terminals send ^H
    def test_ctrl_h_erases_while_typing
      sb = tree
      sb.send(:handle, "/ab\b")
      assert_equal "a", search(sb).query
    end

    # Value: protects=LF commits a search as CR does; fails_when=\n is dropped from the commit branch; why_new=every commit test sent CR; seam=none; no_claim=which byte tmux sends for Enter
    def test_line_feed_commits_while_typing
      sb = tree
      sb.send(:handle, "/auth\n")
      assert search(sb).committed?
    end

    # Value: protects=LF opens the row from a committed search; fails_when=\n leaves SEARCH_KEYS; why_new=open tests sent only CR; seam=none; no_claim=switch mechanics
    def test_line_feed_opens_from_a_committed_search
      sb = committed(tree, "oauth")
      opened = nil
      stub_method(sb, :switch, ->(node) { opened = node.name }) { sb.send(:dispatch, "\n") }
      assert_equal "oauth", opened
      refute active?(sb)
    end

    # Value: protects=↵ with no rows ends the search without raising; fails_when=a nil guard goes from open_from_search; why_new=the empty-tree test never commits; seam=none; no_claim=how the tree emptied
    def test_enter_with_every_row_gone_ends_the_search
      sb = committed(tree, "oauth")
      sb.instance_variable_set(:@nodes, [])
      sb.send(:recompute_rows)
      assert sb.send(:dispatch, "\r")
      refute active?(sb)
    end

    # Value: protects=a project left open by Esc folds again off screen, with one repaint; fails_when=the sticky check goes from end_search_if_hidden; why_new=hidden tests started from a live search; seam=none; no_claim=which sampler fires
    def test_a_hidden_pane_refolds_a_sticky_project
      sb = committed(tree(collapsed: ["api"]), "oauth")
      sb.send(:dispatch, "\e")
      assert_equal "api", search(sb).sticky
      sb.instance_variable_set(:@visible, true)
      renders = 0
      stub_method(sb, :render, -> { renders += 1 }) do
        hidden_pane { sb.send(:recheck_visibility) }
      end
      assert_nil search(sb).sticky
      assert_equal 5, rows_of(sb).size
      assert_equal 1, renders
    end

    # Value: protects=count_indicator: false applies to the search footer; fails_when=the setting check goes from search_footer_tail; why_new=the footer test used the default; seam=none; no_claim=the normal footer
    def test_count_indicator_off_hides_the_count_in_a_committed_footer
      File.write(Config.path, YAML.dump({ "count_indicator" => false }))
      sb = committed(tree, "auth")
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:dispatch, "3")
      assert_equal ["/auth [1/2] · n/N · esc"], sb.send(:footer)
    end

    # Value: protects=the highlight survives when a note has no room to draw; fails_when=line_without_note passes no spans; why_new=the width test strips ANSI; seam=none; no_claim=note truncation
    def test_a_cursor_bar_with_no_room_for_its_note_keeps_its_highlight
      sb = sidebar(nodes: [proj("app"), ws("auth-row")])
      node = rows_of(sb).last
      stub_method(sb, :row_note, ->(_) { "a task" }) do
        sb.send(:handle, "/auth\r")
        assert_includes sb.send(:line, node, true, 14), Sidebar::Render::SEARCH_MATCH
      end
    end

    # --- drawing matches -------------------------------------------------------

    def test_marking_never_changes_a_rows_visible_text_on_any_draw_path
      nodes = [proj("auth-proj"), ws("oauth-x", pr: open_pr("#7")), ws("auth-plain"), br("wip/auth", active: true)]
      nodes.each do |node|
        [true, false].each do |focused|
          [60, 14].each do |cols|
            sb = sidebar(nodes: nodes, focused: focused)
            cursor_row = strip_ansi(sb.send(:line, node, true, cols))
            other_row = strip_ansi(sb.send(:line, node, false, cols))
            sb.send(:handle, "/auth\r")
            assert_equal cursor_row, strip_ansi(sb.send(:line, node, true, cols)), "#{node.kind} focused=#{focused} cols=#{cols}"
            assert_equal other_row, strip_ansi(sb.send(:line, node, false, cols)), "#{node.kind} off the cursor, cols=#{cols}"
          end
        end
      end
    end

    def test_the_note_path_marks_the_name_and_not_the_note
      sb = sidebar(nodes: [proj("app"), ws("auth-row")])
      rec = { "state" => "ready", "task" => "auth task" }
      sb.instance_variable_set(:@creation_for, { "/wt/auth-row" => rec })
      node = rows_of(sb).last
      stub_method(sb, :row_note, ->(_) { "auth task" }) do
        sb.send(:handle, "/auth\r")
        bar = sb.send(:line, node, true, 40)
        assert_equal 1, bar.scan(Sidebar::Render::SEARCH_MATCH).size, "the name, not the note"
        assert_equal strip_ansi(bar).length, 40
        off = sb.send(:line, node, false, 40)
        assert_equal 1, off.scan(Sidebar::Render::SEARCH_MATCH).size
      end
    end

    def test_a_match_inside_the_cursor_bar_shows_and_the_bar_resumes
      sb = sidebar(nodes: [proj("app"), ws("xauthy")])
      sb.send(:handle, "/auth\r")
      assert_includes sb.send(:line, rows_of(sb).last, true, 40), "\e[0m#{Sidebar::Render::SEARCH_MATCH}auth\e[0m\e[7my"
    end

    def test_a_match_restores_the_rows_own_style
      style = Sidebar::Render::SEARCH_MATCH
      sb = sidebar(nodes: [proj("xauthy"), ws("xauthy"), br("xauthy", active: true)], attention: ["/wt/xauthy"])
      sb.send(:handle, "/auth\r")
      header, row, branch = rows_of(sb)
      assert_includes sb.send(:line, header, false, 40), "#{style}auth\e[0m\e[1my"
      assert_includes sb.send(:line, row, false, 40), "#{style}auth\e[0m\e[1;33my", "unviewed stays bold yellow"
      assert_includes sb.send(:line, branch, false, 40), "#{style}auth\e[0m#{Sidebar::BRANCH_FG}y"
      sb.instance_variable_set(:@current_path, "/wt/xauthy")
      assert_includes sb.send(:line, row, false, 40), "#{style}auth\e[0m\e[36my", "the current row stays cyan"
    end

    def test_a_query_never_marks_a_cue_or_a_glyph
      node = ws("plain3")
      node[:folded] = 3
      sb = sidebar(nodes: [proj("app"), node])
      sb.send(:handle, "/3\r")
      row = rows_of(sb).last
      assert_includes sb.send(:plain, row), "▸3"
      [true, false].each do |active|
        assert_equal 1, sb.send(:line, row, active, 40).scan(Sidebar::Render::SEARCH_MATCH).size, "the name 3, not the ▸3"
      end
    end

    def test_a_truncated_match_is_a_stop_with_no_highlight
      sb = sidebar(nodes: [proj("app"), ws("#{'x' * 40}auth")])
      sb.send(:handle, "/auth\r")
      assert_equal [1], hits(sb)
      refute_includes sb.send(:line, rows_of(sb).last, true, 20), Sidebar::Render::SEARCH_MATCH
    end

    def test_a_wide_name_marks_the_right_characters_and_keeps_its_width
      sb = sidebar(nodes: [proj("app"), ws("名前auth")])
      plain = strip_ansi(sb.send(:line, rows_of(sb).last, true, 30))
      sb.send(:handle, "/auth\r")
      bar = sb.send(:line, rows_of(sb).last, true, 30)
      assert_equal plain, strip_ansi(bar)
      assert_includes bar, "名前\e[0m#{Sidebar::Render::SEARCH_MATCH}auth"
    end

    private

    def search(sb) = sb.instance_variable_get(:@search)
    def hidden_pane(&block)
      stub_method(Tmux, :visible?, ->(*) { false }) { stub_method(Tmux, :hidden?, ->(*) { true }, &block) }
    end

    def active?(sb) = search(sb).active?
    def hits(sb) = sb.instance_variable_get(:@search_hits)

    def tree(cursor: 0, collapsed: [], current_path: nil)
      sidebar(nodes: [proj("app"), ws("alpha"), ws("auth-fix"), ws("beta"),
                      proj("api"), ws("gamma", project: "api"), ws("oauth", project: "api")],
              cursor: cursor, collapsed: collapsed, current_path: current_path)
    end

    def committed(sb, query)
      sb.send(:handle, "/#{query}\r")
      sb
    end

    def assert_creates(sb)
      created = 0
      stub_method(sb, :create, -> { created += 1 }) { sb.send(:dispatch, "n") }
      assert_equal 1, created, "n is new workspace"
    end

    def sidebar_with_keys(keys)
      sb = sidebar_with_config({ "sidebar_keys" => keys.transform_keys(&:to_s) })
      sb.send(:resolve_keymap)
      sb.instance_variable_set(:@nodes, [proj("app"), ws("x")])
      sb.send(:recompute_rows)
      sb
    end
  end
end
