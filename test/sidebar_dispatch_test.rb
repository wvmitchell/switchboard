# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # How a background dispatch looks and behaves in the sidebar: the synthetic ◌ row for
  # a worktree git doesn't list yet, the ✘ / ◌ glyphs, the task label (DR3) and failure
  # reason (DR8) in the right region, the exactly-once ring (D15), the first-turn edge
  # suppression (D16), the dispatch prompt (DR7/DR11/DR12) and the ? legend (DR9).
  class SidebarDispatchTest < SidebarCase
    def record(path:, state: "queued", task: "add retry to pr refresh", name: File.basename(path), hooked: false)
      rec = Creation.create(project: "app", name: name, path: path, task: task)
      Creation.transition(rec["id"], from: :queued, to: state, hooked: hooked) unless state == "queued"
      Creation.find(rec["id"])
    end

    def hydrated(nodes, **kw)
      sb = sidebar(nodes: nodes, **kw)
      sb.send(:inject_creations, Creation.all)
      sb.send(:recompute_rows)
      sb
    end

    # --- rows ---------------------------------------------------------------------

    def test_a_build_git_does_not_list_yet_shows_last_in_its_project
      record(path: "/wt/quiet-otter")
      sb = hydrated([proj("app"), ws("alpha"), ws("beta"), proj("other"), ws("x", project: "other")])
      assert_equal %w[alpha beta quiet-otter], rows_of(sb).select { |n| n.project == "app" && n.kind == "ws" }.map(&:name)
      assert rows_of(sb).find { |n| n.name == "quiet-otter" }.creation
    end

    def test_a_listed_worktree_uses_its_real_row_not_a_synthetic_one
      dir = real_dir("wt/quiet-otter")
      record(path: dir, state: "launching")
      sb = hydrated([proj("app"), ws("quiet-otter", path: dir)])
      assert_equal 1, rows_of(sb).count { |n| n.name == "quiet-otter" }
      assert_equal :building, sb.send(:render_state, dir)
    end

    def test_a_collapsed_project_hides_its_building_rows_too
      record(path: "/wt/quiet-otter")
      sb = hydrated([proj("app"), ws("alpha")], collapsed: ["app"])
      assert_empty ws_names(sb)
    end

    def test_canceled_builds_are_not_shown
      rec = record(path: "/wt/quiet-otter")
      Creation.transition(rec["id"], from: :queued, to: :canceled)
      sb = hydrated([proj("app"), ws("alpha")])
      assert_equal %w[alpha], ws_names(sb)
    end

    # --- glyphs (DR4/DR5/DR10) ---------------------------------------------------------

    def test_pre_ready_states_render_one_steady_building_glyph
      %w[queued building launching].each_with_index do |state, i|
        record(path: "/wt/b#{i}", state: state)
      end
      sb = hydrated([proj("app")])
      %w[/wt/b0 /wt/b1 /wt/b2].each { |p| assert_equal :building, sb.send(:render_state, p) }
      assert_equal "◌", sb.send(:glyph_for, :building)
      assert_equal "\e[33m◌\e[0m", sb.send(:dot_for, :building), "normal-weight yellow, legible on light themes"
    end

    def test_failure_renders_the_heavy_cross_and_outranks_the_agent
      rec = record(path: "/wt/broke", state: "building")
      Creation.mark_failed(rec["id"], "setup", 1)
      sb = hydrated([proj("app")], agents: { "/wt/broke" => :thinking })
      assert_equal :failed, sb.send(:render_state, "/wt/broke")
      assert_equal "✘", sb.send(:glyph_for, :failed)
      assert_equal "\e[1;31m✘\e[0m", sb.send(:dot_for, :failed)
    end

    def test_a_building_row_never_animates
      record(path: "/wt/quiet-otter")
      sb = hydrated([proj("app")])
      sb.send(:set_visible, true)
      sb.instance_variable_set(:@visible_rows, rows_of(sb))
      refute sb.send(:pulsing?), "a steady ◌ must not wake the loop at PULSE cadence"
    end

    def test_a_ready_record_hands_the_dot_back_to_the_agent
      dir = real_dir("wt/fix-auth")
      record(path: dir, state: "ready")
      sb = hydrated([proj("app"), ws("fix-auth", path: dir)], agents: { dir => :thinking })
      assert_equal :thinking, sb.send(:render_state, dir)
    end

    # --- notes (DR3/DR8) ------------------------------------------------------------

    def test_a_building_row_shows_its_task_dimmed
      record(path: "/wt/quiet-otter", task: "add retry to the pr refresh")
      sb = hydrated([proj("app")], focused: false)
      node = rows_of(sb).find { |n| n.name == "quiet-otter" }
      line = sb.send(:line, node, false, 40)
      assert_equal 40, strip_ansi(line).length
      assert_match(/quiet-otter\s+add retry/, strip_ansi(line))
      assert_includes line, "\e[2m"
    end

    def test_the_task_stays_until_the_agent_renames_the_workspace
      dir = real_dir("wt/quiet-otter")
      record(path: dir, state: "ready", task: "fix the flaky test")
      sb = hydrated([proj("app"), ws("quiet-otter", path: dir)], focused: false)
      assert_equal "fix the flaky test", sb.send(:row_note, rows_of(sb).last)

      named = hydrated([proj("app"), ws("flaky-test-fix", path: dir)], focused: false)
      assert_nil named.send(:row_note, rows_of(named).last), "a real name replaces the task label"
    end

    def test_a_failed_row_shows_its_short_reason
      rec = record(path: "/wt/broke", state: "building")
      Creation.mark_failed(rec["id"], "setup", 1)
      sb = hydrated([proj("app")], focused: false)
      assert_includes strip_ansi(sb.send(:line, rows_of(sb).last, false, 40)), "setup exit 1"
    end

    def test_the_note_yields_to_pr_and_diff_columns
      dir = real_dir("wt/quiet-otter")
      record(path: dir, state: "ready", task: "fix it")
      sb = hydrated([proj("app"), ws("quiet-otter", path: dir, pr: open_pr("#41"))], focused: false)
      refute_includes strip_ansi(sb.send(:line, rows_of(sb).last, false, 40)), "fix it"
    end

    def test_a_narrow_pane_drops_the_note_before_the_name
      record(path: "/wt/quiet-otter", task: "a long task description")
      sb = hydrated([proj("app")], focused: false)
      line = strip_ansi(sb.send(:line, rows_of(sb).last, false, 18))
      assert_includes line, "quiet-otter"
      refute_includes line, "long"
    end

    def test_an_unseen_pre_worktree_failure_is_bold
      rec = record(path: "/wt/never-made", state: "building")
      Creation.mark_failed(rec["id"], "worktree_add", "branch exists")
      sb = hydrated([proj("app")], focused: false)
      assert_includes sb.send(:line, rows_of(sb).last, false, 40), "\e[1;33m"
    end

    # --- rings (D15) ------------------------------------------------------------------

    def test_an_announcing_visible_scan_rings_a_ready_dispatch_once
      record(path: "/wt/quiet-otter", state: "ready", task: "")
      sb = hydrated([proj("app")])
      sb.send(:set_visible, true)
      rang = []
      stub_method(Sound, :play, ->(spec) { rang << spec }) do
        2.times { sb.send(:ring_creations) }
      end
      assert_equal 1, rang.size
    end

    def test_an_off_screen_pane_never_rings
      record(path: "/wt/quiet-otter", state: "ready", task: "")
      sb = hydrated([proj("app")])
      sb.send(:set_visible, false)
      rang = []
      stub_method(Sound, :play, ->(spec) { rang << spec }) { sb.send(:ring_creations) }
      assert_empty rang
      assert Creation.ring_due?(Creation.all.first), "the ping is kept for a visible pane"
    end

    def test_a_failure_rings_the_failed_sound
      rec = record(path: "/wt/broke", state: "building")
      Creation.mark_failed(rec["id"], "setup", 1)
      sb = hydrated([proj("app")])
      sb.send(:set_visible, true)
      states = []
      stub_method(sb.instance_variable_get(:@config), :sound_for, ->(_p, state) { states << state && nil }) do
        sb.send(:ring_creations)
      end
      assert_equal [:failed], states
    end

    # --- first-turn ownership (D16) -----------------------------------------------------

    def test_a_pending_first_turn_suppresses_the_normal_completion_edge
      edges = Sidebar::Edges.new
      assert edges.send(:suppress_completion?, "/wt/a", :done, Set.new, Set["/wt/a"])
      refute edges.send(:suppress_completion?, "/wt/a", :waiting, Set.new, Set["/wt/a"]), "input requests still surface"
      refute edges.send(:suppress_completion?, "/wt/b", :done, Set.new, Set["/wt/a"])
    end

    def test_first_turn_paths_come_from_hooked_tasked_records
      dir = real_dir("wt/fix-auth")
      record(path: dir, state: "ready", task: "do it", hooked: true)
      sb = hydrated([proj("app"), ws("fix-auth", path: dir)])
      assert_equal Set[dir], sb.send(:first_turn_paths)
    end

    # --- viewing acks ---------------------------------------------------------------

    def test_viewing_the_workspace_acks_its_dispatch
      dir = real_dir("wt/fix-auth")
      rec = record(path: dir, state: "building")
      sb = hydrated([proj("app"), ws("fix-auth", path: dir)])
      sb.send(:set_visible, true)
      stub_method(Tmux, :pane_path, ->(_pane) { dir }) { sb.send(:locate) }
      assert Creation.find(rec["id"])["acked"]
    end

    # --- ↵ / d on a dispatch row ------------------------------------------------------

    def test_enter_on_a_building_row_says_still_creating
      record(path: "/wt/quiet-otter")
      sb = hydrated([proj("app")], cursor: 1)
      flashed = nil
      stub_method(sb, :flash, ->(msg) { flashed = msg }) { sb.send(:enter) }
      assert_equal "still creating…", flashed
    end

    def test_enter_on_a_pre_worktree_failure_explains_and_acks
      rec = record(path: "/wt/never-made", state: "building")
      Creation.mark_failed(rec["id"], "worktree_add", "a branch named 'x' already exists")
      sb = hydrated([proj("app")], cursor: 1)
      flashed = nil
      stub_method(sb, :flash, ->(msg) { flashed = msg }) do
        stub_method(sb, :reload, -> {}) { sb.send(:enter) }
      end
      assert_equal "worktree add failed: a branch named 'x' already exists", flashed
      assert Creation.find(rec["id"])["acked"]
    end

    def test_d_on_a_building_row_cancels_it
      rec = record(path: "/wt/quiet-otter", state: "building")
      sb = hydrated([proj("app")], cursor: 1)
      stub_method(sb, :confirm, ->(_m) { true }) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(sb, :reload, -> {}) { sb.send(:remove) }
        end
      end
      assert_equal "canceled", Creation.find(rec["id"])["state"]
    end

    # The ◌ row can lag the build by a tree-tick: by the time you press d, the worker may
    # have made the worktree and opened its session. Cancel, then tear those down too.
    def test_d_on_a_stale_building_row_tears_down_a_worktree_it_already_made
      rec = record(path: "/wt/quiet-otter", state: "building")
      sb = hydrated([proj("app")], cursor: 1)
      Creation.update(rec["id"], worktree_added: true) # built since the last rebuild
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb.instance_variable_set(:@config, Config.new)
      killed = removed = nil
      stub_method(sb, :confirm, ->(_m) { true }) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(Tmux, :kill, ->(wt) { killed = wt.path }) do
            stub_method(sb, :start_removal, lambda { |repo, path, branch, force_branch: false|
              removed = [repo, path, branch, force_branch]
            }) do
              # the branch checked out there — NOT the record's name (a dir-only rename
              # during launching leaves the branch on the placeholder)
              stub_method(Git, :current_branch, ->(_p) { "wv/quiet-otter" }) do
                stub_method(Creator, :untouched?, ->(*) { true }) do
                  stub_method(sb, :reload, -> {}) { sb.send(:remove) }
                end
              end
            end
          end
        end
      end
      assert_equal "canceled", Creation.find(rec["id"])["state"]
      assert_equal "/wt/quiet-otter", killed
      # proven untouched, so its placeholder branch is force-deleted (-d never reads it
      # as merged into your local base and would leak one per cancel)
      assert_equal ["/repos/app", "/wt/quiet-otter", "wv/quiet-otter", true], removed
    end

    # Setup or the agent already wrote in the tree: cancel stops the session but must
    # NOT force-remove the work — it stays for d on its real row (which asks first).
    def test_d_on_a_stale_row_keeps_a_tree_that_has_changes
      rec = record(path: "/wt/quiet-otter", state: "launching")
      sb = hydrated([proj("app")], cursor: 1)
      Creation.update(rec["id"], worktree_added: true)
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" }]))
      sb.instance_variable_set(:@config, Config.new)
      removed = false
      flashed = nil
      stub_method(sb, :confirm, ->(_m) { true }) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(Tmux, :kill, ->(*) {}) do
            stub_method(Creator, :untouched?, ->(*) { false }) do
              stub_method(sb, :start_removal, ->(*) { removed = true }) do
                stub_method(sb, :flash, ->(m) { flashed = m }) do
                  stub_method(sb, :reload, -> {}) { sb.send(:remove) }
                end
              end
            end
          end
        end
      end
      refute removed
      assert_match(/kept quiet-otter: it has changes/, flashed)
      assert_equal "canceled", Creation.find(rec["id"])["state"]
    end

    # The build reached ready while the "cancel?" confirm was up: the cancel no-ops, and
    # nothing may be torn down — it's a live workspace now (its real row's d has the
    # dirty check).
    def test_d_never_tears_down_a_build_that_finished_during_the_confirm
      rec = record(path: "/wt/quiet-otter", state: "building")
      sb = hydrated([proj("app")], cursor: 1)
      Creation.update(rec["id"], worktree_added: true)
      torn = false
      confirm = lambda do |_m|
        Creation.transition(rec["id"], from: :building, to: :ready)
        true
      end
      stub_method(sb, :confirm, confirm) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(Tmux, :kill, ->(*) { torn = true }) do
            stub_method(sb, :start_removal, ->(*) { torn = true }) do
              stub_method(sb, :reload, -> {}) { sb.send(:remove) }
            end
          end
        end
      end
      refute torn
      assert_equal "ready", Creation.find(rec["id"])["state"]
    end

    # Another pane's GC dropped the record since this pane last rebuilt: the stale row
    # still can't be switched into (no dir to open the agent in), and d just reloads.
    def test_a_stale_synthetic_row_whose_record_is_gone_is_inert
      rec = record(path: "/wt/quiet-otter", state: "building")
      sb = hydrated([proj("app")], cursor: 1)
      Creation.delete(rec["id"])
      sb.instance_variable_set(:@creation_for, {})
      node = sb.instance_variable_get(:@rows)[1]
      assert sb.send(:dispatch_pending?, node), "a synthetic row never falls through to switch"
      asked = reloaded = false
      stub_method(sb, :confirm, ->(_m) { asked = true }) do
        stub_method(sb, :reload, -> { reloaded = true }) do
          sb.send(:remove)
          sb.send(:enter_dispatch, node)
        end
      end
      refute asked
      assert reloaded
    end

    # A ◌ row whose build has since finished: there's nothing to cancel, so no confirm —
    # just the reload that brings in its real row.
    def test_d_on_a_stale_row_of_a_finished_build_just_reloads
      rec = record(path: "/wt/quiet-otter", state: "building")
      sb = hydrated([proj("app")], cursor: 1)
      Creation.transition(rec["id"], from: :building, to: :ready)
      asked = reloaded = false
      stub_method(sb, :confirm, ->(_m) { asked = true }) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(sb, :reload, -> { reloaded = true }) { sb.send(:remove) }
        end
      end
      refute asked
      assert reloaded
      assert_equal "ready", Creation.find(rec["id"])["state"]
    end

    # Value: protects=d on a ✘ row dismisses it (ack) with no "cancel?" confirm and no state change; fails_when=dismiss_dispatch loses its failed branch, so d on a ✘ asks to cancel and the from-PRE_READY transition no-ops, leaving the ✘ undismissable; why_new=only the building-row cancel path is tested; seam=none; no_claim=GC dropping the acked record
    def test_d_on_a_failed_row_dismisses_without_asking
      rec = record(path: "/wt/never-made", state: "building")
      Creation.mark_failed(rec["id"], "worktree_add", "branch exists")
      sb = hydrated([proj("app")], cursor: 1)
      asked = false
      stub_method(sb, :confirm, ->(_m) { asked = true }) do
        stub_method(Tmux, :broadcast_warm, ->(**_k) {}) do
          stub_method(sb, :reload, -> {}) { sb.send(:remove) }
        end
      end
      found = Creation.find(rec["id"])
      refute asked, "dismissing a ✘ needs no confirm"
      assert found["acked"]
      assert_equal "failed", found["state"]
    end

    # Value: protects=↵ on a real row whose dispatch is still launching switches you in once its session exists (watch setup run), and only says "still creating…" before it does; fails_when=dispatch_pending? treats every PRE_READY real row as pending (blocking entry to a live session) or ignores PRE_READY (switching into a session the worker hasn't opened, which would create it with the agent command); why_new=existing ↵ tests cover only synthetic rows; seam=none; no_claim=what Tmux.go does with the session
    def test_enter_on_a_launching_row_switches_once_its_session_exists
      dir = real_dir("wt/quiet-otter")
      record(path: dir, state: "launching")
      sb = hydrated([proj("app"), ws("quiet-otter", path: dir)], cursor: 1)
      went = flashed = nil
      stub_method(sb, :flash, ->(msg) { flashed = msg }) do
        stub_method(sb, :switch, ->(node) { went = node.path }) do
          stub_method(Tmux, :has_session?, ->(_n) { false }) { sb.send(:enter) }
          assert_equal "still creating…", flashed
          assert_nil went, "no session yet: never switch"
          stub_method(Tmux, :has_session?, ->(_n) { true }) { sb.send(:enter) }
        end
      end
      assert_equal dir, went
    end

    # Value: protects=removing a project cancels ITS in-flight builds (only its) before its sessions are killed; fails_when=remove_project drops or reorders Creation.cancel_all(projects:), so a worker opens a session for a just-removed project (orphaned forever, prune can't see it) or another project's build is canceled; why_new=Creation.cancel_all scoping is unit-tested but nothing pins the sidebar call site or its order vs the kill; seam=none; no_claim=the worker honoring the cancel
    def test_removing_a_project_cancels_only_its_builds_before_the_kill
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => "/repos/app" },
                                                       { "name" => "other", "path" => "/repos/other" }]))
      mine = record(path: "/wt/quiet-otter", state: "building")
      theirs = Creation.create(project: "other", name: "brave-fox", path: "/wt/brave-fox", task: "")
      sb = hydrated([proj("app"), proj("other")])
      sb.instance_variable_set(:@config, Config.new)
      sb.define_singleton_method(:reload) { |**| }
      state_at_kill = nil
      stub_method(Tmux, :broadcast_warm, ->(**) {}) do
        stub_method(Tmux, :session_of, ->(*) { "sb/home" }) do
          stub_method(Tmux, :kill_project_sessions, ->(*) { state_at_kill = Creation.find(mine["id"])["state"]; [] }) do
            stub_method(sb, :confirm, ->(*) { true }) { sb.send(:remove_project, proj("app")) }
          end
        end
      end
      assert_equal "canceled", state_at_kill, "canceled BEFORE its sessions are killed"
      assert_equal "queued", Creation.find(theirs["id"])["state"], "another project's build is untouched"
    end

    # Value: protects=the sidebar's q cancels every in-flight build before Tmux.kill_all (D17); fails_when=Sidebar#quit drops or moves Creation.cancel_all after the kill, so a build in flight opens a fresh session after the teardown; why_new=only CLI#quit's ordering is tested — the sidebar quit is a separate code path; seam=none; no_claim=the worker's lock-serialized cancel check
    def test_sidebar_quit_cancels_builds_before_killing_sessions
      rec = record(path: "/wt/quiet-otter", state: "building")
      sb = hydrated([proj("app")])
      state_at_kill = nil
      stub_method(sb, :confirm, ->(_m) { true }) do
        stub_method(Tmux, :kill_all, -> { state_at_kill = Creation.find(rec["id"])["state"]; [] }) do
          refute sb.send(:quit), "a confirmed quit leaves the loop"
        end
      end
      assert_equal "canceled", state_at_kill
    end

    # rebuild hands GC the configured project NAMES, so a removed project's finished
    # records (nothing renders or acks them any more) get dropped; and a warm reload
    # skips GC's per-build owner checks.
    def test_rebuild_gcs_with_the_configured_projects
      repo = temp_git_repo("app")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "app", "path" => repo }]))
      FileUtils.mkdir_p(path("gone-wt"))
      gone = Creation.create(project: "gone", name: "x", path: path("gone-wt"), task: "")
      Creation.transition(gone["id"], from: :queued, to: :ready)
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      seen = []
      real = Creation.method(:gc)
      stub_method(Creation, :gc, ->(**kw) { seen << kw[:owners]; real.call(**kw) }) do
        sb.send(:rebuild)
        sb.instance_variable_set(:@warming, true)
        sb.send(:rebuild)
      end
      assert_nil Creation.find(gone["id"])
      assert_equal [true, false], seen
    end

    # --- prompt (DR7/DR11/DR12) ---------------------------------------------------------

    def test_a_long_task_scrolls_to_the_caret
      sb = sidebar
      view = sb.send(:tail_view, "app task › ", "add retry with backoff to the pr refresh", 30)
      assert_equal 30, view.length
      assert view.start_with?("app task › …")
      assert view.end_with?("pr refresh"), "what you just typed stays visible"
    end

    def test_a_multiline_paste_folds_into_one_line_instead_of_submitting
      sb = sidebar
      buf = +""
      assert_equal :edit, sb.send(:edit_buffer, "fix the bug\nin the parser\r\n", buf, fold_newlines: true)
      assert_equal "fix the bug in the parser ", buf
      assert_equal :submit, sb.send(:edit_buffer, "\r", buf, fold_newlines: true), "a typed ↵ still submits"
    end

    # A bracketed paste spread over several reads — the second read ending on a lone
    # newline, exactly what used to submit early — stays text: nothing in it submits,
    # and keys inside it (`d`, `y`, `q`) are just letters.
    def test_a_bracketed_paste_across_reads_never_submits_or_acts
      sb = sidebar
      buf = String.new
      paste = { on: false }
      ["\e[200~fix the d", "eploy\n", "then say y and q\n", "\e[201~"].each do |chunk|
        assert_equal :edit, sb.send(:edit_buffer, chunk, buf, fold_newlines: true, paste: paste), chunk.inspect
      end
      refute paste[:on]
      assert_equal "fix the deploy then say y and q ", buf
      assert_equal :submit, sb.send(:edit_buffer, "\r", buf, fold_newlines: true, paste: paste), "a real ↵ after it"
    end

    # Value: protects=a paste whose start/end marker straddles two reads still ends, so the next ↵ submits; fails_when=edit_buffer matches only a whole marker per read, leaving paste mode on and swallowing ↵/Esc/^C; why_new=the across-reads test keeps each marker whole; seam=none; no_claim=a real terminal's read sizes
    def test_a_paste_marker_split_across_reads_still_ends_the_paste
      sb = sidebar
      buf = String.new
      paste = { on: false }
      ["\e[20", "0~fix the thing\e[2", "01~"].each do |chunk|
        assert_equal :edit, sb.send(:edit_buffer, chunk, buf, fold_newlines: true, paste: paste), chunk.inspect
      end
      refute paste[:on]
      assert_equal "fix the thing", buf
      assert_equal :submit, sb.send(:edit_buffer, "\r", buf, fold_newlines: true, paste: paste)
      assert_equal :cancel, sb.send(:edit_buffer, "\e", +"", fold_newlines: true, paste: { on: false }),
                   "a lone Esc is never held back as a marker start"
    end

    # Once you've seen a ✘ on a tree you kept, the agent's live work and input requests
    # show over it again; at rest the ✘ stays.
    def test_an_acked_failure_yields_to_live_work_but_not_to_rest
      dir = real_dir("wt/kept")
      rec = record(path: dir, state: "launching")
      Creation.mark_failed(rec["id"], "setup", 1)
      Creation.ack(rec["id"])
      %i[thinking waiting].each do |state|
        sb = hydrated([proj("app"), ws("kept", path: dir)], agents: { dir => state })
        assert_equal state, sb.send(:render_state, dir)
      end
      sb = hydrated([proj("app"), ws("kept", path: dir)], agents: { dir => :done })
      assert_equal :failed, sb.send(:render_state, dir)
    end

    # A task label is free text: wide characters take two columns, and the row must
    # still fit the pane exactly.
    def test_a_wide_character_task_label_still_fits_the_row
      record(path: "/wt/quiet-otter", task: "修正するパーサーのバグ 🐛 and more words")
      [[false, false], [true, true]].each do |active, focused| # a plain row and the cursor row
        sb = hydrated([proj("app")], focused: focused)
        node = rows_of(sb).find { |n| n.name == "quiet-otter" }
        shown = strip_ansi(sb.send(:line, node, active, 40))
        assert_equal 40, display_cols(shown), "active=#{active}: #{shown.inspect}"
      end
    end

    # Emoji drawn as emoji below the CJK blocks (✅ ✨ ⚡) take two columns too; the
    # expected widths are spelled out, not measured with the renderer's own table.
    def test_symbol_emoji_in_a_task_label_count_two_columns
      sb = sidebar
      assert_equal 15, sb.send(:columns, "fix ✅ ✨ 🐛 修")
      assert_equal 5, sb.send(:columns, "abc ©"), "© is text-presentation: one column"
    end

    # The prompt line is painted on the bottom row, where one column too many wraps and
    # scrolls the pane: a wide task keeps its tail within the width, in columns.
    def test_the_task_prompt_line_fits_its_width_in_columns
      sb = sidebar
      shown = sb.send(:tail_view, "app task › ", "修正するパーサーのバグを直す 🐛", 30)
      assert_operator display_cols(shown), :<=, 30
      assert shown.end_with?("🐛")

      # Value: protects=the prompt's caret parks right after a wide typed task, in columns; fails_when=draw_prompt places the caret by String#length, so it lands mid-text on CJK/emoji; why_new=the prompt tests only measure the line, never the caret move; seam=none; no_claim=a real terminal's own width table (40-col fallback winsize)
      out = capture_stdout { sb.send(:draw_prompt, "app task", "修正する 🐛", tail: true) }
      typed = out[/\e\[\d+;1H\e\[K(.*?)\e\[\d+;\d+H/m, 1]
      assert_equal "app task › 修正する 🐛", typed
      assert_match(/\e\[\d+;#{display_cols(typed) + 1}H\e\[\?25h/, out, "caret right after the 🐛")
    end

    # A ✘ row exists only where git lists no tree; d dismisses it whatever the record
    # thinks was built.
    def test_d_dismisses_a_failure_row_even_if_a_tree_was_recorded
      rec = record(path: "/wt/broke", state: "building")
      Creation.mark_failed(rec["id"], "worktree_add", "x")
      Creation.update(rec["id"], worktree_added: true)
      sb = hydrated([proj("app")], cursor: 1)
      stub_method(Tmux, :broadcast_warm, ->(**_k) {}) { stub_method(sb, :reload, -> {}) { sb.send(:remove) } }
      assert Creation.find(rec["id"])["acked"]
    end

    # Measured independently of the renderer's own width table: everything this test's
    # strings use from U+2E80 up (CJK, kana, emoji) is two columns, the rest one.
    def display_cols(str)
      str.each_char.sum { |c| c.ord >= 0x2E80 ? 2 : 1 }
    end

    # Two records on one path (a finished one outliving its tree, a fresh build): the
    # sidebar indexes the NEWEST, like for_path — else re-entry would read the old one's
    # setup_ok and start the agent on the new, un-set-up tree.
    def test_the_sidebar_indexes_the_newest_record_on_a_reused_path
      dir = real_dir("wt/reused")
      old = Creation.create(project: "app", name: "reused", path: dir, task: "", now: Time.now - 3600)
      Creation.transition(old["id"], from: :queued, to: :ready, setup_ok: true)
      fresh = record(path: dir, state: "building")
      sb = hydrated([proj("app"), ws("reused", path: dir)])
      assert_equal fresh["id"], sb.instance_variable_get(:@creation_for)[dir]["id"]
      assert_equal :building, sb.send(:render_state, dir)
    end

    # DR1: n keeps the cursor on the row it was on, even when the new ◌ row lands above.
    def test_the_cursor_stays_on_its_row_when_a_dispatch_lands_above_it
      sb = hydrated([proj("app"), ws("a"), proj("other"), ws("b", project: "other")], cursor: 3)
      record(path: "/wt/new-otter")
      sb.send(:keep_cursor) do
        sb.send(:inject_creations, Creation.all)
        sb.send(:recompute_rows)
      end
      assert_equal "b", rows_of(sb)[sb.instance_variable_get(:@cursor)].name
    end

    # A task from Slack/docs carries smart quotes, accents, CJK; none may silently vanish.
    def test_the_task_prompt_keeps_non_ascii_text_and_backspaces_whole_characters
      sb = sidebar
      buf = String.new
      "fix the café “quote” 修正".b.each_char { |c| sb.send(:edit_buffer, c, buf, fold_newlines: true, paste: {on: false}) }
      assert_equal "fix the café “quote” 修正", sb.send(:display_text, buf, true)
      sb.send(:edit_buffer, "\x7F", buf, fold_newlines: true, paste: {on: false})
      assert_equal "fix the café “quote” 修", sb.send(:display_text, buf, true)
    end

    def test_a_name_prompt_still_drops_non_ascii
      sb = sidebar
      buf = +""
      sb.send(:edit_buffer, "caf\xC3\xA9".b, buf)
      assert_equal "caf", buf
    end

    # A fast last key + ↵ (or a laggy pane / ssh batching) arrives as ONE read; that ↵ is
    # still a submit, not a folded space you'd have to press ↵ again after.
    def test_a_batched_last_key_and_enter_still_submits
      sb = sidebar
      %W[t\r t\n t\r\n].each do |chunk|
        buf = +"fix i"
        assert_equal :submit, sb.send(:edit_buffer, chunk, buf, fold_newlines: true), chunk.inspect
        assert_equal "fix it", buf
      end
    end

    # Value: protects=keys read in the same batch as `n` become the task, not tree commands; fails_when=handle keeps dispatching the batch past the key that opened the prompt (the task loses its start and `e`/`r`/`d` fire after submit); why_new=the prompt tests feed edit_buffer directly, never handle; seam=none; no_claim=a real terminal's read batching
    def test_keys_typed_with_n_in_one_read_become_the_task
      sb = sidebar(nodes: [proj("app")])
      tasks = []
      flashes = []
      stub_method(Creator, :dispatch, ->(_c, _p, task) { tasks << task; :no_name }) do
        stub_method(sb, :read_prompt_key, -> { flunk "the batch already held the whole task" }) do
          stub_method(sb, :flash, ->(m) { flashes << m }) do
            capture_stdout { sb.send(:handle, "nfix it\r") }
          end
        end
      end
      assert_equal ["fix it"], tasks
      assert_equal ["no free workspace name — try again"], flashes, "nothing else ran as a key"
    end

    # Value: protects=a state dir that can't be written fails the create with a flash, not a dead sidebar; fails_when=Sidebar#create lets the reservation lock's SystemCallError escape the input loop; why_new=only dispatch's own failure returns were covered; seam=none; no_claim=which errno a real disk raises
    def test_an_unwritable_state_dir_flashes_instead_of_crashing
      sb = sidebar(nodes: [proj("app")])
      flashes = []
      stub_method(Creator, :dispatch, ->(*) { raise Errno::EACCES, "creation" }) do
        stub_method(sb, :prompt_line, ->(*, **) { "fix it" }) do
          stub_method(sb, :flash, ->(m) { flashes << m }) { sb.send(:create, proj("app")) }
        end
      end
      assert_equal ["couldn't record the dispatch"], flashes
    end

    def test_name_prompts_keep_first_line_submit
      sb = sidebar
      buf = +""
      assert_equal :submit, sb.send(:edit_buffer, "name\nrest", buf)
      assert_equal "name", buf
    end

    def test_the_dispatch_prompt_fits_the_pane
      sb = sidebar
      out = capture_stdout { sb.send(:draw_prompt, "switchboard task", "", hint: " (↵ = no task · esc)", tail: true) }
      visible = out.gsub(/\e\[[0-9;?]*[A-Za-z]/, "")
      assert_operator visible.length, :<=, 40
      assert_includes visible, "switchboard task ›"
      assert_includes visible, "↵ = no task"
    end

    # --- ? legend (DR9) -----------------------------------------------------------------

    def test_help_opens_with_the_glyph_legend
      sb = sidebar
      sb.instance_variable_set(:@pane_switch_keys, [])
      body = sb.send(:help_pages, 8, 40).first.map { |l| strip_ansi(l) }
      legend = body[1..2].join(" ")
      %w[working input done watching building failed].each { |w| assert_includes legend, w }
      body.each { |l| assert_operator l.length, :<=, 40 }
    end
  end
end
