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

    # An agent whose cycle is slower than the ~10-min default declares its own window, so
    # the dot stays lit between ticks instead of going stale mid-cycle (issue: a 30-min
    # loop under the hardcoded default).
    def test_a_declared_ttl_keeps_a_marker_live_past_the_default_window
      w = wt
      Monitoring.mark(w, ttl: Monitoring::TTL * 4) # a slow-cycle monitor
      old = Time.now - Monitoring::TTL - 60        # older than the DEFAULT, within its own window
      File.utime(old, old, marker_file(w))
      assert_includes Monitoring.monitored([w]), w, "the agent's window outlives the default TTL"
    end

    # But it's still a liveness clock: past its OWN window a custom marker is stale and GC'd
    # like any other, so a crashed slow-cycle agent's dot still ages out.
    def test_a_declared_ttl_still_ages_out_past_its_own_window
      w = wt
      window = Monitoring::TTL * 4
      Monitoring.mark(w, ttl: window)
      old = Time.now - window - 60
      File.utime(old, old, marker_file(w))
      assert_empty Monitoring.monitored([w]), "past its own ttl the custom marker is stale too"
      refute File.exist?(marker_file(w)), "and GC'd, not just hidden"
    end

    # The declared window survives a rename — carry re-encodes the ttl onto the new key, so
    # a renamed slow-cycle monitor doesn't silently revert to the default until its next tick.
    def test_carry_preserves_a_declared_ttl
      old = wt("old")
      new = wt("new")
      Monitoring.mark(old, ttl: Monitoring::TTL * 4)
      Monitoring.carry(old, new)
      aged = Time.now - Monitoring::TTL - 60 # past the default, within the carried window
      File.utime(aged, aged, marker_file(new))
      assert_includes Monitoring.monitored([new]), new, "the agent's ttl rides through the rename"
    end

    # decode is the read-time interpreter: honor a valid trailing ttl, fall back to the
    # default on a bad one, and — the tab-in-path guard (from review) — never truncate a
    # realpath that itself contains a tab. Only a trailing \t<positive-int> is a ttl.
    def test_decode_reads_ttl_without_truncating_a_tabbed_path
      assert_equal ["/wt", Monitoring::TTL],   Monitoring.decode("/wt"),         "bare -> default window"
      assert_equal ["/wt", 2400],              Monitoring.decode("/wt\t2400"),   "trailing int is the ttl"
      assert_equal ["/a\tb", 2400],            Monitoring.decode("/a\tb\t2400"), "tab in path + ttl: split on the LAST tab"
      assert_equal ["/a\tb", Monitoring::TTL], Monitoring.decode("/a\tb"),       "tab in path, no ttl: whole content is the path"
      assert_equal ["/wt\tx", Monitoring::TTL], Monitoring.decode("/wt\tx"),     "non-numeric suffix -> whole content is the path"
    end

    # End-to-end: a worktree whose dir literally contains a tab still lights up (the #1
    # regression the tab-safe decode fixes — bare marker, whole content is the path).
    def test_a_tabbed_worktree_path_is_still_monitored
      w = wt("a\tb")
      Monitoring.mark(w)
      assert_includes Monitoring.monitored([w]), w, "a tab in the path no longer truncates the marker"
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
