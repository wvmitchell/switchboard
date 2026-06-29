# frozen_string_literal: true

require "fileutils"

module Switchboard
  # The global "fold every workspace's branch-history rows" toggle (the `z` key).
  # A workspace that has held more than one branch expands into inline child
  # branch rows (Tree.nodes / Git.branch_history — the multiple-PRs-per-workspace
  # case). Those rows are useful occasionally and noise usually, so `z` flips them
  # all at once: folded ⇒ every multi-branch workspace shows just its own row
  # (with its own diff/PR badge restored — issue #107).
  #
  # This is a SINGLE global flag, not a per-workspace fold: pressing `z` anywhere
  # folds/unfolds the whole tree regardless of the cursor. So it's modeled exactly
  # like FullHeader (a single marker file whose mere existence is the flag), NOT
  # like Collapse (a per-project KeyedMarkerStore). State lives on disk, NOT in a
  # sidebar ivar, for the same reason Collapse/FullHeader/Width do: every window's
  # sidebar is its own process, so only a shared on-disk flag folds the same in all
  # of them (and survives a respawn). Like those, it is a durable VIEW PREFERENCE —
  # deliberately NOT cleared on quit. Default OFF ⇒ branches show, matching the
  # always-expanded behavior before #107, so nothing changes until you press `z`.
  #
  # Because only existence is read (never the contents), a torn write can't misread,
  # so no temp+rename dance is needed (unlike Collapse/Width, which read a value).
  module BranchFold
    module_function

    # Folded when the marker exists. Degrades to off (branches shown) on any error —
    # a sidebar that can't read the flag just renders the tree expanded, never crashes.
    def folded?
      File.exist?(marker)
    rescue StandardError
      false
    end

    # Fold every workspace's branches. Idempotent create — re-folding stays folded.
    def fold
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "on")
    rescue StandardError
      nil
    end

    # Unfold. Idempotent — a missing marker is a quiet no-op, so a toggle can call
    # it unconditionally on the unfold edge.
    def unfold
      File.delete(marker)
    rescue StandardError
      nil
    end

    # The single marker file, XDG-state-rooted beside the collapse folds and the
    # full-header flag. Resolved from ENV per call (not frozen at load) so the test
    # sandbox can redirect it.
    def marker
      File.expand_path(
        ENV["SWITCHBOARD_BRANCH_FOLD_FILE"] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", "branch_fold")
      )
    end
  end
end
