# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The dispatch lifecycle record, driven against the real on-disk store in the sandbox.
  # The contract under test: from-gated transitions (a racing writer that already moved
  # the record wins), sticky ack, exactly-once rings, and GC that tells a slow build from
  # a dead one by owner identity rather than a TTL.
  class CreationTest < SandboxTest
    def dispatch(task: "fix the thing", path: path("wt", "quiet-otter"), now: Time.now)
      Creation.create(project: "proj", name: File.basename(path), path: path, task: task, now: now)
    end

    def drive_to_ready(rec, hooked:, owner: Creation.owner_fields)
      id = rec["id"]
      Creation.transition(id, from: :queued, to: :building, **owner)
      Creation.update(id, worktree_added: true, hooked: hooked)
      Creation.transition(id, from: :building, to: :launching, **owner)
      Creation.transition(id, from: :launching, to: :ready)
    end

    def test_create_writes_a_queued_record
      rec = dispatch
      found = Creation.find(rec["id"])
      assert_equal "queued", found["state"]
      assert_equal "fix the thing", found["task"]
      refute found["acked"]
    end

    def test_transition_applies_only_from_an_allowed_state
      rec = dispatch
      assert Creation.transition(rec["id"], from: :queued, to: :building)
      assert_nil Creation.transition(rec["id"], from: :queued, to: :building),
                 "a second writer that lost the race no-ops"
      assert_equal "building", Creation.find(rec["id"])["state"]
    end

    def test_each_state_change_bumps_gen
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building)
      Creation.transition(rec["id"], from: :building, to: :launching)
      assert_equal 2, Creation.find(rec["id"])["gen"]
    end

    def test_field_update_changes_no_state
      rec = dispatch
      Creation.update(rec["id"], hooked: true)
      found = Creation.find(rec["id"])
      assert found["hooked"]
      assert_equal "queued", found["state"]
      assert_equal 0, found["gen"]
    end

    def test_update_refuses_listed_states
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :canceled)
      assert_nil Creation.update(rec["id"], unless_state: :canceled, path: "/elsewhere")
    end

    # --- what rings ------------------------------------------------------------------

    def test_bare_create_rings_on_ready
      rec = drive_to_ready(dispatch(task: ""), hooked: true)
      assert Creation.ring_due?(rec)
    end

    def test_hookless_task_rings_on_ready
      rec = drive_to_ready(dispatch, hooked: false)
      assert Creation.ring_due?(rec)
    end

    def test_hooked_task_waits_for_its_first_turn
      rec = drive_to_ready(dispatch, hooked: true)
      refute Creation.ring_due?(rec), "a hooked tasked create pings on turn_done, not ready"
      done = Creation.transition(rec["id"], from: :ready, to: :turn_done)
      assert Creation.ring_due?(done)
    end

    def test_failure_rings
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building)
      assert Creation.ring_due?(Creation.mark_failed(rec["id"], "setup", 1))
    end

    def test_pre_ready_states_never_ring
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building)
      refute Creation.ring_due?(Creation.find(rec["id"]))
    end

    def test_claim_ring_wins_exactly_once
      rec = drive_to_ready(dispatch(task: ""), hooked: false)
      assert Creation.claim_ring(rec["id"])
      assert_nil Creation.claim_ring(rec["id"]), "a second pane must not ring the same transition"
    end

    def test_claim_ring_is_exactly_once_across_processes
      rec = drive_to_ready(dispatch(task: ""), hooked: false)
      reader, writer = IO.pipe
      pids = Array.new(4) do
        fork do
          reader.close
          writer.write(Creation.claim_ring(rec["id"]) ? "1" : "0")
          exit!(0)
        end
      end
      writer.close
      pids.each { |pid| Process.wait(pid) }
      assert_equal 1, reader.read.count("1"), "the flock'd compare-and-set lets one process ring"
    end

    def test_acked_never_rings
      rec = drive_to_ready(dispatch(task: ""), hooked: false)
      Creation.ack(rec["id"])
      assert_nil Creation.claim_ring(rec["id"])
    end

    # Value: protects=a ringing transition (from the worker/launcher/Stop hook, with no sidebar on screen) bolds the workspace on disk, and an acked one doesn't; fails_when=advance stops calling Attention.mark, or marks acked/non-ringing records; why_new=existing ring tests assert ring_gen only, never the persisted bold the away-user relies on; seam=none; no_claim=sidebar rendering of the bold
    def test_a_ringing_transition_bolds_the_workspace_from_any_process
      dir = File.realpath(FileUtils.mkdir_p(path("wt", "quiet-otter")).first)
      rec = dispatch(task: "", path: dir)
      Creation.transition(rec["id"], from: :queued, to: :building)
      assert_empty Attention.marked([dir]), "a pre-ready state never bolds"
      drive_ready = Creation.transition(rec["id"], from: :building, to: :launching)
      Creation.transition(drive_ready["id"], from: :launching, to: :ready)
      assert_includes Attention.marked([dir]), dir, "a bare create's ready bolds with no sidebar involved"

      acked_dir = File.realpath(FileUtils.mkdir_p(path("wt", "seen-it")).first)
      seen = dispatch(task: "", path: acked_dir)
      Creation.transition(seen["id"], from: :queued, to: :building)
      Creation.ack(seen["id"])
      Creation.mark_failed(seen["id"], "setup", 1)
      assert_empty Attention.marked([acked_dir]), "you already looked: a failure doesn't re-bold"
    end

    # --- interleavings ---------------------------------------------------------------

    def test_ack_mid_build_stays_sticky_through_ready
      rec = dispatch(task: "")
      Creation.transition(rec["id"], from: :queued, to: :building)
      Creation.ack(rec["id"])
      Creation.transition(rec["id"], from: :building, to: :launching)
      ready = Creation.transition(rec["id"], from: :launching, to: :ready)
      assert ready["acked"]
      refute Creation.ring_due?(ready), "you watched it build, so no ping"
    end

    def test_stop_after_ack_does_not_ring
      rec = drive_to_ready(dispatch, hooked: true)
      Creation.ack(rec["id"])
      done = Creation.transition(rec["id"], from: :ready, to: :turn_done)
      refute Creation.ring_due?(done)
    end

    def test_late_launcher_claim_no_ops_after_failure
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building)
      Creation.mark_failed(rec["id"], "didnt_start")
      assert_nil Creation.transition(rec["id"], from: :building, to: :launching),
                 "the launcher must not resurrect a build the worker already gave up on"
    end

    def test_cancel_all_stops_in_flight_builds_only
      building = dispatch(path: path("wt", "a"))
      Creation.transition(building["id"], from: :queued, to: :building)
      done = drive_to_ready(dispatch(path: path("wt", "b")), hooked: false)
      Creation.cancel_all
      assert_equal "canceled", Creation.find(building["id"])["state"]
      assert_equal "ready", Creation.find(done["id"])["state"]
    end

    def test_cancel_all_scopes_to_projects
      rec = dispatch
      Creation.cancel_all(projects: ["other"])
      assert_equal "queued", Creation.find(rec["id"])["state"]
    end

    # --- first-turn ownership (D16) ---------------------------------------------------

    def test_owns_first_turn_while_hooked_task_is_pending
      rec = drive_to_ready(dispatch, hooked: true)
      assert Creation.owns_first_turn?(rec)
      assert Creation.owns_first_turn?(Creation.transition(rec["id"], from: :ready, to: :turn_done)),
             "still owned right after the stamp, so a late scan doesn't double-ring"
      refute Creation.owns_first_turn?(Creation.ack(rec["id"])), "viewing hands later turns back"
    end

    def test_does_not_own_hookless_or_bare
      refute Creation.owns_first_turn?(drive_to_ready(dispatch, hooked: false))
      refute Creation.owns_first_turn?(drive_to_ready(dispatch(task: "", path: path("wt", "z")), hooked: true))
    end

    # --- lookup + rename ----------------------------------------------------------------

    def test_for_path_compares_realpaths
      real = path("wt", "real")
      FileUtils.mkdir_p(real)
      File.symlink(real, path("wt", "link"))
      rec = dispatch(path: real)
      assert_equal rec["id"], Creation.for_path(path("wt", "link"))["id"]
    end

    # Value: protects=the launcher claims the build in its dir, not a finished record left on a reused path; fails_when=for_path returns the oldest match, so the claim no-ops and the new workspace opens agent-less; why_new=only single-record lookups were tested; seam=none; no_claim=how a name gets reused
    def test_for_path_prefers_the_newest_record_on_a_reused_path
      wt = path("wt", "quiet-otter")
      old = dispatch(path: wt, now: Time.now - 3600)
      drive_to_ready(old, hooked: false)
      fresh = dispatch(path: wt)
      Creation.transition(fresh["id"], from: :queued, to: :building, **Creation.owner_fields)
      assert_equal fresh["id"], Creation.for_path(wt)["id"]
      assert Creation.transition(Creation.for_path(wt)["id"], from: :building, to: :launching)
    end

    def test_repath_carries_the_record_to_the_new_dir
      old = path("wt", "quiet-otter")
      FileUtils.mkdir_p(old)
      rec = dispatch(path: old)
      Creation.repath(old, File.realpath(old), path("wt", "pr-retry"))
      found = Creation.find(rec["id"])
      assert_equal path("wt", "pr-retry"), found["path"]
      assert_equal "pr-retry", found["name"]
    end

    # Like for_path: the build in this dir is the newest record, not a finished one left
    # on a reused path.
    def test_repath_moves_the_newest_record_on_a_reused_path
      old = path("wt", "quiet-otter")
      FileUtils.mkdir_p(old)
      stale = dispatch(path: old, now: Time.now - 3600)
      fresh = dispatch(path: old)
      Creation.repath(old, File.realpath(old), path("wt", "named"))
      assert_equal path("wt", "named"), Creation.find(fresh["id"])["path"]
      assert_equal old, Creation.find(stale["id"])["path"]
    end

    # --- GC -------------------------------------------------------------------------------

    def test_gc_fails_a_queued_record_whose_worker_never_started
      rec = dispatch(now: Time.now - 60)
      Creation.gc
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert_equal "didnt_start", found["reason"]
    end

    def test_gc_leaves_a_fresh_queued_record
      rec = dispatch
      Creation.gc
      assert_equal "queued", Creation.find(rec["id"])["state"]
    end

    def test_gc_fails_a_build_whose_owner_died
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: 2_147_483_600, owner_start: "x")
      Creation.gc
      found = Creation.find(rec["id"])
      assert_equal "failed", found["state"]
      assert_equal "interrupted", found["reason"]
    end

    # The liveness hand-off: a 15s setup runs under the LAUNCHER, so GC racing it must see
    # a live owner and leave it alone.
    def test_gc_never_fails_a_live_setup
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      Creation.transition(rec["id"], from: :building, to: :launching, **Creation.owner_fields)
      5.times { Creation.gc }
      assert_equal "launching", Creation.find(rec["id"])["state"]
    end

    def test_gc_rechecks_under_the_lock_when_the_owner_handed_off
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: 2_147_483_600, owner_start: "x")
      stale_view = Creation.find(rec["id"])
      Creation.transition(rec["id"], from: :building, to: :launching, **Creation.owner_fields)
      Creation.send(:reap_dead_owner, stale_view, Time.now, ProcessIdentity.method(:same?))
      assert_equal "launching", Creation.find(rec["id"])["state"],
                   "GC must not fail a build whose owner changed after it looked"
    end

    def test_gc_drops_canceled_records
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :canceled)
      Creation.gc
      assert_nil Creation.find(rec["id"])
    end

    # Value: protects=an un-set-up tree on disk keeps its guard record even when worktree_added was never written; fails_when=drop? keys the unfinished guard on the flag, so an add killed mid-checkout loses its record after one ack; why_new=keep-tests always set worktree_added; seam=none; no_claim=how the tree came to exist
    def test_gc_keeps_an_unfinished_record_while_its_tree_is_on_disk
      dir = path("wt", "half-built")
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: 2_147_483_600, owner_start: "x")
      FileUtils.mkdir_p(dir) # git made the tree; the worker died before recording it
      File.write(File.join(dir, ".git"), "gitdir: /repo/.git/worktrees/half-built\n")
      Creation.gc
      Creation.ack(rec["id"])
      Creation.gc
      found = Creation.find(rec["id"])
      refute_nil found, "an acked ✘ on an un-set-up tree still guards it"
      assert_equal "interrupted", found["reason"]
      assert found["worktree_added"], "GC recorded the tree the worker never did"
      FileUtils.rm_rf(dir)
      Creation.gc
      assert_nil Creation.find(rec["id"]), "gone once the tree is"
    end

    # Value: protects=a build whose add fails after git wrote `.git` still lands its ✘ and task; fails_when=GC stamps or drops an in-flight record, so the rollback's missing dir deletes it and mark_failed lands on nothing; why_new=the on-disk test uses a dead owner (reaped first), never a live in-flight build; seam=none; no_claim=git's own timing of the `.git` write
    def test_gc_never_drops_a_live_build_whose_failed_add_was_rolled_back
      dir = path("wt", "hooked")
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      FileUtils.mkdir_p(dir) # git wrote `.git`; a post-checkout hook is still running
      File.write(File.join(dir, ".git"), "gitdir: /repo/.git/worktrees/hooked\n")
      Creation.gc
      refute Creation.find(rec["id"])["worktree_added"], "the worker owns an in-flight tree"
      FileUtils.rm_rf(dir) # the hook failed; undo_add rolled the tree back
      Creation.gc
      failed = Creation.mark_failed(rec["id"], "worktree_add", "hook refused")
      refute_nil failed, "the worker's ✘ lands"
      assert_equal %w[failed hook\ refused], failed.values_at("state", "detail")
    end

    # Value: protects=an in-flight build the worker already recorded as added survives its tree vanishing, so its own ✘ lands; fails_when=drop?'s rule 3 runs before the in-flight guard; why_new=the test above only reaches the stamp guard (worktree_added never set); seam=none; no_claim=which process removed the dir
    def test_gc_never_drops_an_in_flight_build_whose_recorded_tree_vanished
      dir = path("wt", "launching")
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      Creation.transition(rec["id"], from: :building, to: :launching, worktree_added: true)
      Creation.gc # the dir never existed here: as if setup's `rm -rf` took it
      refute_nil Creation.mark_failed(rec["id"], "setup", 1), "the launcher's ✘ lands"
    end

    # A bare leftover dir (no checkout in it) can't be entered as a workspace, so it
    # holds nothing: an acked ✘ there is dismissed like any other.
    def test_gc_drops_an_acked_failure_over_a_dir_that_is_no_checkout
      dir = path("wt", "debris")
      rec = dispatch(path: dir)
      FileUtils.mkdir_p(dir)
      Creation.mark_failed(rec["id"], "worktree_add", "x", from: "queued")
      Creation.ack(rec["id"])
      Creation.gc
      assert_nil Creation.find(rec["id"])
    end

    # Under a C locale (no LANG) Ruby reads files as US-ASCII; a task with a smart quote
    # or emoji must still parse, or the build vanishes as a "torn" record.
    def test_a_non_ascii_record_reads_under_a_c_locale
      rec = dispatch(task: "fix “this” 🐛")
      saved = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      found = Creation.find(rec["id"])
      refute_nil found
      assert_equal "fix “this” 🐛", found["task"]
    ensure
      Encoding.default_external = saved
    end

    # The keep-canceled rule uses GC's one liveness test: a worker whose start time
    # couldn't be read is alive while its pid is.
    def test_gc_keeps_a_canceled_record_whose_owner_start_time_is_unknown
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: Process.pid, owner_start: "")
      Creation.cancel_all
      Creation.gc
      refute_nil Creation.find(rec["id"])
    end

    # A cancel during a slow `worktree add`: the worker still has to record the tree it
    # may keep, so the record outlives GC until its owner is gone.
    def test_gc_keeps_a_canceled_record_while_its_owner_lives
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      Creation.cancel_all
      Creation.gc
      refute_nil Creation.find(rec["id"]), "the live worker still needs it"
      Creation.gc(owners: false)
      refute_nil Creation.find(rec["id"]), "an off-screen pane can't check, so it waits"
      Creation.gc(same: ->(*) { false })
      assert_nil Creation.find(rec["id"]), "dropped once the worker is gone"
    end

    def test_gc_drops_a_built_worktree_that_was_deleted
      rec = dispatch(path: path("wt", "gone"))
      Creation.update(rec["id"], state: "ready", worktree_added: true, setup_ok: true) # built, then deleted
      Creation.gc
      assert_nil Creation.find(rec["id"])
    end

    def test_gc_keeps_a_pre_worktree_failure_until_acked
      rec = dispatch(path: path("wt", "never-made"))
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      Creation.mark_failed(rec["id"], "worktree_add", "branch exists")
      Creation.gc
      refute_nil Creation.find(rec["id"]), "an unseen ✘ survives GC"
      Creation.ack(rec["id"])
      Creation.gc
      assert_nil Creation.find(rec["id"])
    end

    # D12 needs the record after you've looked: re-entering a failed workspace whose
    # session is gone must still open a plain shell, so its ✘ persists until it's deleted.
    def test_gc_keeps_an_acked_failure_that_has_a_worktree
      dir = path("wt", "broken")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".git"), "gitdir: x\n") # a linked worktree
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :launching, worktree_added: true, **Creation.owner_fields)
      Creation.mark_failed(rec["id"], "setup", 1)
      Creation.ack(rec["id"])
      Creation.gc
      refute_nil Creation.find(rec["id"])
      FileUtils.rm_rf(dir)
      Creation.gc
      assert_nil Creation.find(rec["id"]), "deleting the workspace finally drops it"
    end

    # Once you've looked, no ping can fire — so even a hooked ready whose first turn never
    # reported (a crash mid-turn) is done; only an UN-acked one still waits for it.
    def test_gc_drops_acked_ready_but_keeps_an_unacked_hooked_ready
      done = drive_to_ready(dispatch(path: path("wt", "a")), hooked: false)
      seen = drive_to_ready(dispatch(path: path("wt", "b")), hooked: true)
      waiting = drive_to_ready(dispatch(path: path("wt", "c")), hooked: true)
      [done, seen].each { |r| Creation.ack(r["id"]) }
      FileUtils.mkdir_p([path("wt", "a"), path("wt", "b"), path("wt", "c")])
      Creation.gc
      assert_nil Creation.find(done["id"]), "a hook-less ready has nothing left to report"
      assert_nil Creation.find(seen["id"]), "an acked hooked ready can never ping, so it isn't kept forever"
      refute_nil Creation.find(waiting["id"]), "an unacked hooked ready still expects its first turn"
    end

    # A quit mid-setup cancels a build whose worktree exists; setup never finished there,
    # so the record must outlive GC to keep re-entry on a plain shell.
    def test_gc_keeps_a_canceled_build_that_has_a_worktree
      dir = path("wt", "half-built")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".git"), "gitdir: x\n") # a linked worktree
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :launching, worktree_added: true, **Creation.owner_fields)
      Creation.cancel_all
      Creation.gc
      assert_equal "canceled", Creation.find(rec["id"])&.dig("state")
      FileUtils.rm_rf(dir)
      Creation.gc
      assert_nil Creation.find(rec["id"]), "deleting the workspace finally drops it"
    end

    # A transient `ps` miss reads as an empty start time; GC must not fail a live build on it.
    def test_gc_does_not_fail_a_live_owner_on_an_unreadable_start_time
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, **Creation.owner_fields)
      stub_method(ProcessIdentity, :start_of, ->(_pid) { "" }) { Creation.gc }
      assert_equal "building", Creation.find(rec["id"])["state"]
    end

    # The same, when `ps` missed at the moment the owner was RECORDED: an empty token
    # can never match, so only a dead pid may fail the build.
    def test_gc_does_not_fail_a_live_owner_recorded_without_a_start_time
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: Process.pid, owner_start: "")
      Creation.gc
      assert_equal "building", Creation.find(rec["id"])["state"]
    end

    def test_gc_drops_records_of_a_removed_project_only_given_a_real_list
      dir = path("wt", "gone-proj")
      FileUtils.mkdir_p(dir)
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :ready)
      Creation.gc(projects: [])
      refute_nil Creation.find(rec["id"]), "an empty (failed) project list never wipes records"
      Creation.gc(projects: ["other"])
      assert_nil Creation.find(rec["id"])
    end

    # GC decides on a lock-free read; the delete re-decides under the lock, so a writer
    # that changed the record in between (here: un-acking) wins.
    def test_delete_with_a_check_rereads_under_the_lock
      rec = dispatch
      refute Creation.delete(rec["id"]) { |cur| cur["acked"] }
      refute_nil Creation.find(rec["id"])
    end

    # Through gc itself: its lock-free snapshot says "acked, drop it", but the record on
    # disk changed since (un-acked), and the re-decision under the lock keeps it.
    def test_gc_rechecks_the_drop_under_the_lock
      dir = path("wt", "raced")
      FileUtils.mkdir_p(dir)
      rec = drive_to_ready(dispatch(path: dir), hooked: false)
      stale = Creation.find(rec["id"]).merge("acked" => true)
      stub_method(Creation, :all, -> { [stale] }) { Creation.gc }
      refute_nil Creation.find(rec["id"])
    end

    # An un-set-up tree stays guarded even after its project is removed, so re-registering
    # the project can't re-enter it with the agent.
    def test_gc_keeps_an_unfinished_worktree_of_a_removed_project
      dir = path("wt", "half-built")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".git"), "gitdir: x\n") # a linked worktree
      rec = dispatch(path: dir)
      Creation.transition(rec["id"], from: :queued, to: :launching, worktree_added: true, **Creation.owner_fields)
      Creation.mark_failed(rec["id"], "setup", 1)
      Creation.gc(projects: ["other"])
      refute_nil Creation.find(rec["id"])
    end

    # A quit on one tmux server kills only that server's sessions, so it must cancel only
    # that server's builds. Records with no server (outside tmux, older records) stay in.
    def test_cancel_all_is_scoped_to_the_current_server
      here = Creation.create(project: "proj", name: "a", path: path("a"), task: "", server: "/tmp/tmux-1/default")
      there = Creation.create(project: "proj", name: "b", path: path("b"), task: "", server: "/tmp/tmux-1/other")
      unknown = Creation.create(project: "proj", name: "c", path: path("c"), task: "", server: nil)
      Creation.cancel_all(server: "/tmp/tmux-1/default")
      assert_equal %w[canceled queued canceled], [here, there, unknown].map { |r| Creation.find(r["id"])["state"] }
    end

    def test_current_server_comes_from_tmux_env_only
      ENV["TMUX"] = "/tmp/tmux-501/default,123,4"
      assert_equal "/tmp/tmux-501/default", Creation.current_server
      ENV.delete("TMUX")
      assert_nil Creation.current_server
    end

    # The launch go-ahead is one locked, state-gated step: only a still-launching build
    # gets it; canceled, failed or gone means no agent.
    def test_authorize_launch_only_for_a_build_still_launching
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :launching)
      assert Creation.authorize_launch(rec["id"])
      found = Creation.find(rec["id"])
      assert found["setup_ok"] && found["agent_started"]

      other = dispatch(path: path("wt", "other"))
      Creation.transition(other["id"], from: :queued, to: :canceled)
      assert_nil Creation.authorize_launch(other["id"])
      refute Creation.find(other["id"])["setup_ok"]
      assert_nil Creation.authorize_launch("20260101000000-000000")

      failed = dispatch(path: path("wt", "failed"))
      Creation.transition(failed["id"], from: :queued, to: :launching)
      Creation.mark_failed(failed["id"], "setup", 1, from: "launching")
      assert_nil Creation.authorize_launch(failed["id"]), "a failed build never gets its agent"
      refute Creation.find(failed["id"])["setup_ok"]
    end

    def test_authorize_launch_settles_hooked
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true)
      Creation.authorize_launch(rec["id"], hooked: false)
      refute Creation.find(rec["id"])["hooked"]
    end

    # Value: protects=a Stop never resurrects, re-rings, or rings a bare create twice; fails_when=stamp_first_turn drops its state or task gate; why_new=stamps were only driven from ready/launching; seam=none; no_claim=the hook's cwd matching
    def test_stamp_first_turn_only_moves_a_live_tasked_first_turn
      bare = dispatch(task: "", path: path("wt", "bare"))
      drive_to_ready(bare, hooked: true)
      assert_nil Creation.stamp_first_turn(bare["id"]), "a bare create already rang at ready"

      %i[failed canceled turn_done].each do |state|
        rec = dispatch(path: path("wt", state.to_s))
        Creation.transition(rec["id"], from: :queued, to: :launching, hooked: true, agent_started: true)
        Creation.transition(rec["id"], from: :launching, to: state)
        gen = Creation.find(rec["id"])["ring_gen"]
        assert_nil Creation.stamp_first_turn(rec["id"]), state.to_s
        assert_equal [state.to_s, gen], Creation.find(rec["id"]).values_at("state", "ring_gen")
      end
    end

    def test_gc_keeps_an_unacked_turn_done_and_drops_it_once_acked
      rec = dispatch
      FileUtils.mkdir_p(rec["path"])
      drive_to_ready(rec, hooked: true)
      Creation.transition(rec["id"], from: :ready, to: :turn_done)
      Creation.gc
      refute_nil Creation.find(rec["id"])
      Creation.ack(rec["id"])
      Creation.gc
      assert_nil Creation.find(rec["id"])
    end

    def test_a_failure_detail_cannot_carry_terminal_escapes
      rec = dispatch
      Creation.mark_failed(rec["id"], "worktree_add", "bad\e]0;pwn\a\e[2Jref")
      refute_match(/[[:cntrl:]]/, Creation.find(rec["id"])["detail"])
    end

    def test_gc_sweeps_orphan_locks_and_temps_but_not_reservation_locks
      dir = Creation.state_dir
      FileUtils.mkdir_p(dir)
      old = Time.now - 600
      %w[20200101000000-aaaaaa.lock 20200101000000-bbbbbb.json.123.sb-tmp reserve-abc.lock].each do |f|
        File.write(File.join(dir, f), "")
        File.utime(old, old, File.join(dir, f))
      end
      Creation.gc
      assert_equal ["reserve-abc.lock"], Dir.children(dir).sort
    end

    # Matched by pid alone (its start time was never read) a recycled pid can pose as
    # the owner forever; past PID_ONLY_CEILING the build is called dead.
    def test_gc_fails_a_pid_only_owner_past_the_ceiling
      rec = dispatch(now: Time.now - Creation::PID_ONLY_CEILING - 60)
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: Process.pid, owner_start: "")
      Creation.gc
      assert_equal %w[failed interrupted], Creation.find(rec["id"]).values_at("state", "reason")
    end

    def test_an_off_screen_gc_skips_the_owner_checks
      rec = dispatch
      Creation.transition(rec["id"], from: :queued, to: :building, owner_pid: 2_147_483_600, owner_start: "x")
      Creation.gc(owners: false)
      assert_equal "building", Creation.find(rec["id"])["state"], "no ps per build on a warm reload"
    end

    # If the first-turn stamp never comes, the workspace mustn't stay muted forever.
    def test_first_turn_ownership_lapses_past_its_ceiling
      rec = drive_to_ready(dispatch, hooked: true)
      found = Creation.find(rec["id"])
      assert Creation.owns_first_turn?(found)
      refute Creation.owns_first_turn?(found, now: Time.at(found["updated_at"] + Creation::FIRST_TURN_CEILING + 1))
    end

    # The sidebar's background writers skip a record another process holds instead of
    # freezing the input loop.
    def test_a_non_waiting_mutate_skips_a_locked_record
      rec = dispatch
      rd, wr = IO.pipe
      pid = fork do
        rd.close
        File.open(File.join(Creation.state_dir, "#{rec['id']}.lock"), File::RDWR | File::CREAT) do |l|
          l.flock(File::LOCK_EX)
          wr.write("x")
          wr.close
          sleep 2
        end
        exit!(0)
      end
      wr.close
      rd.read(1)
      started = Time.now
      assert_nil Creation.claim_ring(rec["id"])
      assert_operator Time.now - started, :<, 1
    ensure
      Process.kill("KILL", pid) if pid
      Process.wait(pid) if pid
    end

    def test_a_mutate_on_a_gone_record_leaves_no_lock_file
      assert_nil Creation.update("20260101000000-abcdef", acked: true)
      assert_empty Dir.glob(File.join(Creation.state_dir, "*.lock"))
    end

    def test_owns_first_turn_from_launching_until_shortly_after_its_ring
      rec = dispatch
      Creation.update(rec["id"], hooked: true)
      Creation.transition(rec["id"], from: :queued, to: :launching)
      assert Creation.owns_first_turn?(Creation.find(rec["id"])), "a Stop can land inside the grace"
      Creation.transition(rec["id"], from: :launching, to: :turn_done)
      assert Creation.owns_first_turn?(Creation.find(rec["id"])), "until its ping rings"
      Creation.claim_ring(rec["id"])
      rung = Creation.find(rec["id"])
      assert Creation.owns_first_turn?(rung), "the turn's own edge may land a scan later"
      later = Time.at(rung["rung_at"] + Creation::FIRST_TURN_MARGIN + 1)
      refute Creation.owns_first_turn?(rung, now: later), "then the agent's later turns chime normally"
    end

    def test_delete_removes_the_record_and_its_lock
      rec = dispatch
      Creation.update(rec["id"], acked: true) # creates the lock file
      assert Creation.delete(rec["id"])
      assert_nil Creation.find(rec["id"])
      assert_empty Dir.glob(File.join(Creation.state_dir, "#{rec['id']}*"))
    end

    # The (state × event) matrix for the events that must leave most states alone: a
    # teardown cancels only in-flight builds, a Stop stamps only launching/ready, and a
    # ring is claimable only once a ringing state has been reached and not yet rung.
    STATES = {
      "queued" => ->(_r) {},
      "building" => ->(r) { Creation.transition(r["id"], from: :queued, to: :building) },
      "launching" => ->(r) { Creation.transition(r["id"], from: :queued, to: :launching) },
      "ready" => ->(r) { Creation.transition(r["id"], from: :queued, to: :ready) },
      "turn_done" => ->(r) { Creation.transition(r["id"], from: :queued, to: :turn_done) },
      "failed" => ->(r) { Creation.mark_failed(r["id"], "setup", 1) },
      "canceled" => ->(r) { Creation.transition(r["id"], from: :queued, to: :canceled) }
    }.freeze

    def record_in(state)
      rec = dispatch(path: path("wt", state))
      Creation.update(rec["id"], hooked: true)
      STATES.fetch(state).call(rec)
      rec
    end

    def test_cancel_all_moves_only_in_flight_states
      STATES.each_key do |state|
        rec = record_in(state)
        Creation.cancel_all
        want = Creation::PRE_READY.include?(state) ? "canceled" : state
        assert_equal want, Creation.find(rec["id"])["state"], "cancel from #{state}"
      end
    end

    def test_a_stop_stamps_only_launching_or_ready
      STATES.each_key do |state|
        rec = record_in(state)
        Creation.transition(rec["id"], from: %i[launching ready], to: :turn_done)
        want = %w[launching ready].include?(state) ? "turn_done" : state
        assert_equal want, Creation.find(rec["id"])["state"], "stop from #{state}"
      end
    end

    def test_only_ringing_states_can_be_claimed
      STATES.each_key do |state|
        rec = record_in(state)
        claimed = !Creation.claim_ring(rec["id"]).nil?
        # hooked + tasked: ready waits for its first turn; turn_done and failed ring
        assert_equal %w[turn_done failed].include?(state), claimed, "claim from #{state}"
      end
    end

    # --- copy (DR8) -------------------------------------------------------------------

    def test_row_reasons_fit_fourteen_columns
      Creation::REASONS.each_key do |code|
        text = Creation.row_reason("reason" => code, "detail" => "127")
        assert_operator text.length, :<=, 14, "#{code} row reason overflows: #{text.inspect}"
      end
    end

    def test_pane_notices_share_one_voice
      assert Creation.notice(:task_not_sent).start_with?("switchboard: ")
      assert_equal "switchboard: setup did not succeed (setup exit 1), so switchboard won't start the agent here; finish setup and start it by hand, or press d on the row",
                   Creation.notice(:reentry, "setup exit 1")
    end

    def test_long_reason_falls_back_for_an_unknown_code
      assert_equal "the build failed", Creation.long_reason("reason" => "nope")
    end
  end
end
