# frozen_string_literal: true

require "set"
require_relative "keyed_marker_store"

module Switchboard
  # Per-worktree "needs attention" markers behind the sidebar's bold highlight. A
  # workspace is marked when a hooked agent newly finishes a turn (:done) or asks
  # for input (:waiting) — the same completion edge that rings the sound — and
  # unmarked the moment you view it (switch into its session). The bold persists
  # until then, so a completion you weren't watching can't slip past unnoticed.
  #
  # A KeyedMarkerStore keyed by the worktree path (see there for the on-disk,
  # cross-process write/scan/GC machinery and why it lives on disk). What's specific
  # here: the value is a canonicalized realpath (so a symlinked worktree root still
  # matches), and GC is "the worktree dir still exists" — a filesystem fact, so the
  # scan predicate can never falsely wipe a live marker.
  module Attention
    module_function

    # Mark a worktree as needing attention. Gated on the dir existing so a stale path
    # can't seed a junk marker — scan's GC is then the only cleanup needed. Stores the
    # canonical path as the content, keyed by a stable digest of it.
    def mark(path)
      real = realpath(path)
      return unless real && Dir.exist?(real)

      KeyedMarkerStore.write(state_dir, key(real), real)
    end

    # Clear a worktree's mark — it's been viewed. Idempotent (a missing marker is a
    # no-op), so locate can clear unconditionally on every switch-in.
    def clear(path)
      real = realpath(path) or return

      KeyedMarkerStore.delete(state_dir, key(real))
    end

    # The subset of the given worktree paths that are currently marked, keyed by the
    # RAW input path so the renderer can test node.path directly. Canonicalizes both
    # sides (like AgentState) so a symlinked worktree root still matches.
    def marked(worktree_paths)
      live = scan
      worktree_paths.select { |p| live.include?(realpath(p)) }.to_set
    end

    # All marked worktree paths (canonicalized). Self-healing: a marker whose worktree
    # is gone is GC'd by the store, so the dir can't grow without bound.
    def scan
      KeyedMarkerStore.scan(state_dir) { |path| Dir.exist?(path) }
    end

    # True if two paths resolve to the same worktree dir — the test the marking skip
    # uses to leave the workspace you're sitting in alone (edge paths arrive realpath'd
    # from the hook, the located path raw from git).
    def same_path?(one, two)
      real = realpath(one)
      !real.nil? && real == realpath(two)
    end

    def key(path)
      KeyedMarkerStore.key(path)
    end

    # Same XDG-rooted home as the agent-state dir, a sibling leaf.
    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_ATTENTION_DIR", "attention")
    end

    def realpath(path)
      return nil if path.nil? || path.empty?

      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
