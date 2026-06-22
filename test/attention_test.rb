# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The bold "needs attention" markers. Like AgentState's dots, these are tiny
  # files on disk (shared, so every sidebar process bolds the same rows); we drive
  # them by marking/clearing real dirs in the sandbox and asserting on the marked
  # set, so the canonicalization and garbage-collection run for real.
  class AttentionTest < SandboxTest
    # A real (existing, canonicalized) worktree dir — mark stores the realpath.
    def wt(sub = "wt")
      d = path(sub)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def test_mark_then_marked_includes_the_path
      w = wt
      Attention.mark(w)
      assert_includes Attention.marked([w]), w
    end

    def test_clear_unmarks
      w = wt
      Attention.mark(w)
      Attention.clear(w)
      refute_includes Attention.marked([w]), w
    end

    def test_clear_is_idempotent_when_already_unmarked
      w = wt
      assert_nil Attention.clear(w), "clearing a missing marker is a quiet no-op"
      assert_empty Attention.marked([w])
    end

    def test_mark_is_a_noop_for_a_nonexistent_dir
      ghost = path("ghost") # never created
      Attention.mark(ghost)
      assert_empty Attention.marked([ghost]), "a stale path can't seed a junk marker"
    end

    # marked() echoes back the path you pass, even a symlinked alias of the
    # canonical worktree, so the renderer can test node.path directly.
    def test_marked_keys_by_the_raw_input_path
      w = wt("real")
      File.symlink(w, path("alias"))
      Attention.mark(w)
      assert_includes Attention.marked([path("alias")]), path("alias")
    end

    def test_scan_garbage_collects_a_dead_worktrees_marker
      w = wt("doomed")
      Attention.mark(w)
      FileUtils.remove_entry(w)
      assert_empty Attention.scan, "a marker whose worktree is gone is cleaned up"
    end

    # A torn mid-write read (a peer's atomic write not yet renamed in) reads as
    # empty — it must be SKIPPED this cycle, never deleted, or a racing scan would
    # erase the very completion the bold exists to surface. Mirrors AgentState's
    # torn-write handling (read_hooks skips, never deletes).
    def test_scan_skips_an_empty_marker_without_deleting_it
      FileUtils.mkdir_p(Attention.state_dir)
      f = File.join(Attention.state_dir, "torn")
      File.write(f, "")
      assert_empty Attention.scan
      assert File.exist?(f), "an empty (torn) read is skipped this cycle, never deleted"
    end

    # The atomic write lands as <key>.<pid>.tmp before the rename; a scan that
    # catches one (or a crash leftover) must not read it as a marker.
    def test_scan_ignores_an_inflight_tmp_file
      w = wt("live")
      FileUtils.mkdir_p(Attention.state_dir)
      File.write(File.join(Attention.state_dir, "deadbeef.999.tmp"), w)
      assert_empty Attention.scan, "an in-flight/leftover .tmp is never a marker"
    end

    def test_same_path_matches_through_a_symlink
      w = wt("canon")
      File.symlink(w, path("link"))
      assert Attention.same_path?(path("link"), w), "a symlinked alias is the same worktree"
      refute Attention.same_path?(w, wt("other"))
    end

    def test_marked_is_empty_with_no_state_dir
      assert_empty Attention.marked([path("whatever")]), "no dir yet -> nothing marked, no raise"
    end
  end
end
