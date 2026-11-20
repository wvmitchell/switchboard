# frozen_string_literal: true

require_relative "../support/keyed_marker_store"
require_relative "../support/paths"

module Switchboard
  # Where a workspace you moved with J/K sits in its project. Rows sort by a rank,
  # highest first: by default the time git created the worktree (Git.created_at), so the
  # newest is on top. A move writes the moved workspace's own rank here, between its new
  # neighbours, so one keypress is one atomic write and two sidebars never
  # read-modify-write a shared list. Unmoved workspaces have no entry.
  #
  # A KeyedMarkerStore keyed by realpath; each marker is "realpath<TAB>rank". The rank is
  # epoch-scale seconds, written with Float#to_s (shortest round-trip, never rounded: a
  # midpoint between two neighbours can sit far below a millisecond).
  module Order
    module_function

    STEP = 0.001          # past the end of a project, and between renumbered ranks
    MAX_RANK = 1e11       # epoch scale; anything beyond would swallow STEP
    GC_AGE = 30 * 86_400  # a missing folder keeps its place this long (an unmounted volume)

    # { realpath => rank } of every usable entry. GCs entries whose folder has been gone
    # GC_AGE; delete removes them at once through Leftovers. Never raises: Model reads
    # this in hook commands, which must stay silent.
    def ranks(now: Time.now)
      live = KeyedMarkerStore.scan(state_dir) do |content, mtime|
        Dir.exist?(content.split("\t").first.to_s) || now - mtime < GC_AGE
      end
      live.each_with_object({}) do |content, out|
        path, raw = content.split("\t", 2)
        rank = parse(raw)
        out[path] = rank if rank && !path.to_s.empty?
      end
    rescue StandardError
      {}
    end

    # nil on success, or why the write failed.
    def set(path, rank)
      real = Paths.real_or_self(path)
      KeyedMarkerStore.write!(state_dir, key(real), "#{real}\t#{Float(rank)}")
    end

    def clear(path)
      KeyedMarkerStore.delete(state_dir, key(Paths.real_or_self(path)))
    end

    def parse(raw)
      rank = Float(raw.to_s.strip)
      rank if usable?(rank)
    rescue ArgumentError, TypeError
      nil
    end

    def usable?(rank)
      rank.is_a?(Float) && rank.finite? && rank >= 0 && rank < MAX_RANK
    end

    def key(real) = KeyedMarkerStore.key(real)

    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_ORDER_DIR", "order")
    end
  end
end
