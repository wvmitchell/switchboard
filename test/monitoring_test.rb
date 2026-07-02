# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The background-monitor ∞ markers. Like Attention, tiny shared files on disk; we
  # drive real dirs in the sandbox and assert on the live set, so canonicalization,
  # the freshness (liveness) gate, and the GC all run for real.
  class MonitoringTest < SandboxTest
    # A real (existing, canonicalized) worktree dir — mark stores the realpath.
    def wt(sub = "wt")
      d = path(sub)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def marker_file(real)
      File.join(Monitoring.state_dir, Monitoring.key(real))
    end

    def test_mark_then_monitored_includes_the_path
      w = wt
      Monitoring.mark(w)
      assert_includes Monitoring.monitored([w]), w
    end

    def test_clear_stops_monitoring
      w = wt
      Monitoring.mark(w)
      Monitoring.clear(w)
      refute_includes Monitoring.monitored([w]), w
    end

    def test_clear_is_idempotent_when_already_off
      w = wt
      assert_nil Monitoring.clear(w), "clearing a missing marker is a quiet no-op"
      assert_empty Monitoring.monitored([w])
    end

    def test_mark_is_a_noop_for_a_nonexistent_dir
      ghost = path("ghost") # never created
      Monitoring.mark(ghost)
      assert_empty Monitoring.monitored([ghost]), "a stale path can't seed a junk marker"
    end

    # monitored() echoes back the path you pass, even a symlinked alias, so the
    # renderer can test node.path directly (matches Attention.marked).
    def test_monitored_keys_by_the_raw_input_path_through_a_symlink
      w = wt("real")
      File.symlink(w, path("alias"))
      Monitoring.mark(w)
      assert_includes Monitoring.monitored([path("alias")]), path("alias")
    end

    def test_clear_all_wipes_every_marker
      a = wt("a")
      b = wt("b")
      Monitoring.mark(a)
      Monitoring.mark(b)
      Monitoring.clear_all
      assert_empty Monitoring.monitored([a, b])
    end

    # The liveness gate: a marker not re-affirmed within TTL is stale — dropped from the
    # live set AND garbage-collected. This is thought-experiment #2/#3's floor: a stopped
    # or crashed agent stops re-affirming, so its dot ages out on its own.
    def test_a_stale_marker_is_dropped_and_gced
      w = wt
      Monitoring.mark(w)
      old = Time.now - Monitoring::TTL - 60
      File.utime(old, old, marker_file(w)) # age it past the TTL
      assert_empty Monitoring.monitored([w]), "past TTL, no re-affirm -> not live"
      refute File.exist?(marker_file(w)), "and the stale marker is GC'd, not just hidden"
    end

    # Re-affirming (a second `mark`) rewrites the marker with a fresh mtime, so a monitor
    # that would otherwise age out keeps its dot up across cycles.
    def test_reaffirm_refreshes_liveness
      w = wt
      Monitoring.mark(w)
      old = Time.now - Monitoring::TTL - 60
      File.utime(old, old, marker_file(w))
      assert_empty Monitoring.monitored([w]), "aged marker is stale (and gets GC'd)"

      Monitoring.mark(w) # re-affirm
      assert_includes Monitoring.monitored([w]), w, "re-affirm restores liveness"
    end

    def test_scan_garbage_collects_a_dead_worktrees_marker
      w = wt("doomed")
      Monitoring.mark(w)
      FileUtils.remove_entry(w)
      assert_empty Monitoring.monitored([w]), "a marker whose worktree is gone is cleaned up"
    end

    # A torn mid-write read (empty) is SKIPPED, never deleted — mirrors Attention /
    # AgentState, so a racing scan can't erase a marker a peer is mid-writing.
    def test_live_paths_skips_a_torn_empty_marker_without_deleting_it
      FileUtils.mkdir_p(Monitoring.state_dir)
      f = File.join(Monitoring.state_dir, "torn")
      File.write(f, "")
      assert_empty Monitoring.live_paths
      assert File.exist?(f), "an empty (torn) read is skipped this cycle, never deleted"
    end

    # Carry across a rename: the key is the realpath, which the dir move changes, so the
    # marker is re-keyed old -> new. One shared helper (KeyedMarkerStore.carry) backs this
    # and Attention's identical fix.
    def test_carry_moves_the_marker_to_the_new_realpath
      old = wt("old")
      new = wt("new")
      Monitoring.mark(old)
      Monitoring.carry(old, new)
      refute File.exist?(marker_file(old)), "old key removed"
      assert_includes Monitoring.monitored([new]), new, "new key present and live"
    end

    def test_carry_is_a_noop_when_nothing_is_monitored
      old = wt("old")
      new = wt("new")
      Monitoring.carry(old, new) # no marker at old
      assert_empty Monitoring.monitored([new]), "carry of an absent marker creates nothing"
    end
  end
end
