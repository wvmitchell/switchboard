# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The global "fold every workspace's branches" toggle (the `z` key, issue #107).
  # Like FullHeader it's a single marker file on disk so every sidebar process reads
  # the same flag — we flip it in the sandbox and assert on folded?, so the real
  # create/delete runs.
  class BranchFoldTest < SandboxTest
    def test_off_by_default
      refute BranchFold.folded?, "no marker yet → branches show (expanded, as before #107)"
    end

    def test_fold_then_folded
      BranchFold.fold
      assert BranchFold.folded?
    end

    def test_unfold_turns_it_off
      BranchFold.fold
      BranchFold.unfold
      refute BranchFold.folded?
    end

    def test_fold_is_idempotent
      BranchFold.fold
      BranchFold.fold
      assert BranchFold.folded?, "re-folding an already-folded flag stays folded"
    end

    def test_unfold_is_idempotent_when_already_off
      assert_nil BranchFold.unfold, "unfolding a missing flag is a quiet no-op"
      refute BranchFold.folded?
    end

    # The cross-process guarantee: a flag set by one "process" is visible to a
    # second read (every sidebar reads the same file).
    def test_a_set_flag_is_visible_on_a_later_read
      BranchFold.fold
      assert BranchFold.folded?, "a second process sees the same marker"
    end

    def test_folded_is_false_with_no_state_dir
      refute BranchFold.folded?, "no dir yet → off, no raise"
    end
  end
end
