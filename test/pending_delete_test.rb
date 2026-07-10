# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The being-deleted row-hide markers. Tiny shared files like Monitoring/Attention,
  # driven against the real store in the sandbox. The load-bearing difference from
  # Monitoring: liveness is a plain mtime TTL with NO Dir.exist? gate — the dir is
  # being removed on purpose, so a gone dir must NOT un-hide the row.
  class PendingDeleteTest < SandboxTest
    def marker_file(p)
      File.join(PendingDelete.state_dir, PendingDelete.key(p))
    end

    def test_mark_then_pending_includes_the_path
      PendingDelete.mark("/wt/a")
      assert_includes PendingDelete.pending(["/wt/a"]), "/wt/a"
    end

    def test_clear_stops_hiding
      PendingDelete.mark("/wt/a")
      PendingDelete.clear("/wt/a")
      refute_includes PendingDelete.pending(["/wt/a"]), "/wt/a"
    end

    # The crux: the worktree dir is being deleted, so the marker must keep hiding the
    # row even with the dir gone — unlike Monitoring, which requires the dir to exist.
    def test_marker_hides_even_though_the_directory_is_gone
      PendingDelete.mark("/wt/already-removed") # a path with no dir on disk
      assert_includes PendingDelete.pending(["/wt/already-removed"]), "/wt/already-removed",
                      "a gone dir must NOT un-hide the row (no Dir.exist? gate)"
    end

    def test_pending_returns_only_queried_marked_paths
      PendingDelete.mark("/wt/a")
      assert_equal Set["/wt/a"], PendingDelete.pending(["/wt/a", "/wt/b"])
    end

    def test_clear_all_wipes_every_marker
      PendingDelete.mark("/wt/a")
      PendingDelete.mark("/wt/b")
      PendingDelete.clear_all
      assert_empty PendingDelete.pending(["/wt/a", "/wt/b"])
    end

    def test_mark_and_clear_are_blank_safe_and_idempotent
      assert_nil PendingDelete.mark(nil)
      assert_nil PendingDelete.mark("")
      assert_nil PendingDelete.clear("never-marked")
      assert_empty PendingDelete.pending([])
    end

    # The daemon-crash backstop: a marker older than TTL un-hides the row and is GC'd,
    # so a reaper that died mid-remove never hides a workspace forever.
    def test_a_stale_marker_un_hides_and_is_gced
      PendingDelete.mark("/wt/a")
      old = Time.now - PendingDelete::TTL - 60
      File.utime(old, old, marker_file("/wt/a"))
      assert_empty PendingDelete.pending(["/wt/a"]), "past TTL ⇒ no longer hidden"
      refute File.exist?(marker_file("/wt/a")), "and the stale marker is GC'd, not just hidden"
    end

    # A generous TTL means a legitimately-slow removal never flickers the row back:
    # just inside the window, still hidden.
    def test_a_marker_within_ttl_still_hides
      PendingDelete.mark("/wt/a")
      recent = Time.now - PendingDelete::TTL + 30
      File.utime(recent, recent, marker_file("/wt/a"))
      assert_includes PendingDelete.pending(["/wt/a"]), "/wt/a"
    end
  end
end
