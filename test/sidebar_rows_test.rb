# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/sidebar_case"

module Switchboard
  # Sidebar::Rows — the view-model half (#57): the z branch-fold row transform
  # (#107) and its cursor re-anchor, the #88/#90 diff-visibility gates, and the
  # refresh_diffs mtime-gated cache (#79). What a row SHOWS is pinned here;
  # what it looks like is sidebar_render_test.rb.
  class SidebarRowsTest < SidebarCase
    # --- z: global branch fold (issue #107) ----------------------------------
    #
    # A multi-branch workspace + a single-branch sibling, mirroring Tree.nodes:
    # the expanded ws carries NO pr (the active branch row owns the badge, #90),
    # the active branch row carries it, and folding restores it to the ws row.

    def folded_ws_of(sb, path = "/wt/m") = rows_of(sb).find { |n| n.kind == "ws" && n.path == path }

    # Project-header names in the rebuilt tree, in order.
    def project_names(sb) = sb.instance_variable_get(:@nodes).select { |n| n.kind == "proj" }.map(&:project)

    # Force a strictly-newer mtime so an mtime-gated re-read fires regardless of
    # filesystem timestamp granularity (two writes can share a coarse mtime).
    def bump_mtime(file, by: 2)
      t = File.mtime(file) + by
      File.utime(t, t, file)
    end

    def test_z_folds_every_branch_row_and_writes_through_to_the_store
      sb = sidebar(nodes: multi_branch_tree)
      assert_equal %w[proj ws br br ws], rows_of(sb).map(&:kind), "expanded: the branch rows are present"
      sb.send(:toggle_branch_fold)
      assert_equal %w[proj ws ws], rows_of(sb).map(&:kind), "folded: every branch row hidden, the ws rows remain"
      assert BranchFold.folded?, "the fold persists to the shared store"
      sb.send(:toggle_branch_fold)
      assert_equal %w[proj ws br br ws], rows_of(sb).map(&:kind), "unfolding brings the branch rows back"
      refute BranchFold.folded?, "unfold clears the shared store"
    end

    def test_a_folded_multi_branch_ws_shows_its_own_badge_again
      sb = sidebar(nodes: multi_branch_tree)
      sb.send(:toggle_branch_fold)
      folded = folded_ws_of(sb)
      refute folded.expanded, "the folded ws renders as not-expanded, so its own diff/PR badge shows"
      assert_equal "#1234", folded.pr["identifier"], "it stands in for its active branch's PR"
      assert sb.send(:diff_visible?, folded), "and #90's expanded-row suppression no longer hides its diff"
    end

    def test_a_folded_ws_shows_the_hidden_branch_count_cue
      sb = sidebar(nodes: multi_branch_tree)
      sb.send(:toggle_branch_fold)
      folded = folded_ws_of(sb)
      assert_equal 2, folded.folded, "two branch rows are tucked away"
      assert_includes strip_ansi(sb.send(:plain, folded)), "▸2", "the plain cue shows the hidden-branch count"
      colored = sb.send(:colored, folded, sb.send(:plain, folded))
      assert_includes colored, "\e[2m ▸2\e[0m", "the colored cue is dimmed"
    end

    def test_a_single_branch_ws_is_unchanged_by_the_fold
      sb = sidebar(nodes: multi_branch_tree)
      sb.send(:toggle_branch_fold)
      solo = folded_ws_of(sb, "/wt/s")
      assert_nil solo.folded, "a single-branch ws gets no fold clone / no cue"
      assert_equal "", sb.send(:fold_cue, solo)
    end

    def test_folding_from_a_branch_row_lands_the_cursor_on_its_workspace
      sb = sidebar(nodes: multi_branch_tree, cursor: 2) # on the active branch row (path /wt/m)
      sb.send(:toggle_branch_fold)
      landed = current_node(sb)
      assert_equal "ws", landed.kind
      assert_equal "/wt/m", landed.path, "z from a branch row re-anchors onto its workspace, not an unrelated row"
    end

    def test_z_folds_all_workspaces_at_once_regardless_of_cursor
      m1 = expanded_ws("one", path: "/wt/1", branch: "a")
      a1 = br("a", active: true); a1[:path] = "/wt/1"; a1[:pr] = open_pr("#1")
      b1 = br("b", last: true);   b1[:path] = "/wt/1"
      m2 = expanded_ws("two", path: "/wt/2", branch: "c")
      c2 = br("c", active: true); c2[:path] = "/wt/2"; c2[:pr] = open_pr("#2")
      d2 = br("d", last: true);   d2[:path] = "/wt/2"
      sb = sidebar(nodes: [proj("app"), m1, a1, b1, m2, c2, d2], cursor: 0) # cursor on the project header
      assert_equal 4, rows_of(sb).count { |n| n.kind == "br" }
      sb.send(:toggle_branch_fold)
      assert_equal 0, rows_of(sb).count { |n| n.kind == "br" }, "one z folds every workspace's branches, wherever the cursor is"
      assert_equal [2, 2], rows_of(sb).select { |n| n.kind == "ws" }.map(&:folded), "both workspaces show their hidden-branch counts"
    end

    def test_dispatch_routes_z_to_the_branch_fold_toggle
      sb = sidebar(nodes: multi_branch_tree)
      sb.send(:dispatch, "z")
      assert sb.instance_variable_get(:@fold_branches), "z flips the in-memory fold flag"
      assert BranchFold.folded?, "and writes through to the shared store"
    end

    def test_rebuild_hydrates_the_branch_fold_flag_from_the_shared_store
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      BranchFold.fold # as if another window's sidebar pressed z

      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      assert sb.instance_variable_get(:@fold_branches),
             "rebuild picks up the branch-fold flag another sidebar wrote"
    end

    # The cross-session gap: @config is cached per sidebar process, so a project
    # added in ANOTHER session used to stay invisible here until this pane's
    # process was respawned. rebuild now re-reads config (mtime-gated) so it shows
    # on the next reload/warm/switch-in.
    def test_rebuild_picks_up_a_project_registered_in_another_session
      app = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => app }]))
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.instance_variable_set(:@config_mtime, sb.send(:config_mtime))
      sb.send(:rebuild)
      assert_equal ["app"], project_names(sb)

      api = temp_git_repo("api")                # another session runs `a` / `switchboard add`
      File.write(Config.path, YAML.dump("projects" => [
                   { "name" => "app", "path" => app }, { "name" => "api", "path" => api }
                 ]))
      bump_mtime(Config.path)                   # guarantee a strictly newer mtime for the gate

      sb.send(:rebuild)
      assert_equal %w[api app], project_names(sb).sort,
                   "rebuild re-reads config, so the project added elsewhere appears without a respawn"
    end

    # The mtime gate is what keeps the frequent C-l reload cheap: an unchanged
    # config file is never re-parsed, only re-read once it actually changes.
    def test_refresh_config_only_re_reads_when_the_file_changed
      File.write(Config.path, YAML.dump("projects" => []))
      sb = sidebar(nodes: [])
      cfg = Config.new
      sb.instance_variable_set(:@config, cfg)
      sb.instance_variable_set(:@config_mtime, sb.send(:config_mtime))

      sb.send(:refresh_config)
      assert_same cfg, sb.instance_variable_get(:@config),
                  "an unchanged config file is not re-parsed (the mtime gate keeps C-l cheap)"

      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/x" }]))
      bump_mtime(Config.path)
      sb.send(:refresh_config)
      refute_same cfg, sb.instance_variable_get(:@config), "a changed config file IS re-read"
      assert sb.instance_variable_get(:@config).project("app"), "with the new project now in @config"
    end

    # The #118 alignment invariant must hold for a folded ws even at the minimum
    # pane width: a 2-digit diff + 4-digit PR gives left_cols=5, where the " ▸N"
    # cue would otherwise push colored past `text` and staircase the columns. The
    # cue is dropped when there's no room; the row must never overrun the pane.
    def test_a_folded_ws_never_overruns_at_the_minimum_pane_width
      sb = sidebar(nodes: multi_branch_tree, focused: false)
      sb.send(:toggle_branch_fold)
      folded = folded_ws_of(sb)
      sb.instance_variable_set(:@diffs, { [folded.path, folded.branch, "br"] => [nil, false, 22, 33] })
      aw, dw, pw = sb.send(:column_widths, rows_of(sb))
      line = sb.send(:line, folded, false, Width::MIN, adds_w: aw, dels_w: dw, pr_w: pw)
      assert_operator strip_ansi(line).length, :<=, Width::MIN,
                      "a folded ws row never overruns the pane (the cue yields before the badge columns)"
    end

    # A folded ws stands in for its active branch, so its diff reads the "br" cache
    # entry (which takes the #90 merged-bypass), NOT the nil-pr "ws" entry that can
    # go stale after a merge. Distinct values prove which key it reads.
    def test_a_folded_ws_reads_its_active_branch_diff_entry
      sb = sidebar(nodes: multi_branch_tree)
      sb.send(:toggle_branch_fold)
      folded = folded_ws_of(sb)
      sb.instance_variable_set(:@diffs, {
        [folded.path, folded.branch, "ws"] => [nil, false, 99, 99], # the stale nil-pr ws entry
        [folded.path, folded.branch, "br"] => [nil, true, 0, 0]     # the merged-healed active-branch entry
      })
      assert_equal [0, 0], sb.send(:diff_for, folded),
                   "a folded ws reads its active branch's healed br diff, not the stale ws entry"
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

    # --- diff_visible? + toggle/expanded suppression (issues #88, #90) --------

    def diff_off_config
      File.write(Config.path, YAML.dump("diff_counts" => false, "projects" => []))
      Config.new
    end

    def test_diff_visible_truth_table
      sb = sidebar # default config: diff_counts on
      refute sb.send(:diff_visible?, proj("app")),    "projects never show a diff"
      assert sb.send(:diff_visible?, ws("solo")),     "a single-branch ws shows its diff"
      assert sb.send(:diff_visible?, br("feature")),  "branch rows show their diff"
      refute sb.send(:diff_visible?, expanded_ws),    "an expanded ws drops it (the branch row owns it, #90)"
    end

    def test_diff_visible_is_false_for_every_row_when_diff_counts_off
      sb = sidebar
      sb.instance_variable_set(:@config, diff_off_config)
      refute sb.send(:diff_visible?, ws("solo")),    "diff_counts:false hides ws counts (#88)"
      refute sb.send(:diff_visible?, br("feature")), "diff_counts:false hides branch counts (#88)"
    end

    def test_refresh_diffs_is_a_noop_when_diff_counts_off
      node = diff_ws
      sb = sidebar(nodes: [node])
      gd = head_log_gitdir
      sb.instance_variable_set(:@branch_cache, { node.path => [gd, nil, nil, []] })
      sb.instance_variable_set(:@config, diff_off_config)
      sb.instance_variable_set(:@diffs, { [node.path, node.branch, node.kind] => [nil, false, 1, 1] })
      calls = 0
      stub_method(Git, :diff_counts, ->(*) { calls += 1; [2, 1] }) do
        sb.send(:refresh_diffs)
      end
      assert_equal 0, calls, "diff_counts:false must skip the git diff shell-out entirely"
      assert_empty sb.instance_variable_get(:@diffs), "and clear any counts already cached (live flip)"
    end

    def test_line_hides_the_diff_count_on_an_expanded_workspace_row
      ws_node = expanded_ws
      br_node = br("feature", active: true)
      br_node[:path] = ws_node.path
      sb = sidebar(nodes: [proj("app"), ws_node, br_node], focused: false)
      sb.instance_variable_set(:@diffs, {
        [ws_node.path, ws_node.branch, "ws"] => [nil, false, 22, 333],
        [br_node.path, br_node.branch, "br"] => [nil, false, 22, 333]
      })
      refute_includes sb.send(:line, ws_node, false, 40), "+22", "the expanded ws name row drops the count"
      assert_includes  sb.send(:line, br_node, false, 40), "+22", "the active branch row still shows it"
    end

    def test_line_hides_the_diff_count_when_diff_counts_off
      node = ws("feature")
      sb = sidebar(nodes: [proj("app"), node], focused: false)
      sb.instance_variable_set(:@config, diff_off_config)
      sb.instance_variable_set(:@diffs, { [node.path, node.branch, node.kind] => [nil, false, 22, 333] })
      refute_includes sb.send(:line, node, false, 40), "+22", "diff_counts:false hides the count at render"
    end

    # --- refresh_diffs: the off-paint diff cache (issue #79) ------------------

    # A real <gitdir>/logs/HEAD so refresh_diffs can stat a fresh mtime; returns gitdir.
    def head_log_gitdir(name = "gd")
      gitdir = path(name)
      FileUtils.mkdir_p(File.join(gitdir, "logs"))
      File.write(File.join(gitdir, "logs", "HEAD"), "x\n")
      gitdir
    end

    def diff_ws(path: "/wt/a", branch: "feat", base: "origin/main", pr: nil)
      Tree::Node.new(kind: "ws", project: "app", path: path, branch: branch, base: base, pr: pr)
    end

    def test_refresh_diffs_skips_the_shell_out_when_the_reflog_is_unchanged
      node = diff_ws
      sb = sidebar(nodes: [node])
      gd = head_log_gitdir
      sb.instance_variable_set(:@branch_cache, { node.path => [gd, nil, nil, []] })
      calls = 0
      stub_method(Git, :diff_counts, ->(*) { calls += 1; [2, 1] }) do
        sb.send(:refresh_diffs) # computes
        sb.send(:refresh_diffs) # mtime unchanged -> skips
      end
      assert_equal 1, calls, "an unchanged logs/HEAD mtime must not re-run git diff"
      assert_equal [2, 1], sb.send(:diff_for, node)
    end

    def test_refresh_diffs_recomputes_when_the_reflog_advances
      node = diff_ws
      sb = sidebar(nodes: [node])
      gd = head_log_gitdir
      log = File.join(gd, "logs", "HEAD")
      sb.instance_variable_set(:@branch_cache, { node.path => [gd, nil, nil, []] })
      calls = 0
      stub_method(Git, :diff_counts, ->(*) { calls += 1; [calls, 0] }) do
        File.utime(Time.at(1000), Time.at(1000), log)
        sb.send(:refresh_diffs)
        File.utime(Time.at(2000), Time.at(2000), log) # a commit bumped the reflog
        sb.send(:refresh_diffs)
      end
      assert_equal 2, calls, "a fresh reflog mtime re-runs the diff (the agent-edge case)"
      assert_equal [2, 0], sb.send(:diff_for, node)
    end

    # A cached gitdir whose logs/HEAD is gone reads mtime nil; it must still compute
    # once and then gate (entry presence), never re-run git diff every reload.
    def test_refresh_diffs_with_a_missing_reflog_computes_once_not_every_reload
      node = diff_ws
      sb = sidebar(nodes: [node])
      bare = path("bare-gitdir") # exists, but has no logs/HEAD
      FileUtils.mkdir_p(bare)
      sb.instance_variable_set(:@branch_cache, { node.path => [bare, nil, nil, []] })
      calls = 0
      stub_method(Git, :diff_counts, ->(*) { calls += 1; [3, 0] }) do
        sb.send(:refresh_diffs)
        sb.send(:refresh_diffs)
      end
      assert_equal 1, calls, "nil mtime computes once, then the entry-presence gate holds"
      assert_equal [3, 0], sb.send(:diff_for, node)
    end

    def test_refresh_diffs_clears_a_stale_count_when_it_cannot_recompute
      node = diff_ws
      sb = sidebar(nodes: [node])
      gd = head_log_gitdir
      sb.instance_variable_set(:@branch_cache, { node.path => [gd, nil, nil, []] })
      stub_method(Git, :diff_counts, ->(*) { [9, 9] }) { sb.send(:refresh_diffs) }
      assert_equal [9, 9], sb.send(:diff_for, node)
      sb.instance_variable_set(:@branch_cache, {}) # worktree's cache slot vanished
      sb.send(:refresh_diffs)
      assert_nil sb.send(:diff_for, node), "no ghost count when the row can no longer be diffed"
    end

    # The merge heal recomputes ONCE on the flip to MERGED/CLOSED (origin may have
    # fast-forwarded past the branch), then the gate holds — it must NOT re-run a
    # synchronous git diff every reload, which would reintroduce the per-worktree
    # cost with_dirty:false avoids.
    def test_refresh_diffs_recomputes_a_resting_row_once_on_the_transition
      node = diff_ws(pr: { "identifier" => "#3", "status" => "open" })
      sb = sidebar(nodes: [node])
      gd = head_log_gitdir
      sb.instance_variable_set(:@branch_cache, { node.path => [gd, nil, nil, []] })
      calls = 0
      stub_method(Git, :diff_counts, ->(*) { calls += 1; [0, 0] }) do
        sb.send(:refresh_diffs)                          # open: computes (1)
        sb.send(:refresh_diffs)                          # open, unchanged: skips (1)
        node.pr = { "identifier" => "#3", "status" => "merged" } # PR flips merged
        sb.send(:refresh_diffs)                          # transition: recomputes once (2)
        sb.send(:refresh_diffs)                          # still merged, unchanged: skips (2)
      end
      assert_equal 2, calls, "recompute fires once on the resting flip, then the gate holds"
    end

    def test_refresh_diffs_counts_each_branch_row_by_its_own_ref
      ws_node = diff_ws(path: "/wt/a", branch: "feat")
      br_node = Tree::Node.new(kind: "br", project: "app", path: "/wt/a", branch: "old",
                               base: "origin/main")
      sb = sidebar(nodes: [ws_node, br_node])
      gd = head_log_gitdir
      sb.instance_variable_set(:@branch_cache, { "/wt/a" => [gd, nil, nil, []] })
      stub_method(Git, :diff_counts, ->(_p, _base, ref) { ref == "feat" ? [1, 0] : [2, 0] }) do
        sb.send(:refresh_diffs)
      end
      assert_equal [1, 0], sb.send(:diff_for, ws_node)
      assert_equal [2, 0], sb.send(:diff_for, br_node), "branch rows diff their own ref vs base"
    end

    # An expanded workspace emits a ws row (pr dropped → resting false) AND an active
    # br row for the SAME branch carrying the real (merged) pr. They share [path,
    # branch]; keying on kind too keeps their disagreeing resting flags from
    # ping-ponging one entry into an unbounded per-reload recompute.
    def test_refresh_diffs_does_not_pingpong_when_ws_and_active_br_share_a_branch
      ws_node = Tree::Node.new(kind: "ws", project: "app", path: "/wt/a", branch: "feat",
                               base: "origin/main", pr: nil)
      br_node = Tree::Node.new(kind: "br", project: "app", path: "/wt/a", branch: "feat",
                               base: "origin/main", pr: { "identifier" => "#9", "status" => "merged" })
      sb = sidebar(nodes: [ws_node, br_node])
      gd = head_log_gitdir
      sb.instance_variable_set(:@branch_cache, { "/wt/a" => [gd, nil, nil, []] })
      calls = 0
      stub_method(Git, :diff_counts, ->(*) { calls += 1; [1, 0] }) do
        sb.send(:refresh_diffs) # ws computes (1) + br computes-once-on-merge (2)
        sb.send(:refresh_diffs) # both gated now
        sb.send(:refresh_diffs) # still gated
      end
      assert_equal 2, calls, "kind-keyed entries never ping-pong into a per-reload recompute"
    end
  end
end
