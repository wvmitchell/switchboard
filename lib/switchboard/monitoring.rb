# frozen_string_literal: true

require "set"
require_relative "keyed_marker_store"

module Switchboard
  # Per-worktree "an agent is running a background monitor / recurring loop here"
  # markers behind the sidebar's steady ∞ dot. Declared by the agent (or a human)
  # with `switchboard monitoring on`, so an idle-between-ticks workspace reads as
  # *watching* rather than *finished* — the one thing a hook can't tell us, since a
  # background loop fires the same SessionStart/Stop events as an interactive turn.
  #
  # A KeyedMarkerStore keyed by the worktree realpath, like Attention (see there for
  # the on-disk, cross-process write/scan/GC machinery). What's specific here:
  #
  #   - It is NOT cleared-on-view (a durable declared state, not a bold-until-seen
  #     nudge) — it clears only on explicit `off`, `clear_all` (quit), the session
  #     boundaries (Layer 2), a vanished worktree, or the liveness TTL below.
  #   - It carries a LIVENESS clock. "The dot is up" must mean "monitoring is
  #     happening right now", and a marker only proves an agent DECLARED monitoring,
  #     not that it's STILL monitoring. So freshness is the signal: `monitoring on`
  #     (re)writes the marker (fresh mtime), the agent re-affirms it at the top of
  #     each cycle, and a marker not re-affirmed within TTL is stale — a stopped or
  #     crashed agent stops re-affirming, so its dot ages out on its own. This is why
  #     re-affirmation (not a generic hook heartbeat) is the liveness source: only a
  #     still-looping agent keeps calling `on`.
  module Monitoring
    module_function

    # Seconds a marker counts as live without a re-affirm. Must exceed the slowest
    # expected monitor cycle so a live loop doesn't flicker mid-cycle, yet stay short
    # enough that a stopped/crashed agent reaps promptly (quit / off / SessionEnd clear
    # instantly regardless). ~10 min = a couple of missed few-minute cycles.
    TTL = 600

    # Declare (or re-affirm) monitoring for a worktree. Writing refreshes the mtime,
    # which IS the re-affirmation — the liveness clock restarts each call. Gated on the
    # dir existing so a stale path can't seed a junk marker (scan's GC is the only other
    # cleanup then). Idempotent.
    def mark(path)
      real = realpath(path)
      return unless real && Dir.exist?(real)

      KeyedMarkerStore.write(state_dir, key(real), real)
    end

    # Stop monitoring a worktree — idempotent (a missing marker is a no-op), so `off`
    # and the session-boundary clears can fire unconditionally.
    def clear(path)
      real = realpath(path) or return

      KeyedMarkerStore.delete(state_dir, key(real))
    end

    # Wipe every marker. Called on `quit`: tearing down all sb/ sessions kills every
    # agent at once, so their monitoring declarations are now stale. Per-file isolated
    # and fully rescued; a restarted agent re-declares if it's still monitoring.
    def clear_all
      Dir.glob(File.join(state_dir, "*")).each do |file|
        File.delete(file) if File.file?(file)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # The LIVE monitored subset of the given worktree paths — marker present, worktree
    # still exists, AND re-affirmed within `ttl`. Keyed by the RAW input path (like
    # Attention.marked) so the renderer can test node.path directly. The scan GCs any
    # marker failing the dir/freshness test, so the store can't grow and "a marker
    # exists" converges to "it's live". `now` is injectable for tests.
    def monitored(paths, ttl: TTL, now: Time.now)
      live = live_paths(ttl, now)
      paths.select { |p| live.include?(realpath(p)) }.to_set
    end

    # Set of canonical paths with a fresh, dir-alive marker; GCs the rest. A stale
    # (past-ttl) marker is deleted, not just hidden — a still-live monitor re-affirms
    # and re-creates it, a stopped one stays gone. Self-healing, degrades to empty.
    def live_paths(ttl = TTL, now = Time.now)
      KeyedMarkerStore.scan(state_dir) { |path, mtime| Dir.exist?(path) && (now - mtime) <= ttl }
    end

    # Carry a marker across a rename (dir move changes the realpath key). old/new are
    # canonical paths captured by the caller — old BEFORE the move, new AFTER (the
    # bridge symlink makes realpath(old) resolve to new post-move). Delegates to the
    # shared helper; a fresh mtime on the new marker is correct (the rename is activity).
    def carry(old_real, new_real)
      KeyedMarkerStore.carry(state_dir, old_real, new_real)
    end

    def key(path)
      KeyedMarkerStore.key(path)
    end

    # Same XDG-rooted home as the agent-state / attention dirs, a sibling leaf.
    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_MONITORING_DIR", "monitoring")
    end

    def realpath(path)
      return nil if path.nil? || path.empty?

      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
