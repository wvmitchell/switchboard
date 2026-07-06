# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Render — the model -> frame half (#57): the row formatter and its
  # fixed columns, the glyphs/dots and their state resolution, header/footer/
  # console, scrolling, and the ? overlay lines. White-box like the rest of the
  # sidebar suite: the mixin lands on Sidebar, so tests drive a sidebar(...)
  # instance from SidebarCase; raw render-to-stdout stays out of scope.
  class SidebarRenderTest < SidebarCase
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

    # --- background-monitor dot (∞) ------------------------------------------

    def test_monitoring_glyph_and_dot
      sb = sidebar
      assert_equal "∞", sb.send(:glyph_for, :monitoring)
      assert_includes sb.send(:dot_for, :monitoring), "∞"
    end

    # render_state is the single resolver both paint paths use: a monitored worktree AT
    # REST shows :monitoring; active states win so live work / input requests still show.
    def test_render_state_shows_monitoring_only_at_rest
      sb = sidebar(agents: { "/wt/a" => :done, "/wt/b" => :thinking, "/wt/c" => :waiting, "/wt/d" => nil },
                   monitoring: %w[/wt/a /wt/b /wt/c /wt/d])
      assert_equal :monitoring, sb.send(:render_state, "/wt/a"), "done + monitored -> ∞"
      assert_equal :monitoring, sb.send(:render_state, "/wt/d"), "idle/aged-out + monitored -> ∞"
      assert_equal :thinking,   sb.send(:render_state, "/wt/b"), "thinking wins (live work)"
      assert_equal :waiting,    sb.send(:render_state, "/wt/c"), "waiting wins (needs input)"
    end

    def test_render_state_is_the_plain_state_when_not_monitored
      sb = sidebar(agents: { "/wt/a" => :done }, monitoring: [])
      assert_equal :done, sb.send(:render_state, "/wt/a")
    end

    # The rendered ws row actually carries the ∞ (via ws_glyph -> render_state) when the
    # worktree is a resting monitor.
    def test_a_resting_monitored_ws_row_renders_the_dot
      node = ws("watcher", path: "/wt/watch")
      sb = sidebar(nodes: [proj("app"), node], agents: { "/wt/watch" => :done }, monitoring: ["/wt/watch"])
      assert_includes sb.send(:plain, node), "∞", "idle-between-ticks reads as watching, not done"
    end

    def test_line_draws_a_reverse_video_bar_only_for_the_focused_cursor_row
      focused = sidebar(focused: true)
      assert_includes focused.send(:line, proj("app"), true, 20), "\e[7m"
      unfocused = sidebar(focused: false)
      refute_includes unfocused.send(:line, proj("app"), true, 20), "\e[7m",
                      "off-focus, the cursor row renders like any other"
    end

    # --- line: the diff-count badge (issue #79) ------------------------------

    def test_line_renders_the_diff_count_before_the_pr_badge
      node = ws("feature", pr: { "identifier" => "#12", "status" => "open" })
      sb = sidebar(nodes: [proj("app"), node], focused: false)
      sb.instance_variable_set(:@diffs, { [node.path, node.branch, node.kind] => [nil, false, 22, 333] })
      out = sb.send(:line, node, false, 40)
      assert_includes out, "\e[32m+22\e[0m",  "additions green"
      assert_includes out, "\e[31m−333\e[0m", "deletions red"
      assert_includes out, "#12"
      assert out.index("+22") < out.index("#12"), "diff count sits left of the PR badge"
    end

    # The regression guard: a row with no @diffs entry renders byte-identical to before.
    def test_line_without_a_diff_count_is_unchanged
      node = ws("plain")
      sb = sidebar(nodes: [proj("app"), node], focused: false)
      before = sb.send(:line, node, false, 40)
      sb.instance_variable_set(:@diffs, { ["/somewhere/else", "x", "ws"] => [nil, false, 9, 9] })
      assert_equal before, sb.send(:line, node, false, 40)
    end

    def test_line_keeps_the_diff_and_badge_within_the_column_budget
      node = ws("a-very-long-workspace-name", pr: { "identifier" => "#7", "status" => "open" })
      sb = sidebar(nodes: [proj("app"), node], focused: false)
      sb.instance_variable_set(:@diffs, { [node.path, node.branch, node.kind] => [nil, false, 999, 999] })
      out = sb.send(:line, node, false, 30)
      assert_includes out, "+999"
      assert_includes out, "#7"
      assert_operator strip_ansi(out).length, :<=, 30, "name truncates; nothing overruns the pane"
    end

    # The narrow-pane backstop: when name + diff + badge can't fit, the diff yields
    # first (the badge is the essential signal) and the row never overruns the pane.
    def test_line_drops_the_diff_badge_when_the_pane_is_too_narrow
      node = ws("nm", pr: { "identifier" => "#123456", "status" => "open" })
      sb = sidebar(nodes: [proj("app"), node], focused: false)
      sb.instance_variable_set(:@diffs, { [node.path, node.branch, node.kind] => [nil, false, 9999, 9999] })
      out = sb.send(:line, node, false, 20)
      assert_includes out, "#123456", "the PR badge survives — the essential signal"
      refute_includes out, "+9", "the diff badge is dropped when there's no room for all three"
      assert_operator strip_ansi(out).length, :<=, 20, "the row never overruns the pane"
    end

    def test_focused_bar_carries_the_plain_diff_count
      node = ws("feature")
      sb = sidebar(nodes: [proj("app"), node], focused: true)
      sb.instance_variable_set(:@diffs, { [node.path, node.branch, node.kind] => [nil, false, 4, 0] })
      out = sb.send(:line, node, true, 40)
      assert_includes out, "\e[7m",   "reverse-video cursor bar"
      assert_includes out, "+4",      "the count rides the bar, plain"
      refute_includes out, "\e[32m+4", "...uncolored under the bar, where color is stripped"
    end

    # --- line: fixed-column alignment (issue #118) ---------------------------
    #
    # The contract is now multi-row: columns are measured over the whole row set
    # (column_widths) and threaded into each line, so the +adds / −dels / #pr
    # numbers stack into straight, right-justified columns. These render a small
    # set and assert the cells share their column rather than staircasing.

    def set_diffs(sb, map) # node => [adds, dels]
      diffs = map.each_with_object({}) do |(node, (a, d)), h|
        h[[node.path, node.branch, node.kind]] = [nil, false, a, d]
      end
      sb.instance_variable_set(:@diffs, diffs)
    end

    # Render every row through line with the columns measured over @rows — the
    # render path, minus raw I/O — returning the plain (de-ANSI'd) lines.
    def lines_with_columns(sb, cols: 40)
      adds_w, dels_w, pr_w = sb.send(:column_widths, rows_of(sb))
      rows_of(sb).map do |n|
        strip_ansi(sb.send(:line, n, false, cols, adds_w: adds_w, dels_w: dels_w, pr_w: pr_w))
      end
    end

    # The column at which a token's right edge sits — the value that must match
    # across rows for a cell to be "in a fixed column".
    def ends_at(line, token) = line.index(token) + token.length

    def test_column_widths_measures_the_max_over_rows_ignoring_projects
      a = ws("a", pr: open_pr("#9"))
      b = ws("b", pr: open_pr("#1234"))
      sb = sidebar(nodes: [proj("app"), a, b], focused: false)
      set_diffs(sb, a => [22, 333], b => [5, 0])
      adds_w, dels_w, pr_w = sb.send(:column_widths, rows_of(sb))
      assert_equal "+22".length,   adds_w, "widest adds sub-column (+22)"
      assert_equal "−333".length,  dels_w, "widest dels sub-column (−333)"
      assert_equal "#1234".length, pr_w,   "widest PR (#1234); the project header doesn't count"
    end

    def test_pr_badges_share_a_fixed_right_edge
      a = ws("a", pr: open_pr("#9"))
      b = ws("b", pr: open_pr("#1234"))
      sb = sidebar(nodes: [proj("app"), a, b], focused: false)
      set_diffs(sb, a => [1, 1], b => [1, 1])
      _, la, lb = lines_with_columns(sb)
      assert_equal 40, la.rstrip.length, "the PR badge reaches the right edge of the pane"
      assert_equal la.rstrip.length, lb.rstrip.length, "both PR badges share that right edge"
      assert_equal ends_at(la, "#9"), ends_at(lb, "#1234"),
                   "...right-justified into the column, not left-aligned"
    end

    def test_adds_and_dels_stack_into_right_justified_subcolumns
      wide_adds = ws("a", pr: open_pr("#1")) # +1.2k −5
      wide_dels = ws("b", pr: open_pr("#2")) # +5 −1.2k
      sb = sidebar(nodes: [proj("app"), wide_adds, wide_dels], focused: false)
      set_diffs(sb, wide_adds => [1234, 5], wide_dels => [5, 1234])
      _, la, lb = lines_with_columns(sb)
      assert_equal ends_at(la, "+1.2k"), ends_at(lb, "+5"),    "the +adds right edges align in their sub-column"
      assert_equal ends_at(la, "−5"),    ends_at(lb, "−1.2k"), "the −dels right edges align in their sub-column"
    end

    def test_a_diff_only_row_keeps_its_diff_in_the_diff_column
      with_pr = ws("a", pr: open_pr("#1234"))
      no_pr   = ws("b") # has a diff, no PR
      sb = sidebar(nodes: [proj("app"), with_pr, no_pr], focused: false)
      set_diffs(sb, with_pr => [22, 333], no_pr => [22, 333])
      _, la, lb = lines_with_columns(sb)
      assert_equal 40, la.rstrip.length, "the PR row reaches the right edge"
      assert_operator lb.rstrip.length, :<, la.rstrip.length,
                      "the no-PR row's diff stays in the diff column — it never slides into PR territory"
      assert_equal ends_at(la, "−333"), ends_at(lb, "−333"),
                   "the diff column's right edge is fixed across both rows"
    end

    def test_a_bare_row_leaves_aligned_blanks_and_does_not_shift_its_neighbors
      top  = ws("a", pr: open_pr("#12"))
      bare = ws("a-longer-bare-name") # no diff, no PR
      bot  = ws("c", pr: open_pr("#9"))
      sb = sidebar(nodes: [proj("app"), top, bare, bot], focused: false)
      set_diffs(sb, top => [1, 1], bot => [1, 1]) # bare has no @diffs entry
      _, ltop, lbare, lbot = lines_with_columns(sb)
      assert_equal ends_at(ltop, "#12"), ends_at(lbot, "#9"),
                   "the PR column holds across the bare row between them"
      adds_w, dels_w, pr_w = sb.send(:column_widths, rows_of(sb))
      diff_w = adds_w + dels_w + (adds_w.positive? && dels_w.positive? ? 1 : 0)
      left_cols = 40 - sb.send(:region_width, diff_w, pr_w) - 1
      assert_operator lbare.rstrip.length, :<=, left_cols,
                      "the bare row reserves blank cells — its name stays in the name column"
    end

    def test_narrow_pane_drops_the_diff_column_uniformly_keeping_pr_aligned
      wide = ws("a", pr: open_pr("#123456"))
      slim = ws("b", pr: open_pr("#9"))
      sb = sidebar(nodes: [proj("app"), wide, slim], focused: false)
      set_diffs(sb, wide => [9999, 9999], slim => [1, 1])
      _, la, lb = lines_with_columns(sb, cols: 22)
      refute_includes la, "+", "the diff column is dropped when the pane can't seat all three"
      refute_includes lb, "+", "...dropped on every row, so the columns can't split"
      assert_equal ends_at(la, "#123456"), ends_at(lb, "#9"), "the PR badges stay aligned after the drop"
      assert_operator la.rstrip.length, :<=, 22, "nothing overruns the narrowed pane"
    end

    # A suppressed diff (expanded ws / diff_counts off) has a @diffs entry but
    # diff_visible? is false, so it must NOT size the columns — else every row
    # over-reserves and the whole tree shifts. Guards the #90 interaction at the
    # column_widths layer (line-level suppression is covered separately).
    def test_column_widths_ignores_a_suppressed_diff
      exp = expanded_ws("multi", path: "/wt/m", branch: "feat")
      small = ws("b", pr: open_pr("#1"))
      sb = sidebar(nodes: [proj("app"), exp, small], focused: false)
      set_diffs(sb, exp => [9999, 9999], small => [2, 3])
      adds_w, dels_w, pr_w = sb.send(:column_widths, rows_of(sb))
      assert_equal "+2".length, adds_w, "a suppressed (expanded) ws diff does not widen the adds column"
      assert_equal "−3".length, dels_w, "...nor the dels column"
      assert_equal "#1".length, pr_w,  "and its (nil) PR doesn't size the PR column"
    end

    # The focused reverse-video cursor bar is a separate render branch; it must
    # land its columns at the same edges as the normal rows around it.
    def test_focused_active_bar_aligns_with_the_other_rows
      a = ws("a", pr: open_pr("#9"))
      b = ws("b", pr: open_pr("#1234"))
      sb = sidebar(nodes: [proj("app"), a, b], cursor: 1, focused: true)
      set_diffs(sb, a => [1, 1], b => [1, 1])
      adds_w, dels_w, pr_w = sb.send(:column_widths, rows_of(sb))
      la = strip_ansi(sb.send(:line, a, true,  40, adds_w: adds_w, dels_w: dels_w, pr_w: pr_w))
      lb = strip_ansi(sb.send(:line, b, false, 40, adds_w: adds_w, dels_w: dels_w, pr_w: pr_w))
      assert_equal ends_at(la, "#9"), ends_at(lb, "#1234"),
                   "the cursor bar's PR column lines up with the rows around it"
    end

    # The multi-PR-per-workspace path: branch rows carry their own diff/PR and
    # must share the columns with a sibling ws, while the expanded ws name row
    # above them renders aligned blanks (its diff/PR moved to the branch rows).
    def test_branch_rows_share_the_columns_and_the_expanded_ws_blanks_them
      exp = expanded_ws("multi", path: "/wt/m", branch: "feat")
      act = br("feat", active: true)
      act[:path] = exp.path
      act[:pr] = open_pr("#1234")
      sib = ws("solo", path: "/wt/s", pr: open_pr("#9"))
      sb = sidebar(nodes: [proj("app"), exp, act, sib], focused: false)
      set_diffs(sb, act => [22, 333], sib => [4, 5])
      _, lexp, lact, lsib = lines_with_columns(sb)
      assert_equal ends_at(lact, "#1234"), ends_at(lsib, "#9"),  "a branch row's PR aligns with a sibling ws"
      assert_equal ends_at(lact, "−333"),  ends_at(lsib, "−5"),  "a branch row's dels align in the dels sub-column"
      assert_operator lexp.rstrip.length, :<, lact.rstrip.length, "the expanded ws row blanks its diff/PR cells"
    end

    # With no PR anywhere, the diff column right-justifies to the pane edge with
    # no dangling 2-col gap (the region_width gap is only reserved when both seat).
    def test_a_diff_only_tree_right_justifies_to_the_edge
      a = ws("a")
      b = ws("b")
      sb = sidebar(nodes: [proj("app"), a, b], focused: false)
      set_diffs(sb, a => [22, 333], b => [4, 5])
      _, la, lb = lines_with_columns(sb)
      assert_equal 40, la.rstrip.length, "with no PR column the diff reaches the right edge (no trailing gap)"
      assert_equal ends_at(la, "−333"), ends_at(lb, "−5"), "and the dels sub-column still aligns"
    end

    # pad_cell prepends PLAIN spaces to an already-ANSI-wrapped token, so color
    # must survive being right-justified into a wider sub-column.
    def test_columns_stay_colored_when_padded_in_a_multi_row_render
      a = ws("a", pr: open_pr("#9"))
      b = ws("b", pr: open_pr("#1234"))
      sb = sidebar(nodes: [proj("app"), a, b], focused: false)
      set_diffs(sb, a => [22, 333], b => [4, 5]) # b's +4/−5 are narrower → padded
      adds_w, dels_w, pr_w = sb.send(:column_widths, rows_of(sb))
      out = sb.send(:line, b, false, 40, adds_w: adds_w, dels_w: dels_w, pr_w: pr_w)
      assert_includes out, "\e[32m+4\e[0m", "adds stay green even when padded into a wider sub-column"
      assert_includes out, "\e[31m−5\e[0m", "dels stay red even when padded"
      assert_includes out, "#1234",          "the PR badge is present"
    end

    # --- footer: one-line nav + ? help (issue #62) ---------------------------
    # Now that the ? overlay is the complete key reference, the footer sheds the
    # action-key tail: it's a SINGLE line — the context-sensitive nav verb plus the
    # ? help gateway — so it never reflows on cursor move and hands the tree two rows.

    # A branch row opens the SAME workspace session as its ws row (never a branch
    # checkout — that's a footgun under a live agent), so it reads NAV_WS too, not a
    # "switch" verb implying a checkout it doesn't do.
    def test_footer_is_one_line_nav_plus_help_per_row_kind
      nodes = [proj("app"), ws("a"), br("feat")]
      [[0, Sidebar::NAV_PROJ], [1, Sidebar::NAV_WS], [2, Sidebar::NAV_WS]].each do |cursor, nav|
        sb = sidebar(nodes: nodes, cursor: cursor)
        foot = sb.send(:footer)
        assert_equal 1, foot.size, "the footer is a single line for every kind (no reflow)"
        assert foot[0].start_with?(nav), "line leads with the kind's nav verb"
        assert_includes foot[0], "? help", "...and ends with the ? help gateway"
      end
    end

    # The action keys (a/n/o/O/r/d/e/R/q) no longer ride the footer — the ? overlay
    # holds them now, so the footer stays one calm line.
    def test_footer_drops_the_action_keys_into_the_overlay
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 1)
      foot = sb.send(:footer)
      ["d delete", "o PR", "r rename", "R sync", "n new", "e settings"].each do |hint|
        refute_includes foot[0], hint, "#{hint.inspect} moved to the ? overlay"
      end
    end

    def test_footer_in_home_shows_the_title_and_help
      sb = sidebar(nodes: [proj("app"), ws("a")], cursor: 0)
      sb.instance_variable_set(:@home, true)
      foot = sb.send(:footer)
      assert_equal 1, foot.size
      assert foot[0].start_with?(Sidebar::HOME_TITLE), "home shows its title, not the nav verb"
      assert_includes foot[0], "? help"
    end

    def test_footer_on_an_empty_tree_invites_a_first_project
      foot = sidebar(nodes: []).send(:footer)
      assert_equal 1, foot.size
      assert_includes foot[0], "a add a project", "the fresh-install state shows how to add"
      assert_includes foot[0], "? help"
    end

    # Every kind's single line must still fit the pinned pane width uncut.
    def test_footer_fits_the_pin_width_on_every_kind
      [[proj("app")], [proj("app"), ws("a")], [proj("app"), ws("a"), br("f")], []].each do |nodes|
        sb = sidebar(nodes: nodes, cursor: [nodes.size - 1, 0].max)
        sb.send(:footer).each do |line|
          assert line.length <= Tmux::SIDEBAR_WIDTH, "footer #{line.inspect} fits the #{Tmux::SIDEBAR_WIDTH}-col pane"
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

    def test_help_lines_list_the_jump_keys_and_fit_width
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { %w[↑↓←→ o h j k] }) do
        lines = sb.send(:help_lines, 40)
        assert(lines.any? { |l| l.include?("g  G") }, "the overlay advertises g/G")
        assert(lines.all? { |l| strip_ansi(l).length <= 40 }, "no line overruns the pane width")
      end
    end

    # The devex-magic row: the overlay shows the user's OWN select-pane keys, so they
    # know how to move focus into the sidebar (the step switchboard never binds).
    def test_help_overlay_shows_the_users_pane_switch_keys
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { %w[↑↓←→ o] }) do
        lines = sb.send(:help_lines, 40).map { |l| strip_ansi(l) }
        assert(lines.any? { |l| l.include?("tmux (operate the sidebar)") }, "the tmux section heads it")
        assert(lines.any? { |l| l.include?("prefix ↑↓←→ o") && l.include?("move between panes") },
               "the user's resolved pane-switch keys are shown")
      end
    end

    # No detected pane-switch keys (no server / remapped away) -> the row is omitted,
    # never a blank or guessed binding.
    def test_help_overlay_omits_pane_switch_row_when_undetected
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { [] }) do
        lines = sb.send(:help_lines, 40).map { |l| strip_ansi(l) }
        refute(lines.any? { |l| l.include?("move between panes") }, "no keys -> no row")
      end
    end

    # help_body caps the body to rows-1 so the "any key to close" hint always seats,
    # even on a tiny pane (the height-cap, testable without raw I/O).
    def test_help_body_caps_to_leave_room_for_the_hint
      sb = sidebar(nodes: [proj("app")])
      stub_method(Tmux, :pane_switch_keys, -> { [] }) do
        assert_equal 4, sb.send(:help_body, 5, 40).size, "body capped to rows-1 on a short pane"
        assert_operator sb.send(:help_body, 100, 40).size, :>, 10, "a tall pane shows the full map"
      end
    end
  end
end
