# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The declared "come look" alert markers (`monitoring notify`). A KeyedMarkerStore
  # twin of Attention — tiny shared files on disk — but READ by mtime: pending returns
  # { raw_path => mtime } so a sidebar can ring once per advance. We drive real dirs in
  # the sandbox so canonicalization, the dir-GC, and mtime all run for real.
  class NotifyTest < SandboxTest
    def wt(sub = "wt")
      d = path(sub)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def marker_file(real)
      File.join(Notify.state_dir, Notify.key(real))
    end

    def test_mark_then_pending_includes_the_path_with_its_mtime
      w = wt
      Notify.mark(w)
      pend = Notify.pending([w])
      assert_includes pend.keys, w
      assert_equal File.mtime(marker_file(w)), pend[w], "pending carries the marker's mtime"
    end

    def test_pending_is_keyed_by_the_raw_input_path_through_a_symlink
      real = wt("real")
      File.symlink(real, path("alias"))
      Notify.mark(path("alias")) # canonicalizes to real internally
      pend = Notify.pending([path("alias")])
      assert_includes pend.keys, path("alias"), "keyed by node.path, not the realpath"
    end

    def test_mark_is_a_noop_for_a_nonexistent_dir
      ghost = path("gone")
      Notify.mark(ghost)
      assert_empty Notify.pending([ghost]), "a stale path can't seed a junk marker"
    end

    def test_re_notify_bumps_the_mtime
      w = wt
      Notify.mark(w)
      File.utime(Time.at(1_000), Time.at(1_000), marker_file(w)) # age it into the past
      old = Notify.pending([w])[w]
      Notify.mark(w) # re-notify
      assert Notify.pending([w])[w] > old, "re-notifying re-touches the marker to a fresher mtime"
    end

    def test_a_vanished_worktree_is_gced
      w = wt("temp")
      Notify.mark(w)
      FileUtils.rm_rf(w)
      assert_empty Notify.pending([w]), "dir gone -> not pending"
      refute File.exist?(marker_file(w)), "...and the marker is GC'd, so the store can't grow"
    end

    def test_clear_all_wipes_every_marker
      a = wt("a")
      b = wt("b")
      Notify.mark(a)
      Notify.mark(b)
      Notify.clear_all
      assert_empty Notify.pending([a, b])
    end

    def test_pending_degrades_to_empty
      assert_equal({}, Notify.pending([]), "no paths -> empty, never nil")
      assert_equal({}, Notify.pending([path("never-marked")]), "an unmarked path -> empty")
    end

    # Rename CLEARS the pending-alert marker (Rename.perform), unlike Attention/Monitoring
    # which carry. Carrying would mint a fresh mtime under the new realpath — where every
    # process has a nil cursor — replaying a FALSE "come look" for an already-consumed alert.
    # The bold rides Attention.carry, so a truly-pending alert keeps its durable signal;
    # only the best-effort sound is dropped.
    def test_clear_removes_the_marker
      w = wt
      Notify.mark(w)
      Notify.clear(w)
      refute File.exist?(marker_file(w)), "the marker is gone"
      assert_empty Notify.pending([w]), "and nothing is pending"
    end

    def test_clear_is_idempotent_when_absent
      assert_nil Notify.clear(path("never-marked")), "clearing a missing marker is a quiet no-op"
    end
  end
end
