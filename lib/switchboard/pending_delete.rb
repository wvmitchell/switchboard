# frozen_string_literal: true

require "set"
require_relative "keyed_marker_store"

module Switchboard
  # Per-worktree "this workspace is being deleted right now" markers. `Sidebar#delete`
  # hands the slow `git worktree remove` to a detached daemon (see CLI#reap_worktree)
  # so the input loop never blocks; a marker written here lets EVERY window's sidebar
  # hide the row immediately (the delete feels instant) while the removal runs in the
  # background. The daemon clears the marker when it finishes.
  #
  # A KeyedMarkerStore like Monitoring/Attention (the on-disk, cross-process
  # write/scan machinery lives there — a shared marker is the only thing several
  # sidebar processes can agree on). Two things are specific here:
  #
  #   - Keyed by the RAW worktree path, NOT its realpath. Every input is git's own
  #     `git worktree list` path (the sidebar marks node.path, the daemon clears the
  #     same argv path, the render filter tests node.path) — one canonical source, so
  #     no canonicalization is needed. Realpath would be actively WRONG here: the dir
  #     is being removed, so `File.realpath` would raise mid-removal and degrade to the
  #     raw path anyway.
  #   - Liveness is a plain mtime TTL and NOTHING ELSE — in particular NOT a
  #     `Dir.exist?` gate (unlike Monitoring). The whole point is that the directory is
  #     disappearing; gating on its existence would un-hide the row the instant the
  #     daemon starts deleting. The daemon's explicit `clear` handles the normal
  #     success/failure convergence; the TTL is only the backstop for a daemon that
  #     crashes before clearing (rare) — sized well above any realistic removal time so
  #     it never un-hides a still-in-progress delete.
  module PendingDelete
    module_function

    # Backstop only. The daemon clears the marker on completion (success ⇒ the row is
    # gone from git anyway; failure ⇒ the row must reappear), so this TTL fires just
    # when the daemon dies mid-remove without clearing. 5 min is far above even a
    # huge-monorepo `git worktree remove`, so a legitimately-slow delete never flickers
    # the row back; a crashed daemon's stale hide clears within it.
    TTL = 300

    # Mark a worktree as being deleted (hides its row everywhere). Idempotent.
    def mark(path)
      return if path.nil? || path.empty?

      KeyedMarkerStore.write(state_dir, key(path), path)
    end

    # Clear a worktree's marker — the daemon calls this when the removal finishes
    # (success or failure). Idempotent (a missing marker is a no-op).
    def clear(path)
      return if path.nil? || path.empty?

      KeyedMarkerStore.delete(state_dir, key(path))
    end

    # Wipe every marker. Rides `quit` beside AgentState/Monitoring/Notify.clear_all:
    # tearing down all sessions makes any in-flight delete's UI-hide moot (the daemon
    # keeps running and finishes the removal regardless; this just drops the markers so
    # a relaunch never hides a workspace that's genuinely still there).
    def clear_all
      Dir.glob(File.join(state_dir, "*")).each do |file|
        File.delete(file) if File.file?(file)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # The subset of `paths` currently marked for deletion (fresh within TTL). Scans the
    # whole store so stale markers GC everywhere, then intersects — the render filter
    # tests node.path directly against this set. `now` injectable for tests.
    def pending(paths, now: Time.now)
      live = live_paths(now)
      paths.select { |p| live.include?(p) }.to_set
    end

    # Set of marked paths still fresh (mtime within TTL); GCs the rest. No Dir.exist?
    # gate — see the module note (the dir is being removed on purpose).
    def live_paths(now = Time.now)
      KeyedMarkerStore.scan(state_dir) { |_content, mtime| (now - mtime) <= TTL }
    end

    def key(path)
      KeyedMarkerStore.key(path)
    end

    # Same XDG-rooted home as the other marker stores, a sibling leaf.
    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_PENDING_DELETE_DIR", "pending-delete")
    end
  end
end
