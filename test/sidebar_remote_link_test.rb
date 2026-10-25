# frozen_string_literal: true

require_relative "support/sidebar_case"
require "json"

module Switchboard
  # The ⇅ remote-link cue on workspace rows, the console's link clauses, and the
  # refresh_agents / warm-fingerprint wiring. RemoteLink's own scan is pinned in
  # remote_link_test.rb; here @links is seeded directly unless the wiring is the point.
  class SidebarRemoteLinkTest < SidebarCase
    def link(stale: false, kind: "interactive", id: "session_abc")
      RemoteLink::Link.new(pid: 1, bridge_id: id, kind: kind, started_at: 0, stale: stale)
    end

    def with_links(sb, links)
      sb.instance_variable_set(:@links, links)
      sb
    end

    def folded_ws(name, path)
      n = ws(name, path: path)
      n[:folded] = 2
      n
    end

    def test_a_linked_workspace_shows_the_cue_right_after_its_name
      sb = with_links(sidebar(nodes: [ws("alpha", path: "/wt/a")]), { "/wt/a" => [link] })
      assert_equal "    alpha ⇅", sb.send(:plain, ws("alpha", path: "/wt/a"))
    end

    def test_several_links_show_a_count
      sb = with_links(sidebar, { "/wt/a" => [link, link(id: "session_two")] })
      assert_equal "    alpha ⇅2", sb.send(:plain, ws("alpha", path: "/wt/a"))
    end

    def test_a_folded_workspace_puts_the_link_before_the_branch_count
      sb = with_links(sidebar, { "/wt/a" => [link] })
      node = folded_ws("alpha", "/wt/a")
      assert_equal "    alpha ⇅ ▸2", sb.send(:plain, node)
      assert_includes strip_ansi(sb.send(:colored, node, sb.send(:plain, node))), "alpha ⇅ ▸2"
    end

    def test_an_expanded_workspace_carries_the_cue_and_its_branch_rows_never_do
      sb = with_links(sidebar(nodes: multi_branch_tree), { "/wt/m" => [link] })
      rows = rows_of(sb)
      ws_row = rows.find { |n| n.kind == "ws" && n.path == "/wt/m" }
      assert_includes sb.send(:plain, ws_row), "⇅"
      rows.select { |n| n.kind == "br" }.each { |b| refute_includes sb.send(:plain, b), "⇅" }
    end

    def test_an_unlinked_row_is_unchanged
      sb = sidebar
      assert_equal "    beta", sb.send(:plain, ws("beta", path: "/wt/b"))
    end

    # The old fit cut the WHOLE row from the right, so a long name lost its trailing
    # cues exactly when the cursor sat on it. Now the name gives way.
    def test_a_long_name_under_the_cursor_bar_keeps_both_cues
      name = "tr-line-preflight-checks-and-a-very-long-tail"
      node = folded_ws(name, "/wt/a")
      node[:pr] = open_pr("#31")
      sb = with_links(sidebar(nodes: [node], focused: true), { "/wt/a" => [link] })
      out = strip_ansi(sb.send(:line, node, true, 40))
      assert_includes out, "… ⇅ ▸2", "the name truncates, the cues survive"
      assert_equal 40, out.length
    end

    def test_the_cues_drop_only_when_no_name_column_would_remain
      node = folded_ws("alpha", "/wt/a")
      sb = with_links(sidebar(nodes: [node]), { "/wt/a" => [link] })
      assert_equal "    a…", sb.send(:fit_plain, node, 6), "4 prefix + 5 of cues leaves no name col: cues go"
      assert_equal "    … ⇅ ▸2", sb.send(:fit_plain, node, 10), "one name col left: cues stay (the name shrinks to …)"
    end

    # Value: protects=at a very narrow pane, where the cues drop, the colored row keeps the
    # plain text's visible width (and its name), so the #118 columns can't shift on that row;
    # fails_when=colored re-truncates the name to the cue-less budget again ("…" instead of
    # "ab"); why_new=red team, ship 2 (the same bug predates the link for ▸N); seam=none;
    # no_claim=a real resize
    def test_a_narrow_row_keeps_its_width_and_name_when_the_cues_drop
      node = folded_ws("ab", "/wt/a")
      sb = with_links(sidebar(nodes: [node]), { "/wt/a" => [link] })
      (5..12).each do |w|
        text = sb.send(:fit_plain, node, w)
        assert_equal text.length, strip_ansi(sb.send(:colored, node, text)).length, "width #{w}: colored == plain"
      end
      assert_includes strip_ansi(sb.send(:colored, node, sb.send(:fit_plain, node, 6))), "ab"
    end

    def test_a_link_does_not_shift_the_diff_and_pr_columns
      plain_node = ws("beta", path: "/wt/b", pr: open_pr("#24"))
      linked = ws("alpha", path: "/wt/a", pr: open_pr("#31"))
      sb = with_links(sidebar(nodes: [linked, plain_node], focused: false), { "/wt/a" => [link] })
      a = strip_ansi(sb.send(:line, linked, false, 40, pr_w: 3))
      b = strip_ansi(sb.send(:line, plain_node, false, 40, pr_w: 3))
      assert_equal [40, 40], [a.length, b.length]
      assert_equal a.index("#31"), b.index("#24"), "the #pr column stays put (#118)"
    end

    def test_a_stale_link_renders_grey_and_a_fresh_one_green
      node = ws("alpha", path: "/wt/a")
      stale = with_links(sidebar, { "/wt/a" => [link(stale: true)] })
      assert_includes stale.send(:colored, node, stale.send(:plain, node)), "#{Sidebar::LINK_STALE_FG} ⇅\e[0m"
      fresh = with_links(sidebar, { "/wt/a" => [link] })
      out = fresh.send(:colored, node, fresh.send(:plain, node))
      assert_includes out, "#{Sidebar::LINK_LIVE_FG} ⇅\e[0m"
      refute_includes out, Sidebar::LINK_STALE_FG
    end

    def test_any_stale_link_greys_the_row_even_behind_a_newer_busy_one
      node = ws("alpha", path: "/wt/a")
      sb = with_links(sidebar, { "/wt/a" => [link, link(stale: true, id: "session_old")] })
      assert_includes sb.send(:colored, node, sb.send(:plain, node)), Sidebar::LINK_STALE_FG
    end

    # Value: protects=a newer background job (never stale, D6) can't hide an older forgotten
    # interactive link; fails_when=row greyness follows the first/newest link instead of any;
    # why_new=the busy case above uses two interactive links; seam=none; no_claim=real scan order
    def test_any_stale_link_greys_the_row_even_behind_a_newer_background_job
      node = ws("alpha", path: "/wt/a")
      sb = with_links(sidebar, { "/wt/a" => [link(kind: "bg", id: "session_bg"), link(stale: true, id: "session_old")] })
      assert_includes sb.send(:colored, node, sb.send(:plain, node)), Sidebar::LINK_STALE_FG
    end

    # Under the reverse-video bar a color code paints the glyph's cell background (fg and
    # bg swap), an off-shade block in the bar, so the bar row is one uniform run: shape
    # survives, color doesn't, as with the dots.
    def assert_uniform_bar(out)
      assert out.start_with?("\e[7m") && out.end_with?("\e[0m"), "a reverse-video bar"
      assert_equal ["\e[7m", "\e[0m"], out.scan(/\e\[[\d;]*m/), "no color inside the bar"
    end

    def test_a_stale_link_under_the_cursor_bar_keeps_the_bar_uniform
      node = ws("alpha", path: "/wt/a")
      sb = with_links(sidebar(nodes: [node], focused: true), { "/wt/a" => [link, link(stale: true, id: "session_old")] })
      out = sb.send(:line, node, true, 40)
      assert_uniform_bar(out)
      assert_includes out, "alpha ⇅2"
      assert_equal 40, strip_ansi(out).length
    end

    # Value: protects=at a pane too narrow for the cues, a linked row under the cursor bar
    # still paints full width; fails_when=the bar path regains a cue lookup that assumes the
    # cue fits; seam=none; no_claim=a real resize (@links seeded)
    def test_a_narrow_stale_linked_row_under_the_cursor_bar_paints_without_its_cues
      node = folded_ws("alpha", "/wt/a")
      sb = with_links(sidebar(nodes: [node], focused: true), { "/wt/a" => [link(stale: true)] })
      out = sb.send(:line, node, true, 8)
      assert_equal "\e[7m    alp…\e[0m", out, "the cues drop and nothing raises"
    end

    # Value: protects=a placeholder ws showing its dispatch task note keeps its ⇅ and a uniform
    # bar under the cursor; fails_when=note_line goes back to trunc(plain) or colors the cue;
    # why_new=the tests above drive line's diff/PR path, never the note path; seam=none;
    # no_claim=real Creation record, @links seeded
    def test_a_task_note_row_under_the_cursor_bar_keeps_its_link_and_a_uniform_bar
      dir = real_dir("wt/quiet-otter")
      rec = Creation.create(project: "app", name: "quiet-otter", path: dir, task: "fix the flaky test")
      Creation.transition(rec["id"], from: :queued, to: "ready")
      node = ws("quiet-otter", path: dir)
      sb = with_links(sidebar(nodes: [proj("app"), node], focused: true), { dir => [link(stale: true)] })
      sb.send(:inject_creations, Creation.all)
      sb.send(:recompute_rows)
      row = rows_of(sb).find { |n| n.kind == "ws" }
      assert_equal "fix the flaky test", sb.send(:row_note, row), "the note path is the one under test"
      out = sb.send(:line, row, true, 40)
      assert_match(/quiet-otter ⇅\s+fix the flaky test/, strip_ansi(out))
      assert_uniform_bar(out)
      assert_equal 40, strip_ansi(out).length
    end

    # Value: protects=on a narrowed pane (note dropped) a task row keeps its ⇅ and a uniform bar;
    # fails_when=line_without_note colors the cue; why_new=only the wide note path is above;
    # seam=none; no_claim=real Creation record, @links seeded
    def test_a_narrow_task_note_row_under_the_cursor_bar_keeps_its_link_and_a_uniform_bar
      dir = real_dir("wt/quiet-otter")
      Creation.create(project: "app", name: "quiet-otter", path: dir, task: "fix the flaky test") # queued
      node = ws("quiet-otter", path: dir)
      sb = with_links(sidebar(nodes: [proj("app"), node], focused: true), { dir => [link(stale: true)] })
      sb.send(:inject_creations, Creation.all)
      sb.send(:recompute_rows)
      row = rows_of(sb).find { |n| n.kind == "ws" }
      out = sb.send(:line, row, true, 18) # too narrow for the note: line_without_note
      assert_equal "  ◌ quiet-otter ⇅ ", strip_ansi(out), "the note drops; the name and cue stay"
      assert_uniform_bar(out)
    end

    # The ? overlay's legend is the only place the row glyphs are taught.
    def test_the_help_legend_teaches_both_link_states
      legend = sidebar.send(:legend_lines, 40).join("\n")
      assert_includes legend, "#{Sidebar::LINK_LIVE_FG}⇅\e[0m \e[2mon phone"
      assert_includes legend, "#{Sidebar::LINK_STALE_FG}⇅\e[0m \e[2midle link"
    end

    def test_console_counts_links_and_idle_links
      sb = with_links(sidebar(nodes: [ws("a", path: "/wt/a"), ws("b", path: "/wt/b")]),
                      { "/wt/a" => [link(stale: true)], "/wt/b" => [link(kind: "bg")] })
      assert_equal "2 worktrees · 1 idle link · 2 linked", sb.send(:console)
    end

    def test_console_drops_whole_clauses_and_keeps_idle_links_when_tight
      nodes = (1..12).map { |i| ws("w#{i}", path: "/wt/#{i}", pr: (open_pr("##{i}") if i <= 4)) }
      sb = with_links(sidebar(nodes: nodes, agents: { "/wt/1" => :thinking, "/wt/2" => :thinking, "/wt/3" => :thinking }),
                      { "/wt/1" => [link(stale: true)], "/wt/2" => [link], "/wt/3" => [link] })
      assert_operator sb.send(:console).length, :>, 40
      assert_equal "12 worktrees · 1 idle link · 3 active", sb.send(:console, 40),
                   "linked, then PRs drop whole; the idle-link warning stays"
      sb.instance_variable_set(:@home, true) # the console line only seats on home (or H)
      header = sb.send(:header, 40).map { |l| strip_ansi(l) }
      assert_includes header, "12 worktrees · 1 idle link · 3 active"
    end

    # R1: link code may add a ⇅ but never change a dot, chime or bold. A raise in the
    # link scan must not trip refresh_agents' broad rescue (which blanks every dot).
    def test_a_raising_link_scan_leaves_the_dots_alone
      a = real_dir("a")
      sb = sidebar(nodes: [ws("a", path: a)])
      states = { a => :thinking }
      as = Struct.new(:last_hook_states).new(states)
      as.define_singleton_method(:scan) { |_paths, hooks_only: false| states }
      sb.instance_variable_set(:@agent_state, as)
      stub_method(RemoteLink, :scan, ->(*, **) { raise "Claude changed its format" }) do
        assert sb.send(:refresh_agents, refresh_prs: false), "the scan still succeeds"
      end
      assert_equal({ a => :thinking }, sb.instance_variable_get(:@agents))
      assert_equal({}, sb.instance_variable_get(:@links))
    end

    # Value: protects=a hidden pane asks for the cheap link scan and a visible one for the full
    # scan — even on a hooks_only reload (the on-screen post-delete reload passes it);
    # fails_when=the cheap flag is tied to hooks_only again (a visible pane places links by the
    # stale recorded cwd) or dropped (hidden panes spawn ps/lsof again); why_new=red team, ship 2;
    # seam=none (stubs RemoteLink.scan); no_claim=real subprocess counts
    def test_only_a_hidden_pane_asks_for_the_cheap_link_scan
      a = real_dir("a")
      sb = sidebar(nodes: [ws("a", path: a)])
      as = Struct.new(:last_hook_states).new({})
      as.define_singleton_method(:scan) { |_paths, hooks_only: false| {} }
      sb.instance_variable_set(:@agent_state, as)
      seen = []
      stub_method(RemoteLink, :scan, ->(_p, stale_after:, cheap: false, **) { seen << cheap; {} }) do
        sb.instance_variable_set(:@visible, false)
        sb.send(:refresh_agents, refresh_prs: false, hooks_only: true)
        sb.instance_variable_set(:@visible, true)
        sb.send(:refresh_agents, refresh_prs: false, hooks_only: true)
        sb.send(:refresh_agents, refresh_prs: false)
      end
      assert_equal [true, false, false], seen
    end

    def test_refresh_agents_hydrates_live_links_from_the_sessions_dir
      a = real_dir("a")
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
      File.write(File.join(RemoteLink.sessions_dir, "1.json"),
                 JSON.generate("pid" => Process.pid, "cwd" => a, "sessionId" => "s", "kind" => "interactive",
                               "procStart" => ProcessIdentity.start_of(Process.pid), "status" => "busy",
                               "bridgeSessionId" => "session_live"))
      sb = sidebar(nodes: [ws("a", path: a)])
      as = Struct.new(:last_hook_states).new({})
      as.define_singleton_method(:scan) { |_paths, hooks_only: false| {} }
      sb.instance_variable_set(:@agent_state, as)
      stub_method(Agents, :cwds_of, ->(*) { {} }) { sb.send(:refresh_agents, refresh_prs: false) }
      assert_equal ["session_live"], sb.instance_variable_get(:@links)[a].map(&:bridge_id)
    end

    def test_the_warm_fingerprint_moves_on_a_link_but_not_on_status_churn
      a = real_dir("a")
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
      tick = Time.now
      write = lambda do |**over|
        File.write(File.join(RemoteLink.sessions_dir, "1.json"),
                   JSON.generate({ "pid" => 1, "cwd" => a, "sessionId" => "s", "status" => "busy" }.merge(over)))
        tick += 5 # a strictly newer mtime every write, whatever the filesystem's granularity
        File.utime(tick, tick, File.join(RemoteLink.sessions_dir, "1.json"))
      end
      sb = sidebar(nodes: [ws("a", path: a)])
      write.call
      base = sb.send(:warm_fingerprint)
      write.call("status" => "idle")
      assert_equal base, sb.send(:warm_fingerprint), "an unlinked session's busy/idle flip doesn't wake a hidden pane"
      write.call("bridgeSessionId" => "session_on")
      refute_equal base, sb.send(:warm_fingerprint), "/rc on does"
    end
  end
end
