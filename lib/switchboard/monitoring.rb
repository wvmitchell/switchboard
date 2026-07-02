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

    # DEFAULT seconds a marker counts as live without a re-affirm, when the declaring
    # agent doesn't pick its own. Must exceed the slowest expected monitor cycle so a live
    # loop doesn't flicker mid-cycle, yet stay short enough that a stopped/crashed agent
    # reaps promptly (quit / off / SessionEnd clear instantly regardless). ~10 min = a
    # couple of missed few-minute cycles. A slower loop (e.g. a 30-min tick) overrides it
    # per-marker via `mark(ttl:)` — the agent owns its own cadence, so it sizes the window.
    TTL = 600

    # Declare (or re-affirm) monitoring for a worktree. Writing refreshes the mtime,
    # which IS the re-affirmation — the liveness clock restarts each call. Gated on the
    # dir existing so a stale path can't seed a junk marker (scan's GC is the only other
    # cleanup then). Idempotent.
    #
    # `ttl` (seconds) lets the DECLARING agent size the liveness window to its OWN cycle —
    # a 30-min loop passes ttl: 2400 so the dot doesn't go stale between ticks. It's
    # persisted IN the marker (freshness is judged at READ time, by the sidebar/status —
    # not here), so the reader honors the agent's number; absent or invalid falls back to
    # the TTL default. The content stays a bare realpath unless a ttl is given, so default
    # markers are byte-identical to before.
    def mark(path, ttl: nil)
      real = realpath(path)
      return unless real && Dir.exist?(real)

      KeyedMarkerStore.write(state_dir, key(real), encode(real, ttl))
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
    def monitored(paths, now: Time.now)
      live = live_paths(now)
      paths.select { |p| live.include?(realpath(p)) }.to_set
    end

    # Set of canonical paths with a fresh, dir-alive marker; GCs the rest. Freshness is
    # judged against EACH marker's own ttl (the agent-declared window, decoded from the
    # marker; default TTL when absent), so a long-cycle monitor stays live between ticks
    # while a short one still ages out on time. A stale (past-ttl) marker is deleted, not
    # just hidden — a still-live monitor re-affirms and re-creates it, a stopped one stays
    # gone. The scan yields raw content; we map survivors back to their realpath (dropping
    # the ttl suffix) so callers still match on node.path. Self-healing, degrades to empty.
    def live_paths(now = Time.now)
      survivors = KeyedMarkerStore.scan(state_dir) do |content, mtime|
        real, ttl = decode(content)
        Dir.exist?(real) && (now - mtime) <= ttl
      end
      survivors.map { |content| decode(content).first }.to_set
    end

    # Carry a marker across a rename (dir move changes the realpath key). old/new are
    # canonical paths captured by the caller — old BEFORE the move, new AFTER (the bridge
    # symlink makes realpath(old) resolve to new post-move). NOT a plain delegate to the
    # shared carry: that rewrites content to the new path only, which would DROP an
    # agent-declared ttl (a renamed 30-min monitor would revert to the default until its
    # next re-affirm — one long cycle of a wrongly-dark dot). So we read the old marker's
    # ttl and re-encode it onto the new key. A fresh mtime is correct (the rename is
    # activity). Fully rescued: a failed carry drops the marker rather than crash rename.
    def carry(old_real, new_real)
      dir = state_dir
      old_file = File.join(dir, key(old_real))
      return unless File.exist?(old_file)

      _real, ttl = decode(File.read(old_file).chomp)
      KeyedMarkerStore.write(dir, key(new_real), encode(new_real, ttl == TTL ? nil : ttl))
      KeyedMarkerStore.delete(dir, key(old_real))
    rescue StandardError
      nil
    end

    # Marker content encodes the realpath and, when the agent picked one, its ttl:
    # "<realpath>" (default window) or "<realpath>\t<seconds>". Kept bare unless a valid
    # positive ttl is given, so nothing changes for the common case.
    def encode(real, ttl)
      secs = positive_int(ttl)
      secs ? "#{real}\t#{secs}" : real
    end

    # Inverse of encode: [realpath, ttl_seconds]. Only a trailing "\t<positive int>" is a
    # ttl — split on the LAST tab and require digits — so a realpath that itself contains a
    # tab is never truncated (it reads as the whole content on the default window, matching
    # pre-ttl behavior). A missing/garbage ttl field decodes to the TTL default.
    def decode(content)
      head, sep, tail = content.rpartition("\t")
      ttl = positive_int(tail)
      sep.empty? || ttl.nil? ? [content, TTL] : [head, ttl]
    end

    # A strictly-positive Integer, else nil — the shared ttl guard for encode/decode and
    # the CLI, so an absent/zero/negative/non-numeric value uniformly falls to the default.
    def positive_int(value)
      n = Integer(value)
      n.positive? ? n : nil
    rescue StandardError
      nil
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
