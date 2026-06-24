# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The shared project-collapse store. Like AgentState's dots and Attention's
  # markers, these are tiny files on disk so every sidebar process folds the same
  # project — we drive them by collapsing/expanding names in the sandbox and
  # asserting on the collapsed set, so the atomic write and GC run for real.
  class CollapseTest < SandboxTest
    def test_collapse_then_collapsed_includes_the_project
      Collapse.collapse("acme")
      assert_includes Collapse.collapsed, "acme"
    end

    def test_expand_unfolds
      Collapse.collapse("acme")
      Collapse.expand("acme")
      refute_includes Collapse.collapsed, "acme"
    end

    def test_expand_is_idempotent_when_already_unfolded
      assert_nil Collapse.expand("acme"), "expanding a missing fold is a quiet no-op"
      assert_empty Collapse.collapsed
    end

    def test_collapse_ignores_a_blank_name
      Collapse.collapse("")
      assert_empty Collapse.collapsed, "a blank project name can't seed a junk fold"
    end

    # Two distinct projects fold independently; the store is a set of names.
    def test_independent_projects
      Collapse.collapse("alpha")
      Collapse.collapse("beta")
      assert_equal %w[alpha beta].to_set, Collapse.collapsed
    end

    # The cross-process guarantee: a fold written by one "process" is visible to a
    # second read (every sidebar reads the same files).
    def test_a_fold_is_visible_on_a_later_read
      Collapse.collapse("shared")
      assert_includes Collapse.collapsed(%w[shared]), "shared"
    end

    # GC: a fold for a project no longer in the configured list is cleaned up, so
    # the dir can't grow without bound as projects come and go.
    def test_collapsed_garbage_collects_a_fold_for_a_removed_project
      Collapse.collapse("gone")
      Collapse.collapse("kept")
      assert_equal %w[kept].to_set, Collapse.collapsed(%w[kept])
      assert_equal %w[kept].to_set, Collapse.collapsed(%w[kept]),
                   "the GC'd fold stays gone on the next read"
    end

    # GC is guarded: an empty/nil known list (a transient config failure) must NOT
    # wipe a user's folds — we can't tell "no projects configured" from "config
    # failed to load this cycle", so the safe choice is to keep them.
    def test_collapsed_keeps_folds_when_known_is_empty_or_nil
      Collapse.collapse("safe")
      assert_includes Collapse.collapsed([]), "safe", "empty known list never GCs"
      assert_includes Collapse.collapsed(nil), "safe", "nil known list never GCs"
    end

    # A torn mid-write read (a peer's atomic write not yet renamed in) reads empty;
    # it must be SKIPPED this cycle, never deleted. Mirrors Attention/AgentState.
    def test_collapsed_skips_an_empty_marker_without_deleting_it
      FileUtils.mkdir_p(Collapse.state_dir)
      f = File.join(Collapse.state_dir, "torn")
      File.write(f, "")
      assert_empty Collapse.collapsed
      assert File.exist?(f), "an empty (torn) read is skipped this cycle, never deleted"
    end

    # The atomic write lands as <key>.<pid>.tmp before the rename; a scan that
    # catches one (or a crash leftover) must not read it as a fold.
    def test_collapsed_ignores_an_inflight_tmp_file
      FileUtils.mkdir_p(Collapse.state_dir)
      File.write(File.join(Collapse.state_dir, "deadbeef.999.tmp"), "acme")
      assert_empty Collapse.collapsed, "an in-flight/leftover .tmp is never a fold"
    end

    def test_collapsed_is_empty_with_no_state_dir
      assert_empty Collapse.collapsed, "no dir yet -> nothing folded, no raise"
    end
  end
end
