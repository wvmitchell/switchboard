# frozen_string_literal: true

require "set"
require_relative "keyed_marker_store"

module Switchboard
  # Per-PROJECT collapse state behind the sidebar's ▸/▾ fold (a collapsed project
  # hides its workspace rows). A KeyedMarkerStore keyed by the project name (see there
  # for the on-disk, cross-process write/scan/GC machinery). Unlike the attention
  # markers, this is a durable VIEW PREFERENCE, so it is deliberately NOT cleared on
  # quit: a project you folded stays folded across restarts.
  #
  # The domain wrinkle is GC: the key is a name, not a checkable path, so we can't
  # self-heal off the filesystem the way Attention's dead-worktree GC does. Instead
  # collapsed GCs a fold against the live project list — but ONLY when that list is
  # actually populated, so a transient empty/failed config can't wipe a user's folds.
  module Collapse
    module_function

    # Fold a project.
    def collapse(project)
      name = project.to_s
      return if name.empty?

      KeyedMarkerStore.write(state_dir, key(name), name)
    end

    # Unfold a project. Idempotent — a missing fold is a quiet no-op, so a toggle can
    # call it unconditionally on the expand edge.
    def expand(project)
      KeyedMarkerStore.delete(state_dir, key(project.to_s))
    end

    # The set of currently-collapsed project names. Given the live (configured) project
    # names, GCs a fold whose project is gone so the dir can't grow without bound — but
    # ONLY when `known` is actually populated (the guard above), so a transient
    # empty/failed config never wipes a user's folds. The keep?-predicate encodes that:
    # keep unless we have a populated `known` that excludes this name.
    def collapsed(known = nil)
      gc = known.is_a?(Array) && !known.empty? ? known.map(&:to_s).to_set : nil
      KeyedMarkerStore.scan(state_dir) { |name| !(gc && !gc.include?(name)) }
    end

    def key(name)
      KeyedMarkerStore.key(name)
    end

    # XDG-state-rooted, a sibling of the attention markers.
    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_COLLAPSE_DIR", "collapse")
    end
  end
end
