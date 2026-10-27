# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Rename.perform end-to-end against real throwaway worktrees (the move + bridge
  # are real git; the tmux session rename is the one stubbed seam). The shared
  # core behind both the sidebar `r` key and `switchboard rename` (issue #42).
  class RenameTest < SandboxTest
    # Config registering `proj` -> a real repo.
    def config_for(repo)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      Config.new
    end

    # A linked worktree at wts/proj/<leaf> off `repo` (returns its path).
    def add_worktree(repo, leaf, branch: leaf)
      dest = path("wts", "proj", leaf)
      git(repo, "worktree", "add", "-q", dest, "-b", branch)
      dest
    end

    def test_perform_moves_the_dir_and_leaves_a_bridge
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "new")

      assert_equal :ok, result.status
      dest = path("wts", "proj", "new")
      assert_equal dest, result.dest
      assert File.directory?(dest)
      assert File.symlink?(old), "a bridge symlink is left at the old path"
      assert_equal File.realpath(dest), File.realpath(old), "the bridge resolves to the new dir"
    end

    # The whole point of the rename surviving a restart: Claude's transcript dir,
    # keyed by the (now-changed) cwd, is carried to the new path so `/resume` finds
    # it (issue #42 follow-up).
    def test_perform_carries_the_claude_history_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      # Claude keys by the canonicalized cwd; the worktree is real here, so on macOS
      # (/var -> /private/var) the raw sandbox path and Claude's key differ — seed at
      # the realpath key the running agent actually wrote under.
      hist = File.join(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"], ClaudeHistory.encode(File.realpath(old)))
      FileUtils.mkdir_p(hist)
      File.write(File.join(hist, "s1.jsonl"), "turn\n")

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      dest_hist = File.join(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"],
                            ClaudeHistory.encode(File.realpath(path("wts", "proj", "new"))))
      assert File.exist?(File.join(dest_hist, "s1.jsonl")), "the transcript moved to the new key"
    end

    # A rename carries the background-monitor ∞ marker to the new realpath (the key is
    # the realpath, which the dir move changes). The old path is captured BEFORE the move
    # because the bridge symlink resolves it to the new dir afterward.
    def test_perform_carries_the_monitoring_marker_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      Monitoring.mark(File.realpath(old))

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      new = File.realpath(path("wts", "proj", "new"))
      assert_includes Monitoring.monitored([new]), new, "the ∞ marker followed the rename"
    end

    # Value: protects=a ◷ chime held across a rename still rings for the renamed workspace;
    # fails_when=Rename.perform stops calling OffstageHold.carry (the hold stays keyed by the
    # old realpath and no lookup of the new path ever finds it — the chime is lost); why_new=
    # only OffstageHold.carry itself was tested, not perform's wiring; seam=none
    def test_perform_carries_a_held_offstage_chime_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      OffstageHold.hold(File.realpath(old), pid: 4242)

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      new = File.realpath(path("wts", "proj", "new"))
      assert_equal({ new => 4242 }, OffstageHold.held([new]).transform_values { _1[:pid] }, "the hold followed the rename")
    end

    # The same shared carry fixes Attention's latent bug: a rename used to silently drop
    # an unviewed completion's bold.
    def test_perform_carries_the_attention_bold_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      Attention.mark(File.realpath(old))

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      new = File.realpath(path("wts", "proj", "new"))
      assert_includes Attention.marked([new]), new, "the bold followed the rename"
    end

    # A dispatched agent that renames its workspace on turn one must still get its
    # first-turn ping: the Creation record follows the dir, so the Stop hook (whose cwd
    # resolves to the new dir) and the sidebar's ack still find it.
    def test_perform_carries_the_dispatch_record_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      rec = Creation.create(project: "proj", name: "old", path: old, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :ready) # the agent is running

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      found = Creation.find(rec["id"])
      assert_equal "new", found["name"]
      assert_equal rec["id"], Creation.for_path(path("wts", "proj", "new"))["id"]
    end

    # Once the agent has started (still inside the launch grace) it may run its own
    # first-turn rename: allowed, and the record follows the dir so the Stop through the
    # old (bridged) path still stamps its ping. Before that — setup running — refused.
    def test_perform_renames_once_the_agent_started_and_the_stop_still_lands
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      rec = Creation.create(project: "proj", name: "old", path: old, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true)
      assert_equal :building, Rename.perform(config_for(repo), "proj", old, "new").status, "setup still running"
      Creation.update(rec["id"], agent_started: true)
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      found = Creation.for_path(old) # the old path is now a bridge to the new dir
      assert_equal rec["id"], found["id"]
      Creation.stamp_first_turn(found["id"])
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
    end

    # While the worker still holds the old path (its session + launch line aren't made
    # yet), a rename would orphan that session and start a second agent later.
    def test_perform_refuses_while_the_workspace_is_still_building
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      %i[queued building].each do |state|
        rec = Creation.create(project: "proj", name: "old", path: old, task: "")
        Creation.transition(rec["id"], from: :queued, to: state) unless state == :queued
        assert_equal :building, Rename.perform(config_for(repo), "proj", old, "new").status, "rename from #{state}"
        assert File.directory?(old), "nothing moved"
        Creation.delete(rec["id"])
      end
    end

    def test_perform_unknown_project_is_failed
      config = config_for(temp_git_repo("proj"))
      assert_equal :failed, Rename.perform(config, "nope", path("x"), "new").status
    end

    def test_perform_blank_name_is_invalid
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "..").status # sanitizes to ""
      assert File.directory?(old), "no move on an invalid name"
    end

    # Agents type branch-style names; a "/" the sanitizer preserves would nest the
    # dir while the session/leaf see only the basename, so rename rejects it.
    def test_perform_rejects_a_slash_in_the_name
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "feature/auth").status
      assert File.directory?(old), "no move on a slashed name"
    end

    def test_perform_rename_to_the_same_name_is_unchanged
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :unchanged, Rename.perform(config_for(repo), "proj", old, "old").status
      assert File.directory?(old)
    end

    def test_perform_real_dir_collision_is_exists
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      FileUtils.mkdir_p(path("wts", "proj", "taken"))
      assert_equal :exists, Rename.perform(config_for(repo), "proj", old, "taken").status
      assert File.directory?(old), "no move onto a real dir"
    end

    # A stale rename-bridge squatting the target must not block the move.
    def test_perform_clears_a_stale_bridge_at_the_target
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      other = add_worktree(repo, "other", branch: "other")
      File.symlink(other, path("wts", "proj", "dest"))
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "dest").status
      assert File.directory?(path("wts", "proj", "dest"))
    end

    def test_perform_move_failure_is_failed
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Git, :move_worktree, ->(*, **) { false }) do
        assert_equal :failed, Rename.perform(config, "proj", old, "new").status
      end
    end

    def test_perform_renames_the_session_with_sanitized_leaf_names
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      seen = []
      stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(o, n) { seen << [o, n]; true }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "new").status
        end
      end
      assert_equal [["sb/proj/old", "sb/proj/new"]], seen
    end

    # Dir moved but a *reachable* session's rename failed -> :partial (recoverable;
    # prune reaps the orphan), distinct from a clean :ok.
    def test_perform_is_partial_when_a_live_session_rename_fails
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(*) { false }) do
          assert_equal :partial, Rename.perform(config, "proj", old, "new").status
        end
      end
      assert File.directory?(path("wts", "proj", "new")), "the dir still moved on :partial"
    end

    # No live session (clientless rename from a plain shell) is not a failure.
    def test_perform_is_ok_when_no_session_exists
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      stub_method(Tmux, :has_session?, ->(_) { false }) do
        assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      end
    end

    # A case-only rename (Old -> old) must NOT misreport as :exists/:failed. On a
    # case-insensitive FS (macOS) the two names are the same dir -> :unchanged; on a
    # case-sensitive FS they're distinct -> a real :ok move. Either is honest; the
    # regression (caught in review) was the bogus :exists the old File.exist? guard
    # produced on macOS.
    def test_perform_handles_a_case_only_rename_without_a_false_collision
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "Old")
      result = Rename.perform(config_for(repo), "proj", old, "old")
      assert_includes %i[ok unchanged], result.status,
                      "a case-only rename is not a collision or a failure"
    end

    # foo.bar and foo-bar both sanitize to the session sb/proj/foo-bar, so the dir
    # moves (dest != old_path) but the session names collapse equal — no tmux call.
    def test_perform_skips_session_rename_when_names_collapse_equal
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "foo.bar")
      config = config_for(repo)
      stub_method(Tmux, :has_session?, ->(*) { flunk "no session check when names collapse" }) do
        stub_method(Tmux, :rename_session, ->(*) { flunk "no rename when names collapse" }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "foo-bar").status
        end
      end
      assert File.directory?(path("wts", "proj", "foo-bar"))
    end

    # --- branch sync (#94) ---------------------------------------------------

    # When the branch is unpushed and still matches the leaf, rename renames it too,
    # so the dir and branch stay in step (the whole point of #94).
    def test_perform_syncs_the_branch_when_unpushed_and_in_sync
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old") # branch "old" == leaf, no remote
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert_equal "new", Git.current_branch(path("wts", "proj", "new"))
      refute Git.branch_exists?(repo, "old"), "the old branch name is gone"
    end

    # The branch adopts the CURRENT branch_prefix on rename (prefix drift): a bare
    # "old" branch becomes "wv/new".
    def test_perform_applies_the_branch_prefix
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "branch_prefix" => "wv",
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      assert_equal :ok, Rename.perform(Config.new, "proj", old, "new").status
      assert_equal "wv/new", Git.current_branch(path("wts", "proj", "new"))
    end

    # A pushed branch is left intact (renaming it would orphan its remote ref / PR),
    # but the dir still moves.
    def test_perform_leaves_a_pushed_branch
      repo = temp_git_repo("proj", origin: true)
      old = path("wts", "proj", "old")
      git(repo, "worktree", "add", "--no-track", "-q", "-b", "old", old, "origin/main")
      git(old, "push", "-q", "origin", "old") # offline push to the local bare origin
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert File.directory?(path("wts", "proj", "new")), "dir still moves"
      assert Git.branch_exists?(repo, "old"), "the pushed branch is left intact"
    end

    # A branch the user switched away from the leaf is left alone (dir-only rename).
    def test_perform_leaves_a_diverged_branch
      repo = temp_git_repo("proj")
      old = path("wts", "proj", "old")
      git(repo, "worktree", "add", "-q", "-b", "feature-x", old) # branch != leaf
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert Git.branch_exists?(repo, "feature-x"), "a diverged branch is left alone"
      refute Git.branch_exists?(repo, "new")
    end

    # A lingering branch at the target name ⇒ :branch_exists, and NOTHING moves
    # (atomic-ish: the agent retries with a new name; no dir≠branch divergence).
    def test_perform_branch_exists_moves_nothing
      repo = temp_git_repo("proj")
      git(repo, "branch", "new") # a lingering branch from a deleted workspace
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "new")
      assert_equal :branch_exists, result.status
      refute File.symlink?(old), "no bridge — the move never happened"
      refute File.exist?(path("wts", "proj", "new")), "dest not created"
      assert Git.branch_exists?(repo, "old"), "the old branch is untouched"
    end

    # A name git rejects as a branch fails clean before any move (when syncing).
    def test_perform_invalid_branch_name_moves_nothing
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "x.lock") # sanitizes ok, bad ref
      assert_equal :invalid, result.status
      refute File.exist?(path("wts", "proj", "x.lock")), "nothing moved"
      assert Git.branch_exists?(repo, "old")
    end

    # --- the session-name worker spawn (SessionName) ---

    # Records spawns instead of running them; TMUX points at a socket that doesn't exist,
    # so the session-rename shell-out finds no server.
    def spawns_for(env: { "TMUX" => path("no-server,1,0"), "SWITCHBOARD_BIN" => "/sb/bin/switchboard" })
      spawned = []
      env.each { |k, v| ENV[k] = v }
      stub_method(Process, :spawn, ->(*args) { spawned << args.first(4) && 4242 }) do
        stub_method(Process, :detach, ->(_) {}) { @result = yield }
      end
      spawned
    end

    # Value: protects=offline tests never launch the installed switchboard; fails_when=the
    # TMUX gate is removed; why_new=D7; seam=none
    def test_a_rename_outside_tmux_spawns_no_worker
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      spawned = spawns_for(env: { "SWITCHBOARD_BIN" => "/sb/bin/switchboard" }) { Rename.perform(config_for(repo), "proj", old, "new") }
      assert_empty spawned
      refute @result.spawned
    end

    def test_a_rename_inside_tmux_spawns_one_worker_for_the_new_leaf
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      spawned = spawns_for { Rename.perform(config_for(repo), "proj", old, "new") }
      assert_equal [["/sb/bin/switchboard", "sync-session-name", path("wts", "proj", "new"), "new"]], spawned
      assert @result.spawned
    end

    # Value: protects=the hour-long worker holds none of the rename's stdio and has its own group,
    # so an agent's Bash tool returns at once and can't kill it; fails_when=out/err/in or pgroup are
    # dropped from the spawn; why_new=spawns_for keeps only argv; seam=none; no_claim=real tool-runner pipes (spawn stubbed)
    def test_the_worker_is_spawned_detached_from_the_renames_stdio_and_group
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      ENV["TMUX"] = path("no-server,1,0")
      ENV["SWITCHBOARD_BIN"] = "/sb/bin/switchboard"
      opts = nil
      stub_method(Process, :spawn, ->(*_args, **o) { (opts = o) && 4242 }) do
        stub_method(Process, :detach, ->(_) {}) { Rename.perform(config_for(repo), "proj", old, "new") }
      end
      assert_equal({ pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL }, opts)
    end

    def test_the_knob_off_spawns_no_worker
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "proj", "path" => repo, "sync_session_name" => false }]))
      assert_empty(spawns_for { Rename.perform(Config.new, "proj", old, "new") })
    end

    def test_a_failed_rename_spawns_no_worker
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      add_worktree(repo, "taken")
      assert_empty(spawns_for { Rename.perform(config_for(repo), "proj", old, "taken") })
      assert_equal :exists, @result.status
    end

    # D12: renaming to the same name is the retry doctor points at.
    def test_a_same_name_rename_spawns_a_retry
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "same")
      spawned = spawns_for { Rename.perform(config_for(repo), "proj", old, "same") }
      assert_equal :unchanged, @result.status
      assert_equal [["/sb/bin/switchboard", "sync-session-name", old, "same"]], spawned
    end

    # Value: protects=a rename still succeeds when the worker can't be launched; fails_when=
    # the SystemCallError rescue or the SWITCHBOARD_BIN guard is dropped; why_new=spawn was
    # always stubbed to succeed; seam=none; no_claim=a real missing binary (Process.spawn stubbed)
    def test_an_unlaunchable_worker_leaves_the_rename_intact
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      ENV["TMUX"] = path("no-server,1,0")
      ENV.delete("SWITCHBOARD_BIN")
      result = Rename.perform(config_for(repo), "proj", old, "new")
      refute result.spawned, "no SWITCHBOARD_BIN, no worker"
      ENV["SWITCHBOARD_BIN"] = "/gone/switchboard"
      result = stub_method(Process, :spawn, ->(*) { raise Errno::ENOENT }) do
        Rename.perform(config_for(repo), "proj", path("wts", "proj", "new"), "newer")
      end
      assert_equal path("wts", "proj", "newer"), result.dest
      refute result.spawned
      assert File.directory?(path("wts", "proj", "newer"))
    end

    def test_a_rename_clears_the_old_names_sync_outcome
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      SessionName::Outcome.record(old, :ceiling, "old")
      Rename.perform(config_for(repo), "proj", old, "new")
      assert_empty SessionName::Outcome.all
    end

    def test_a_rename_forgets_even_a_failed_send_the_new_worker_judges_afresh
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      SessionName::Outcome.record(old, :failed_send, "old")
      Rename.perform(config_for(repo), "proj", old, "new")
      assert_empty SessionName::Outcome.all
    end

    # Value: protects=no notice promises a rename the worker will refuse; fails_when=a leaf the
    # worker's NAME rejects still spawns; why_new=pass-2 red team; seam=none
    def test_a_leaf_the_worker_would_refuse_spawns_nothing
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old", branch: "feature-x") # branch left alone: a dir-only rename
      assert_empty(spawns_for { Rename.perform(config_for(repo), "proj", old, "-dash") })
      assert_equal :ok, @result.status
      refute @result.spawned
    end

    def test_a_case_only_rename_syncs_the_name_the_dir_keeps
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "Mixed")
      skip "case-sensitive filesystem" unless File.identical?(old, path("wts", "proj", "mixed"))
      spawned = spawns_for { Rename.perform(config_for(repo), "proj", old, "mixed") }
      assert_equal :unchanged, @result.status
      assert_equal [["/sb/bin/switchboard", "sync-session-name", old, "Mixed"]], spawned
    end

    # Value: protects=renaming back onto your own bridge moves the dir; fails_when=the identical
    # check follows the bridge and reports :unchanged; why_new=run-2 native adversarial; seam=none
    def test_renaming_back_onto_the_bridge_of_an_earlier_rename_moves_the_dir
      repo = temp_git_repo("proj")
      a = add_worktree(repo, "first")
      config = config_for(repo)
      assert_equal :ok, Rename.perform(config, "proj", a, "second").status
      b = path("wts", "proj", "second")
      result = Rename.perform(config, "proj", b, "first")
      assert_equal :ok, result.status
      assert File.directory?(a) && !File.symlink?(a), "the dir is back at its first name"
    end

    def test_a_partial_rename_still_spawns_and_an_invalid_one_does_not
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      spawned = stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(*) { false }) { spawns_for { Rename.perform(config_for(repo), "proj", old, "new") } }
      end
      assert_equal :partial, @result.status
      assert_equal 1, spawned.size
      assert_empty(spawns_for { Rename.perform(config_for(repo), "proj", path("wts", "proj", "new"), "a/b") })
      assert_equal :invalid, @result.status
      assert_empty(spawns_for { Rename.perform(config_for(repo), "nope", path("wts", "proj", "new"), "x") })
      assert_equal :failed, @result.status
    end
  end
end
