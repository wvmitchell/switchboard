# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Rename.perform end-to-end against real throwaway worktrees and a real names store; tmux
  # is the stubbed seam. The shared core behind both the sidebar `r` key and `switchboard
  # rename`. The folder never moves: every agent keys its history by the cwd.
  class RenameTest < SandboxTest
    # Config registering `proj` -> a real repo.
    def config_for(repo, **extra)
      File.write(Config.path, YAML.dump({ "worktree_root" => path("wts"),
                                          "projects" => [{ "name" => "proj", "path" => repo }] }.merge(extra)))
      Config.new
    end

    # A linked worktree at wts/proj/<leaf> off `repo` (returns its path).
    def add_worktree(repo, leaf, branch: leaf)
      dest = path("wts", "proj", leaf)
      git(repo, "worktree", "add", "-q", dest, "-b", branch)
      dest
    end

    def name_of(dir) = Worktree.new(project: "proj", path: dir).display_name

    # Value: protects=the whole design: a rename changes the name, never the path, so every
    # agent's history (keyed by the cwd) stays put; fails_when=the folder moves or the name
    # isn't stored; seam=none
    def test_perform_names_the_workspace_without_moving_its_folder
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "gentle-lantern-3f9a")
      result = Rename.perform(config_for(repo), "proj", old, "oauth-fix")

      assert_equal :ok, result.status
      assert_equal old, result.dest, "dest is the unchanged path"
      assert_equal "oauth-fix", result.name
      assert File.directory?(old) && !File.symlink?(old), "the folder stays a real dir where it was"
      refute File.exist?(path("wts", "proj", "oauth-fix")), "no folder is created for the name"
      assert_equal "oauth-fix", name_of(old)
      assert_equal ["gentle-lantern-3f9a"], git(repo, "worktree", "list", "--porcelain").scan(%r{wts/proj/([^\n]+)}).flatten
    end

    def test_renaming_back_to_the_folder_name_drops_the_stored_name
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "calm-fern-0a1b")
      config = config_for(repo)
      Rename.perform(config, "proj", old, "first")
      assert_equal :ok, Rename.perform(config, "proj", old, "calm-fern-0a1b").status
      assert_empty Names.read_all.last, "no entry: the name is the folder's again"
      assert_equal "calm-fern-0a1b", name_of(old)
    end

    # A dispatched agent that renames its workspace on turn one keeps its first-turn ping:
    # nothing about the record's path changes.
    def test_perform_renames_once_the_agent_started_and_the_stop_still_lands
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      rec = Creation.create(project: "proj", name: "old", path: old, task: "do it")
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true)
      assert_equal :building, Rename.perform(config_for(repo), "proj", old, "new").status, "setup still running"
      Creation.update(rec["id"], agent_started: true)
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      found = Creation.for_path(old)
      assert_equal rec["id"], found["id"]
      Creation.stamp_first_turn(found["id"])
      assert_equal "turn_done", Creation.find(rec["id"])["state"]
    end

    # While the worker still computes its session name, a rename would split the session
    # from the build.
    def test_perform_refuses_while_the_workspace_is_still_building
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      %i[queued building].each do |state|
        rec = Creation.create(project: "proj", name: "old", path: old, task: "")
        Creation.transition(rec["id"], from: :queued, to: state) unless state == :queued
        assert_equal :building, Rename.perform(config_for(repo), "proj", old, "new").status, "rename from #{state}"
        assert_equal "old", name_of(old), "nothing changed"
        Creation.delete(rec["id"])
      end
    end

    def test_perform_unknown_project_is_failed
      config = config_for(temp_git_repo("proj"))
      assert_equal :failed, Rename.perform(config, "nope", path("x"), "new").status
    end

    def test_perform_rejects_a_blank_or_slashed_name
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "..").status # sanitizes to ""
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "feature/auth").status
      assert_equal "old", name_of(old)
    end

    def test_perform_rename_to_the_current_name_is_unchanged
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      assert_equal :unchanged, Rename.perform(config, "proj", old, "old").status
      Rename.perform(config, "proj", old, "named")
      assert_equal :unchanged, Rename.perform(config, "proj", old, "named").status
    end

    # --- what's taken --------------------------------------------------------------

    # Value: protects=no two workspaces in a project ever share a session name; fails_when=
    # any uniqueness source is skipped or compared unsanitized; seam=Tmux.sessions
    def test_a_name_held_anywhere_in_the_project_is_exists_and_changes_nothing
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      other = add_worktree(repo, "other")
      config = config_for(repo)
      Rename.perform(config, "proj", other, "oauth-fix")
      Creation.create(project: "proj", name: "pending-name", path: path("wts", "proj", "pending-name"), task: "")
      live = [{ name: "sb/proj/loose-session", created: 1, path: path("elsewhere") }]
      stub_method(Tmux, :sessions, -> { live }) do
        { "oauth-fix" => "workspace oauth-fix", "oauth.fix" => "workspace oauth-fix", "other" => "the folder",
          "pending-name" => "a build in progress", "loose-session" => "the tmux session sb/proj/loose-session" }.each do |name, why|
          result = Rename.perform(config, "proj", old, name)
          assert_equal :exists, result.status, name
          assert_includes result.detail, why, name
        end
      end
      assert_equal "old", name_of(old)
      assert Git.branch_exists?(repo, "old"), "the branch is untouched"
    end

    def test_two_concurrent_renames_to_one_name_have_exactly_one_winner
      repo = temp_git_repo("proj")
      a = add_worktree(repo, "a")
      b = add_worktree(repo, "b")
      config = config_for(repo)
      results = [a, b].map { |dir| Thread.new { Rename.perform(config, "proj", dir, "shared").status } }.map(&:value)
      assert_equal %i[exists ok], results.sort
    end

    # --- sessions -------------------------------------------------------------------

    # Value: protects=the live session follows the name in place (a running agent survives),
    # found by the folder it was created in; fails_when=it's looked up by the computed name or
    # killed; seam=Tmux.sessions/rename_session
    def test_perform_renames_the_folders_live_session_in_place
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      seen = []
      live = [{ name: "sb/proj/stale-name", created: 1, path: old }]
      stub_method(Tmux, :sessions, -> { live }) do
        stub_method(Tmux, :rename_session, ->(o, n) { seen << [o, n]; true }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "new.name").status
        end
      end
      assert_equal [["sb/proj/stale-name", "sb/proj/new-name"]], seen
    end

    def test_a_failed_session_rename_is_partial_with_the_name_saved
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      stub_method(Tmux, :sessions, -> { [{ name: "sb/proj/old", created: 1, path: old }] }) do
        stub_method(Tmux, :rename_session, ->(*) { false }) do
          assert_equal :partial, Rename.perform(config_for(repo), "proj", old, "new").status
        end
      end
      assert_equal "new", name_of(old), "the name is saved; the next switch renames the session"
    end

    def test_no_live_session_is_ok
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      stub_method(Tmux, :rename_session, ->(*) { flunk "nothing to rename" }) do
        assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      end
    end

    # --- refusals that change nothing ---------------------------------------------------

    # Value: protects=no name is written while a sidebar runs code that can't read it (it
    # would show the folder, and an old prune could kill the renamed session); fails_when=
    # the gate is skipped or runs after a write; seam=Rename.stale_peers
    def test_a_stale_sidebar_refuses_before_anything_changes
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      result = stub_method(Rename, :stale_peers, -> { ["%7"] }) { Rename.perform(config_for(repo), "proj", old, "new") }
      assert_equal :stale_peers, result.status
      assert_equal ["%7"], result.detail
      assert_equal "old", name_of(old)
      assert Git.branch_exists?(repo, "old")
    end

    def test_an_unreadable_store_or_listing_refuses_instead_of_guessing
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Names, :read_all, -> { [:error, "/n", "EACCES"] }) do
        assert_equal :names_unreadable, Rename.perform(config, "proj", old, "new").status
      end
      stub_method(Git, :worktrees, ->(_repo, strict: false) { strict ? nil : [] }) do
        assert_equal :listing_failed, Rename.perform(config, "proj", old, "new").status
      end
      assert Git.branch_exists?(repo, "old")
    end

    # Value: protects=a failed store write never leaves the branch renamed under the old
    # name; fails_when=the rollback is dropped, or a failed rollback reads as plain :failed;
    # seam=Names.write / Git.rename_branch
    def test_a_failed_save_puts_the_branch_back_or_says_it_couldnt
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Names, :write, ->(*, **) { [:error, "EACCES"] }) do
        result = Rename.perform(config, "proj", old, "new")
        assert_equal :failed, result.status
        assert_equal "EACCES", result.detail
      end
      assert Git.branch_exists?(repo, "old"), "the branch is back"
      refute Git.branch_exists?(repo, "new")

      calls = 0
      rename_branch = Git.method(:rename_branch)
      stub_method(Names, :write, ->(*, **) { [:error, "EACCES"] }) do
        stub_method(Git, :rename_branch, ->(*a) { (calls += 1) == 1 ? rename_branch.call(*a) : false }) do
          result = Rename.perform(config, "proj", old, "new")
          assert_equal :rollback_failed, result.status
          assert_equal %w[EACCES new old], result.detail
        end
      end
    end

    # --- branch sync -------------------------------------------------------------------

    def test_perform_syncs_the_branch_to_the_name_each_time_while_unpushed
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      assert_equal :ok, Rename.perform(config, "proj", old, "new").status
      assert_equal "new", Git.current_branch(old)
      assert_equal :ok, Rename.perform(config, "proj", old, "newer").status
      assert_equal "newer", Git.current_branch(old), "compared to the current name, not the folder"
      assert_equal "newer", Names.read_all.last.values.first.branch
    end

    def test_perform_applies_the_branch_prefix
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :ok, Rename.perform(config_for(repo, "branch_prefix" => "wv"), "proj", old, "new").status
      assert_equal "wv/new", Git.current_branch(old)
    end

    # A pushed branch is left intact (renaming it would orphan its remote ref / PR).
    def test_perform_leaves_a_pushed_branch
      repo = temp_git_repo("proj", origin: true)
      old = path("wts", "proj", "old")
      git(repo, "worktree", "add", "--no-track", "-q", "-b", "old", old, "origin/main")
      git(old, "push", "-q", "origin", "old")
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert_equal "new", name_of(old)
      assert_equal "old", Git.current_branch(old), "the pushed branch is left intact"
    end

    def test_perform_leaves_a_diverged_branch
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old", branch: "feature-x")
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      assert Git.branch_exists?(repo, "feature-x")
      refute Git.branch_exists?(repo, "new")
    end

    def test_a_lingering_branch_or_an_invalid_one_changes_nothing
      repo = temp_git_repo("proj")
      git(repo, "branch", "new")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      assert_equal :branch_exists, Rename.perform(config, "proj", old, "new").status
      assert_equal :invalid, Rename.perform(config, "proj", old, "x.lock").status # sanitizes ok, bad ref
      assert_equal "old", name_of(old)
      assert_equal "old", Git.current_branch(old)
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
    # TMUX gate is removed; seam=none
    def test_a_rename_outside_tmux_spawns_no_worker
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      spawned = spawns_for(env: { "SWITCHBOARD_BIN" => "/sb/bin/switchboard" }) { Rename.perform(config_for(repo), "proj", old, "new") }
      assert_empty spawned
      refute @result.spawned
    end

    def test_a_rename_inside_tmux_spawns_one_worker_for_the_folder_and_the_new_name
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      spawned = spawns_for { Rename.perform(config_for(repo), "proj", old, "new") }
      assert_equal [["/sb/bin/switchboard", "sync-session-name", File.realpath(old), "new"]], spawned
      assert @result.spawned
    end

    # Value: protects=the hour-long worker holds none of the rename's stdio and has its own
    # group; fails_when=out/err/in or pgroup are dropped from the spawn; seam=none
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

    def test_the_knob_off_or_a_failure_spawns_no_worker
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      add_worktree(repo, "taken")
      assert_empty(spawns_for { Rename.perform(config_for(repo), "proj", old, "taken") })
      assert_equal :exists, @result.status
      File.write(Config.path, YAML.dump("projects" => [{ "name" => "proj", "path" => repo, "sync_session_name" => false }]))
      assert_empty(spawns_for { Rename.perform(Config.new, "proj", old, "new") })
    end

    # A same-name rename is the retry doctor points at.
    def test_a_same_name_rename_spawns_a_retry
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "same")
      spawned = spawns_for { Rename.perform(config_for(repo), "proj", old, "same") }
      assert_equal :unchanged, @result.status
      assert_equal [["/sb/bin/switchboard", "sync-session-name", File.realpath(old), "same"]], spawned
    end

    def test_an_unlaunchable_worker_leaves_the_rename_intact
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      ENV["TMUX"] = path("no-server,1,0")
      ENV["SWITCHBOARD_BIN"] = "/gone/switchboard"
      result = stub_method(Process, :spawn, ->(*) { raise Errno::ENOENT }) do
        Rename.perform(config_for(repo), "proj", old, "newer")
      end
      assert_equal :ok, result.status
      refute result.spawned
      assert_equal "newer", name_of(old)
    end

    def test_a_rename_forgets_the_old_names_sync_outcome
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      SessionName::Outcome.record(old, :failed_send, "old")
      Rename.perform(config_for(repo), "proj", old, "new")
      assert_empty SessionName::Outcome.all
    end

    # Value: protects=no notice promises a rename the worker will refuse; fails_when=a name
    # the worker's NAME rejects still spawns; seam=none
    def test_a_name_the_worker_would_refuse_spawns_nothing
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old", branch: "feature-x")
      assert_empty(spawns_for { Rename.perform(config_for(repo), "proj", old, "-dash") })
      assert_equal :ok, @result.status
      refute @result.spawned
    end

    def test_a_partial_rename_still_spawns
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      spawned = stub_method(Tmux, :sessions, -> { [{ name: "sb/proj/old", created: 1, path: old }] }) do
        stub_method(Tmux, :rename_session, ->(*) { false }) { spawns_for { Rename.perform(config_for(repo), "proj", old, "new") } }
      end
      assert_equal :partial, @result.status
      assert_equal 1, spawned.size
    end
  end
end
