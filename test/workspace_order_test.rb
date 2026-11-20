# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # Workspace and project order: newest first by default, J/K to move, every sidebar
  # agreeing. Real repos and worktrees; creation times are stubbed so the order under
  # test never depends on how fast the fixture ran.
  class WorkspaceOrderTest < SidebarCase
    # Folder names sort A–Z differently from their creation times on purpose.
    TIMES = { "alpha" => 100.0, "beta" => 400.0, "gamma" => 300.0, "delta" => 200.0 }.freeze

    def setup
      super
      @times = TIMES.dup
      @repo = temp_git_repo("app")
      TIMES.each_key { |n| git(@repo, "worktree", "add", "-q", "-b", n, path("wt", n)) }
      write_config("projects" => [{ "name" => "app", "path" => @repo }])
    end

    def write_config(data) = File.write(Config.path, YAML.dump(data))

    def with_times(&block)
      times = @times # the stub runs with self bound to Git
      stub_method(Git, :created_at, ->(p) { times[File.basename(p)] }, &block)
    end

    def built
      sb = sidebar(nodes: [])
      sb.instance_variable_set(:@config, Config.new)
      sb.send(:rebuild)
      sb
    end

    def on(sb, name)
      sb.instance_variable_set(:@cursor, rows_of(sb).index { |n| n.kind == "ws" && n.name == name })
    end

    # Presses J (+n) or K (-n); returns [broadcasts, notices].
    def press(sb, delta)
      bcast = 0
      notes = []
      stub_method(Tmux, :broadcast_warm, ->(**) { bcast += 1 }) do
        stub_method(Tmux, :notify, ->(msg, **) { notes << msg }) do
          sb.send(:move_row, delta)
        end
      end
      [bcast, notes]
    end

    def order_entries = Dir.glob(File.join(Order.state_dir, "*"))

    # --- default order --------------------------------------------------------------

    # Value: protects=newest on top whatever the folder name; fails_when=the Model keeps
    # git's path order; why_new=new default; seam=none; no_claim=real birthtimes (stubbed)
    def test_workspaces_are_newest_first_whatever_their_names
      with_times { assert_equal %w[beta gamma delta alpha], ws_names(built) }
    end

    def test_an_unknown_creation_time_sorts_last
      @times["beta"] = nil
      with_times { assert_equal %w[gamma delta alpha beta], ws_names(built) }
    end

    # Value: protects=the main checkout stays first when its config path is spelled
    # differently; fails_when=the sort trusts the string-compared primary flag; why_new=new
    # sort; seam=none; no_claim=none beyond protects
    def test_the_main_checkout_stays_first_through_a_trailing_slash
      write_config("projects" => [{ "name" => "app", "path" => "#{@repo}/" }])
      trees = with_times { Model.new(Config.new, with_dirty: false).projects.first.worktrees }
      assert_equal File.realpath(@repo), File.realpath(trees.first.path)
      assert_nil trees.first.rank
    end

    # Value: protects=hook commands never raise on a worktree whose folder is gone;
    # fails_when=the tie-break compares nil with a String; why_new=new sort; seam=none
    def test_a_pruned_worktree_neither_crashes_nor_misorders
      FileUtils.rm_rf(path("wt", "gamma"))
      names = with_times { Model.new(Config.new, with_dirty: false).projects.first.worktrees.map { |w| File.basename(w.path) } }
      assert_equal %w[app beta gamma delta alpha], names
    end

    def test_the_stored_order_is_read_once_per_model
      other = temp_git_repo("web")
      write_config("projects" => [{ "name" => "app", "path" => @repo }, { "name" => "web", "path" => other }])
      calls = 0
      real = Order.method(:ranks)
      stub_method(Order, :ranks, ->(**kw) { calls += 1; real.call(**kw) }) do
        Model.new(Config.new, with_dirty: false).projects.each(&:worktrees)
      end
      assert_equal 1, calls
    end

    # --- J / K -----------------------------------------------------------------------

    # Value: protects=K moves one slot up, the cursor follows, peers hear once;
    # fails_when=the rank lands outside its neighbours or the broadcast is dropped;
    # why_new=new action; seam=none; no_claim=a real peer repaint (the smoke test)
    def test_k_moves_a_workspace_up_and_the_cursor_follows
      with_times do
        sb = built
        on(sb, "delta")
        bcast, notes = press(sb, -1)
        assert_equal %w[beta delta gamma alpha], ws_names(sb)
        assert_equal "delta", current_node(sb).name
        assert_equal 1, bcast
        assert_empty notes
        assert_equal %w[beta delta gamma alpha], ws_names(built), "a fresh sidebar reads the same order"
      end
    end

    def test_j_moves_down_and_a_count_clamps_at_the_end
      with_times do
        sb = built
        on(sb, "beta")
        press(sb, 9)
        assert_equal %w[gamma delta alpha beta], ws_names(sb)
        assert_equal "beta", current_node(sb).name
      end
    end

    # Value: protects=an end-of-list press writes nothing and says nothing; fails_when=the
    # end check runs after the write; why_new=new action; seam=none
    def test_a_press_at_the_end_does_nothing
      with_times do
        sb = built
        on(sb, "beta")
        assert_equal [0, []], press(sb, -1)
        assert_empty order_entries
      end
    end

    def test_a_workspace_moves_from_one_of_its_branch_rows
      git(path("wt", "gamma"), "checkout", "-q", "-b", "gamma-two")
      with_times do
        sb = built
        sb.instance_variable_set(:@cursor, rows_of(sb).index { |n| n.kind == "br" && n.path.end_with?("gamma") })
        press(sb, -1)
        assert_equal %w[gamma beta delta alpha], ws_names(sb)
        assert_equal ["ws", "gamma"], [current_node(sb).kind, current_node(sb).name]
      end
    end

    # Value: protects=a row git doesn't list yet stays pinned on top; fails_when=eligibility
    # ignores node.creation; why_new=new action; seam=none
    def test_a_workspace_that_does_not_exist_yet_does_not_move_and_nothing_passes_it
      Creation.create(project: "app", name: "quiet-otter", path: path("wt", "quiet-otter"), task: "t")
      with_times do
        sb = built
        assert_equal %w[quiet-otter beta gamma delta alpha], ws_names(sb)
        on(sb, "quiet-otter")
        assert_equal [0, []], press(sb, 1)
        on(sb, "beta")
        assert_equal [0, []], press(sb, -1)
        assert_equal %w[quiet-otter beta gamma delta alpha], ws_names(sb)
      end
    end

    def test_a_real_workspace_with_a_creation_record_moves
      rec = Creation.create(project: "app", name: "alpha", path: path("wt", "alpha"), task: "t")
      Creation.update(rec["id"], worktree_added: true)
      with_times do
        sb = built
        on(sb, "alpha")
        press(sb, -1)
        assert_equal %w[beta gamma alpha delta], ws_names(sb)
      end
    end

    # Value: protects=a failed save is never silent and names where and why; fails_when=
    # write! errors are swallowed; why_new=new error path; seam=none; no_claim=a real EACCES (stubbed)
    def test_a_failed_save_says_where_and_why_and_changes_nothing
      with_times do
        sb = built
        on(sb, "delta")
        stub_method(Order, :set, ->(*) { "Permission denied" }) do
          bcast, notes = press(sb, -1)
          assert_equal 0, bcast
          assert_equal 1, notes.size
          assert_includes notes.first, Order.state_dir
          assert_includes notes.first, "Permission denied"
        end
        assert_equal %w[beta gamma delta alpha], ws_names(built)
      end
    end

    # A gap too narrow to halve: beta and gamma are adjacent floats.
    def adjacent_ranks
      @times["gamma"] = 400.0
      @times["beta"] = 400.0.next_float
    end

    # Value: protects=a used-up gap renumbers and the move still lands, hidden rows
    # included; fails_when=the midpoint is written without the strict-between check;
    # why_new=new algorithm; seam=none
    def test_a_used_up_gap_renumbers_every_workspace_and_the_move_lands
      adjacent_ranks
      PendingDelete.mark(File.realpath(path("wt", "delta"))) # the path git lists
      with_times do
        sb = built
        on(sb, "alpha")
        _, notes = press(sb, -1) # delta is hidden: one row up is the used-up gap
        assert_empty notes
        assert_equal %w[beta alpha gamma], ws_names(sb)
        assert_equal 4, Order.ranks.size, "the hidden row is renumbered too"
      end
    end

    # Value: protects=a renumber that fails part-way reorders nothing; fails_when=ranks are
    # written bottom-up or below the old top; why_new=new algorithm; seam=none
    def test_a_renumber_that_fails_part_way_leaves_the_order_as_it_was
      adjacent_ranks
      real = Order.method(:set)
      (1..5).each do |k|
        FileUtils.rm_rf(Order.state_dir)
        with_times do
          sb = built
          on(sb, "alpha")
          calls = 0
          stub_method(Order, :set, ->(*args) { (calls += 1) == k ? "No space left on device" : real.call(*args) }) do
            _, notes = press(sb, -2)
            assert_equal 1, notes.size, "write #{k}"
          end
          assert_equal %w[beta gamma delta alpha], ws_names(built), "write #{k} failed"
        end
      end
    end

    # --- projects --------------------------------------------------------------------

    def with_projects
      web = temp_git_repo("web")
      write_config("projects" => [{ "name" => "app", "path" => @repo }, { "name" => "lib", "path" => path("lib") },
                                  { "name" => "web", "path" => web }])
      yield
    end

    def proj_names(sb) = rows_of(sb).select { |n| n.kind == "proj" }.map(&:project)

    # Value: protects=K on a header moves the project, config.yml is untouched, a hidden
    # project keeps its slot; fails_when=the move rewrites config or only visible names;
    # why_new=new action; seam=none
    def test_k_on_a_header_moves_the_project_and_leaves_config_alone
      with_projects do
        before = File.binread(Config.path)
        sb = built
        sb.instance_variable_set(:@cursor, rows_of(sb).index { |n| n.kind == "proj" && n.project == "web" })
        _, notes = press(sb, -1)
        assert_empty notes
        assert_equal %w[web app], proj_names(sb)
        assert_equal "web", current_node(sb).project
        assert_equal before, File.binread(Config.path)
        assert_equal %w[web lib app], ProjectOrder.names, "the hidden project keeps its slot"
        temp_git_repo("lib")
        assert_equal %w[web lib app], proj_names(built)
      end
    end

    # --- the other panes --------------------------------------------------------------

    # Value: protects=a background reload keeps a peer's selection on its workspace when
    # rows reorder under it; fails_when=the tick reload isn't wrapped; why_new=rows now move
    # under a pane; seam=none; no_claim=the real tick loop (the smoke test)
    def test_a_background_reload_keeps_the_selection_on_its_workspace
      with_times do
        sb = built
        on(sb, "gamma")
        sb.define_singleton_method(:reload) { |**| rebuild }
        Order.set(path("wt", "alpha"), 1000.0)
        sb.send(:reload_in_place)
        assert_equal %w[alpha beta gamma delta], ws_names(sb)
        assert_equal "gamma", current_node(sb).name
      end
    end
  end

  # The stores behind the order, on their own.
  class OrderStoresTest < SandboxTest
    def test_a_rank_round_trips_exactly
      dir = path("w")
      FileUtils.mkdir_p(dir)
      rank = 1_795_120_354.123456789
      assert_nil Order.set(dir, rank)
      assert_equal rank, Order.ranks[File.realpath(dir)]
    end

    # Value: protects=a rank that would break the end offsets is ignored; fails_when=only
    # finiteness is checked; why_new=new parser; seam=none
    def test_unusable_ranks_are_ignored
      dir = path("w")
      FileUtils.mkdir_p(dir)
      ["1e20", "-1", "NaN", "Infinity", "garbage", ""].each do |raw|
        KeyedMarkerStore.write(Order.state_dir, Order.key(dir), "#{dir}\t#{raw}")
        assert_empty Order.ranks, raw
      end
    end

    # Value: protects=a hand-made place survives a folder that is briefly gone; fails_when=
    # the GC is Dir.exist? alone; why_new=new store; seam=none; no_claim=a real unmount
    def test_a_missing_folder_keeps_its_rank_for_a_while
      Order.set(path("gone"), 5.0)
      assert_equal 1, Order.ranks.size
      file = Dir.glob(File.join(Order.state_dir, "*")).first
      File.utime(Time.now - Order::GC_AGE - 60, Time.now - Order::GC_AGE - 60, file)
      assert_empty Order.ranks
      refute File.exist?(file), "an old entry for a missing folder is collected"
    end

    def test_project_order_puts_listed_projects_first_and_ignores_unknown_names
      rows = %w[a b c d].map { |n| { "name" => n } }
      assert_equal %w[a b c d], ProjectOrder.sort(rows).map { |r| r["name"] }, "no file: config order"
      ProjectOrder.write(%w[c ghost a])
      assert_equal %w[c a b d], ProjectOrder.sort(rows).map { |r| r["name"] }
    end

    def test_a_failed_write_says_why
      FileUtils.mkdir_p(path("ro"))
      File.write(path("ro", "order"), "a file where the store's folder goes")
      ENV["SWITCHBOARD_ORDER_DIR"] = path("ro", "order", "inner")
      ENV["SWITCHBOARD_PROJECT_ORDER_FILE"] = path("ro", "order", "inner", "project_order")
      refute_nil Order.set(path("w"), 1.0)
      refute_nil ProjectOrder.write(%w[a])
      assert_nil KeyedMarkerStore.write(Order.state_dir, "k", "x"), "the forgiving write still returns nil"
      assert_empty Dir.glob(path("ro", "**", "*.tmp"))
    end

    # --- Git.created_at --------------------------------------------------------------

    def linked
      repo = temp_git_repo("app")
      git(repo, "worktree", "add", "-q", "-b", "w", path("w"))
      [repo, path("w")]
    end

    def test_created_at_reads_the_worktrees_admin_dir
      _, wt = linked
      admin = File.read(File.join(wt, ".git"))[/gitdir: (.+)/, 1].strip
      assert_in_delta File.birthtime(admin).to_f, Git.created_at(wt), 0.001
    rescue NotImplementedError
      skip "no birthtime here: the commondir test covers it"
    end

    def test_created_at_falls_back_to_commondir_without_birthtime
      _, wt = linked
      admin = File.read(File.join(wt, ".git"))[/gitdir: (.+)/, 1].strip
      stub_method(File, :birthtime, ->(*) { raise NotImplementedError }) do
        assert_in_delta File.mtime(File.join(admin, "commondir")).to_f, Git.created_at(wt), 0.001
      end
    end

    def test_created_at_resolves_a_relative_gitdir
      _, wt = linked
      admin = File.read(File.join(wt, ".git"))[/gitdir: (.+)/, 1].strip
      rel = Pathname.new(admin).relative_path_from(Pathname.new(File.realpath(wt))).to_s
      File.write(File.join(wt, ".git"), "gitdir: #{rel}\n")
      refute_nil Git.created_at(File.realpath(wt))
    end

    def test_created_at_is_nil_for_a_main_checkout_or_anything_unreadable
      repo, wt = linked
      assert_nil Git.created_at(repo), "a .git directory"
      assert_nil Git.created_at(path("nowhere"))
      File.write(File.join(wt, ".git"), "not a gitdir line\n")
      assert_nil Git.created_at(wt)
      File.write(File.join(wt, ".git"), "gitdir: #{path('missing-admin')}\n")
      assert_nil Git.created_at(wt)
    end
  end
end
