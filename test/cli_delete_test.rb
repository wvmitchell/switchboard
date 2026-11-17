# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # `switchboard delete`, over real temp repos and worktrees. Only tmux and the agent
  # process scan are stubbed (no server is running in the sandbox); git, the stores and the
  # receipts are real.
  class CliDeleteTest < SandboxTest
    def setup
      super
      @repo = temp_git_repo("app")
      @wt = path("worktrees", "app", "feat")
      FileUtils.mkdir_p(File.dirname(@wt))
      git(@repo, "worktree", "add", "-q", "-b", "feat", @wt)
      @real = File.realpath(@wt)
      write_config
    end

    def write_config(projects = [{ "name" => "app", "path" => @repo }])
      File.write(Config.path, YAML.dump("worktree_root" => path("worktrees"), "base" => "main", "projects" => projects))
    end

    # No tmux server, no agents, unless a test says otherwise.
    def quiet(sessions: [], agents: [], clients: [], &blk)
      stub_method(Tmux, :sessions_strict, -> { sessions }) do
        stub_method(Tmux, :session_panes, ->(_id) { [] }) do
          stub_method(Tmux, :session_clients, ->(_id) { clients }) do
            stub_method(Tmux, :kill_session_id, ->(_id) { true }) do
              stub_method(Agents, :scan, -> { agents }) { stub_method(Tmux, :broadcast_warm, ->(**) {}, &blk) }
            end
          end
        end
      end
    end

    def run_delete(*args, **stubs)
      CLI.instance_variable_set(:@config, nil)
      out = err = nil
      code = nil
      quiet(**stubs) { out, err = capture_io { code = CLI.delete(args) } }
      [code, out, err]
    end

    def listed?(path = @real)
      Git.worktrees(@repo, strict: true).any? { |w| Paths.real_or_self(w[:path]) == path }
    end

    def state_snapshot
      Dir.glob(path("**", "*"), File::FNM_DOTMATCH)
         .reject { |f| f.start_with?(@repo, @wt) || File.basename(f).start_with?("reserve-") }
         .to_h { |f| [f, File.file?(f) ? File.read(f) : :dir] }
    end

    def write_agent(state, cwd: @real, age: 0)
      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, cwd.sum.to_s), "#{state}\t#{cwd}\t#{Time.now.to_i - age}\n")
    end

    def record(**fields)
      rec = Creation.create(project: "app", name: "feat", path: @wt, task: "t", via: "cli")
      Creation.update(rec["id"], state: "turn_done", worktree_added: true, **fields)
    end

    # --- the delete ------------------------------------------------------------------

    # Value: protects=a delete leaves nothing switchboard owns; fails_when=any forget step
    # is skipped or runs before removal; why_new=new command; seam=tmux, agent scan
    def test_a_clean_workspace_is_deleted_with_everything_switchboard_kept_for_it
      Names.write(@real, "my-feat", project: "app", branch: "feat")
      Attention.mark(@wt)
      Notify.mark(@wt)
      SessionName::Outcome.record_real(@real, "ceiling", "x")
      write_agent("done")
      rec = record

      code, out, err = run_delete("my-feat")
      assert_equal 0, code, err
      refute File.exist?(@wt)
      refute listed?
      refute_includes git(@repo, "branch", "--list"), "feat"
      refute system("git", "-C", @repo, "config", "--get-regexp", "^branch\\.feat\\.", out: File::NULL), "its config section went too"
      assert_nil Names.read_all[1][@real]
      assert_nil Creation.find(rec["id"])
      assert_empty Attention.scan
      assert_empty Dir.children(AgentState.state_dir)
      assert_nil DeleteReceipt.read(@real)
      assert_empty PendingDelete.pending([@wt])
      assert_includes out, "removed: folder #{@real}"
      assert_includes out, "removed: branch feat"
    end

    # Value: protects=a badge the delete couldn't drop is reported and kept for prune;
    # fails_when=Pr.forget's result is ignored; why_new=D5's forget step; seam=Pr.forget
    def test_a_badge_that_cant_be_forgotten_is_partial
      code = out = err = nil
      stub_method(Pr, :forget, ->(*, **) { false }) { code, out, err = run_delete("feat") }
      assert_equal 7, code, out
      assert_match(/PR badges for feat/, err)
      refute File.exist?(@wt), "the folder still goes"
      refute_nil DeleteReceipt.read(@real), "the receipt stays so prune can finish"
    end

    # Value: protects=a refusal changes nothing, and --force passes the 5-class only;
    # fails_when=a check runs after a write; seam=none
    def test_a_dirty_tree_is_refused_without_changing_anything_and_force_passes_it
      File.write(File.join(@wt, "wip.txt"), "x")
      Attention.mark(@wt)
      before = state_snapshot
      code, _out, err = run_delete("feat")
      assert_equal 5, code
      assert_match(/\A\[dirty\] .*; changed: none; fix: commit or stash/, err)
      assert_includes err, "?? wip.txt"
      refute_includes err.lines.first, "use --force"
      assert_equal before, state_snapshot
      assert File.exist?(@wt)

      code, = run_delete("feat", "--force")
      assert_equal 0, code
      refute File.exist?(@wt)
    end

    def test_an_unpushed_commit_is_refused
      File.write(File.join(@wt, "a.txt"), "x")
      git(@wt, "add", "-A")
      git(@wt, "commit", "-q", "-m", "work")
      code, _out, err = run_delete("feat")
      assert_equal 5, code
      assert_match(/\A\[unpushed\] feat: 1 commit\(s\), tip \h{12}, on neither main nor a remote/, err)
    end

    # Value: protects=a detached HEAD's own commit isn't lost; fails_when=only planned branches
    # are counted; why_new=Git.worktrees drops HEAD; seam=none
    def test_a_detached_heads_unique_commit_is_unpushed
      git(@wt, "checkout", "-q", "--detach")
      File.write(File.join(@wt, "a.txt"), "x")
      git(@wt, "add", "-A")
      git(@wt, "commit", "-q", "-m", "detached work")
      code, _out, err = run_delete("feat")
      assert_equal 5, code
      assert_match(/\A\[unpushed\] HEAD: 1 commit/, err)
    end

    # Value: protects=a commit only the worktree's own history log reaches (a reset, a
    # detached commit left behind) isn't lost with its admin dir; fails_when=only branch
    # tips and HEAD are counted; why_new=pre-landing adversarial review; seam=none
    def test_a_commit_only_the_history_log_reaches_is_unpushed
      File.write(File.join(@wt, "w.txt"), "x")
      git(@wt, "add", "-A")
      git(@wt, "commit", "-q", "-m", "work")
      git(@wt, "reset", "-q", "--hard", "HEAD~1")
      code, _out, err = run_delete("feat")
      assert_equal 5, code
      assert_match(/\A\[unpushed\] 1 commit\(s\) only its history log \(reflog\) reaches/, err)
    end

    # Value: protects=a submodule's unpushed commit, kept in this worktree's admin dir, isn't
    # lost by the submodule retry; fails_when=the checks skip submodules; why_new=adversarial
    # review; seam=none
    def test_a_submodules_unpushed_commit_is_unpushed
      sub = temp_git_repo("sub")
      git(@wt, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "lib")
      git(@wt, "commit", "-q", "-m", "add sub")
      subdir = File.join(@wt, "lib")
      git(subdir, "config", "user.email", "t@e.com")
      git(subdir, "config", "user.name", "t")
      File.write(File.join(subdir, "s.txt"), "x")
      git(subdir, "add", "-A")
      git(subdir, "commit", "-q", "-m", "sub work")
      git(@wt, "add", "lib")
      git(@wt, "commit", "-q", "-m", "bump")
      origin = path("app-origin.git")
      git(nil, "init", "-q", "--bare", origin)
      git(@repo, "remote", "add", "origin", origin)
      git(@wt, "push", "-q", "origin", "feat")
      code, _out, err = run_delete("feat")
      assert_equal 5, code
      assert_match(/in its submodules are on none of their remotes/, err)
    end

    # Value: protects=a live workspace is never shadowed by an old receipt that shares its
    # name; fails_when=receipts are matched before resolution; why_new=adversarial review
    def test_a_stale_receipt_never_shadows_a_live_workspace
      other = path("worktrees", "app", "old")
      DeleteReceipt.write({ "path" => other, "real" => other, "project" => "app", "repo" => @repo, "name" => "feat",
                            "record" => nil, "branches" => [], "phase" => "removed", "deleted" => [] }.merge(DeleteReceipt.owner(dead_pid)))
      code, _out, err = run_delete("feat")
      assert_equal 0, code, err
      refute listed?
      code, out, = run_delete("old")
      assert_equal 0, code
      assert_includes out, "removed: folder #{other}"
      assert_nil DeleteReceipt.read(other)
    end

    def test_resolution_tokens
      assert_equal [4, "[primary]"], run_delete("app").values_at(0, 2).then { |c, e| [c, e[/\A\[\w+\]/]] }
      assert_equal 1, run_delete("nope").first
      other = temp_git_repo("other")
      owt = path("worktrees", "other", "feat")
      git(other, "worktree", "add", "-q", "-b", "feat", owt)
      write_config([{ "name" => "app", "path" => @repo }, { "name" => "other", "path" => other }])
      code, _out, err = run_delete("feat")
      assert_equal 2, code
      assert_includes err, "app/feat"
      assert_equal 0, run_delete("other/feat").first
    end

    def test_usage_errors_exit_64
      assert_equal 64, run_delete.first
      assert_equal 64, run_delete("feat", "--bogus").first
      assert_equal 64, run_delete("--creation").first
      code, _out, err = run_delete("--creation", "../x")
      assert_equal 64, code
      assert_match(/\A\[usage\]/, err)
    end

    # Value: protects=a listing that failed can't turn an ambiguous name into a unique one;
    # fails_when=delete resolves from the lenient listing; seam=Git.worktrees
    def test_a_failed_listing_refuses
      real = Git.method(:worktrees)
      stub_method(Git, :worktrees, ->(repo, strict: false) { strict ? nil : real.call(repo) }) do
        assert_equal 4, run_delete("feat").first
      end
    end

    # --- --creation ------------------------------------------------------------------

    def stamp(rec)
      token = Creator.stamp_generation(rec["id"], @wt)[:token]
      Creation.update(rec["id"], token: token)
    end

    # Value: protects=--creation deletes only the tree its record built; fails_when=a
    # record's path alone authorizes, or a token-less record falls back to the name;
    # why_new=new flag; seam=none
    def test_creation_requires_the_records_own_tree
      rec = record
      code, _out, err = run_delete("--creation", rec["id"])
      assert_equal 4, code
      assert_match(/\A\[not-yours\] record \S+ predates delete --creation; .*fix: ask a human/, err)

      stamp(rec)
      assert_equal 4, run_delete("--creation", "20990101000000-abcdef").first
      assert_equal 0, run_delete("--creation", rec["id"]).first
      refute File.exist?(@wt)
    end

    def test_a_tree_recreated_at_the_same_path_fails_the_token
      rec = stamp(record)
      git(@repo, "worktree", "remove", "--force", @wt)
      git(@repo, "worktree", "add", "-q", @wt, "feat")
      code, _out, err = run_delete("--creation", rec["id"])
      assert_equal 4, code
      assert_includes err, "isn't the tree record"
    end

    def test_a_record_still_building_or_from_another_server_refuses
      rec = record
      Creation.update(rec["id"], state: "building")
      assert_equal "[building]", run_delete("feat")[2][/\A\[[\w-]+\]/]
      Creation.update(rec["id"], state: "turn_done", server: "/tmp/tmux-1/other")
      assert_equal "[other-server]", run_delete("feat")[2][/\A\[[\w-]+\]/]
    end

    # --- busy --------------------------------------------------------------------------

    # Value: protects=an agent still working, or a person attached, isn't deleted from under
    # them, while an idle agent doesn't block the monitor; fails_when=any busy signal is
    # dropped or an idle one counts; why_new=new check; seam=Agents.scan, tmux clients
    def test_busy_signals
      write_agent("thinking")
      assert_match(/\A\[busy\] .*an agent is thinking/, run_delete("feat")[2])

      write_agent("done")
      assert_equal 0, run_delete("feat", "-n", agents: [@real]).first, "an idle agent at its prompt isn't busy"

      FileUtils.rm_rf(AgentState.state_dir)
      assert_match(/no fresh idle state/, run_delete("feat", agents: [File.join(@real, "sub")])[2])
      assert_match(/couldn't scan/, run_delete("feat", agents: nil)[2])

      session = { id: "$1", name: "sb/app/feat", path: @wt }
      assert_match(/client \/dev\/ttys009 attached/, run_delete("feat", sessions: [session], clients: ["/dev/ttys009"])[2])
      calls = 0
      CLI.instance_variable_set(:@config, nil)
      code = nil
      order = []
      quiet(clients: ["/dev/ttys009"]) do
        stub_method(Tmux, :sessions_strict, -> { (calls += 1) == 1 ? [session] : [] }) do
          stub_method(Tmux, :send_clients_home, ->(id) { order << [:home, id] }) do
            stub_method(Tmux, :kill_session_id, ->(id) { order << [:kill, id] }) { capture_io { code = CLI.delete(%w[feat --force]) } }
          end
        end
      end
      assert_equal 0, code, "a human's --force passes busy"
      assert_equal [[:home, "$1"], [:kill, "$1"]], order, "the attached client goes home before the kill"
    end

    def test_inside_by_cwd
      Dir.chdir(@wt) { assert_match(/\A\[inside\]/, run_delete("feat")[2]) }
    end

    def test_tmux_that_cant_be_asked_refuses
      assert_match(/\A\[tmux-unknown\]/, run_delete("feat", sessions: nil)[2])
    end

    # --- dry run, receipts --------------------------------------------------------------

    def test_a_dry_run_changes_nothing_and_exits_as_the_real_run_would
      PendingDelete.mark("/elsewhere") # unrelated and stale: a dry run must not collect it
      marker = File.join(PendingDelete.state_dir, PendingDelete.key("/elsewhere"))
      File.utime(Time.now - 3600, Time.now - 3600, marker)
      before = state_snapshot
      code, out, = run_delete("feat", "-n")
      assert_equal 0, code
      assert_includes out, "would remove: folder #{@real}"
      assert_includes out, "would remove: branch feat"
      assert_equal before, state_snapshot
      assert File.exist?(marker)
    end

    def live_receipt(pid: Process.pid, phase: "claimed")
      r = { "path" => @wt, "real" => @real, "project" => "app", "repo" => @repo, "name" => "feat", "record" => nil,
            "branches" => ["#{git(@repo, 'rev-parse', 'feat').strip}:feat"], "phase" => phase, "deleted" => [] }
      DeleteReceipt.write(r.merge(DeleteReceipt.owner(pid)))
      r
    end

    def dead_pid
      pid = Process.spawn("true")
      Process.wait(pid)
      pid
    end

    # Value: protects=two deletes never run at once, and rename can't race one; fails_when=
    # the receipt isn't checked; why_new=receipts are the per-workspace lock; seam=none
    def test_a_live_receipt_refuses_delete_dry_run_and_rename
      live_receipt
      assert_match(/\A\[deleting\]/, run_delete("feat")[2])
      assert_match(/\A\[deleting\]/, run_delete("feat", "-n")[2])
      assert_equal :deleting, Rename.name_it(Config.new, "app", @wt, "other").status
    end

    # Value: protects=an interrupted delete is finished from its receipt once git no longer
    # lists the folder, and re-checked in full while it still does; fails_when=resume trusts
    # the stored phase; why_new=receipt recovery; seam=none
    def test_a_dead_owners_receipt_is_resumed_from_the_listing
      live_receipt(pid: dead_pid)
      session = { id: "$1", name: "sb/app/feat", path: @wt }
      assert_match(/\A\[busy\]/, run_delete("feat", sessions: [session], clients: ["c"])[2], "still listed: full preflight")

      live_receipt(pid: dead_pid, phase: "session_closed")
      git(@repo, "worktree", "remove", @wt)
      code, out, err = run_delete("feat")
      assert_equal 0, code, err
      assert_includes out, "removed: branch feat"
      assert_nil DeleteReceipt.read(@real)
    end

    # Value: protects=a receipt is never finished while its own repo still lists the tree,
    # even when that repo isn't a registered project; fails_when=resume trusts the registered
    # listings; why_new=pre-landing review; seam=none
    def test_resume_asks_the_receipts_own_repo
      Names.write(@real, "kept-name", project: "app", branch: "feat")
      live_receipt(pid: dead_pid)
      write_config([])
      code, _out, err = run_delete("feat")
      assert_equal 4, code
      assert_match(/\A\[listing-failed\] can't confirm git no longer lists/, err)
      assert Names.read_all[1].key?(@real), "nothing was forgotten"
      assert File.exist?(@wt)
    end

    def test_prune_finishes_a_dead_owners_receipt_whose_folder_is_gone
      live_receipt(pid: dead_pid, phase: "removed")
      git(@repo, "worktree", "remove", @wt)
      quiet { assert_equal 1, Leftovers.clear(Config.new)[:delete_receipt] }
      assert_nil DeleteReceipt.read(@real)
      refute_includes git(@repo, "branch", "--list"), "feat"
    end

    def test_doctor_names_an_interrupted_delete_still_listed
      live_receipt(pid: dead_pid)
      out = capture_io { Doctor.doctor_leftovers(Config.new) }.first
      assert_includes out, "interrupted delete of #{@wt} — run `switchboard delete app/feat` to finish it"
    end

    # --- after the session closes -------------------------------------------------------

    # Value: protects=a file written between preflight and removal is caught, and the
    # workspace still shows; fails_when=the post-close re-check goes; seam=kill_session_id
    def test_a_change_after_preflight_stops_the_delete
      session = { id: "$1", name: "sb/app/feat", path: @wt }
      wt = @wt # the stub runs with Tmux as self
      write = ->(_id) { File.write(File.join(wt, "late.txt"), "x") }
      code = err = nil
      CLI.instance_variable_set(:@config, nil)
      seen = 0
      stub_method(Tmux, :sessions_strict, -> { (seen += 1) == 1 ? [session] : [] }) do
        stub_method(Tmux, :session_panes, ->(_id) { [] }) do
          stub_method(Tmux, :session_clients, ->(_id) { [] }) do
            stub_method(Tmux, :kill_session_id, write) do
              stub_method(Agents, :scan, -> { [] }) do
                _out, err = capture_io { code = CLI.delete(["feat"]) }
              end
            end
          end
        end
      end
      assert_equal 8, code
      assert_match(/\A\[changed-during-delete\]/, err)
      assert File.exist?(@wt)
      assert_empty PendingDelete.pending([@wt])
      assert_nil DeleteReceipt.read(@real)
    end

    def test_a_session_that_wont_die_stops_before_the_folder
      session = { id: "$1", name: "sb/app/feat", path: @wt }
      code, _out, err = run_delete("feat", sessions: [session])
      assert_equal 8, code
      assert_match(/\A\[session-alive\]/, err)
      assert File.exist?(@wt)
    end

    def test_an_unexpected_error_is_failed_with_a_trace
      code = err = nil
      CLI.instance_variable_set(:@config, nil)
      quiet do
        stub_method(Git, :status_lines, ->(*) { raise "boom" }) do
          _out, err = capture_io { code = CLI.delete(["feat"]) }
        end
      end
      assert_equal 70, code
      assert_match(/\A\[failed\] unexpected error: boom; .*trace: (\S+)/, err)
      assert File.exist?(err[/trace: (\S+) \(/, 1])
    end

    # Value: protects=every stderr line agents parse has the same shape; fails_when=a token
    # drops a part; seam=none
    def test_message_shape
      line = Deletion.message(Deletion.refuse("dirty", "x\e[31m", fix: "y")).first
      assert_equal "[dirty] x\\x1b[31m; changed: none; fix: y (reference-cli.md#delete-dirty)", line
    end
  end
end
