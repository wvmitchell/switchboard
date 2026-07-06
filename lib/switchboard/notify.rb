# frozen_string_literal: true

require_relative "keyed_marker_store"

module Switchboard
  # Per-worktree "come look — this monitor cycle surfaced something" markers behind
  # the sidebar's declared ALERT cue (`switchboard monitoring notify`). A background
  # monitor's routine :done ticks are deliberately suppressed (Edges#suppress_completion?),
  # so a cycle that actually found something would otherwise pass silently. The agent
  # DECLARES the significant tick with `monitoring notify`; this marker is how that
  # declaration reaches the sidebar's announce-gated sound + sparkle. (The persistent
  # BOLD is written directly into Attention by the CLI, so it survives even when no
  # sidebar is on screen — this marker only drives the ring/twinkle.)
  #
  # A KeyedMarkerStore twin of Attention (see there for the on-disk, cross-process
  # write/scan/GC machinery). Byte-identical shape — content is the canonical realpath —
  # but read differently: the file MTIME is the signal. Writing (re-notifying) re-touches
  # the marker → fresh mtime; each sidebar process compares that mtime against its own
  # cursor (Edges#@prev_notify) and rings once per advance. Same "compare-to-your-own-
  # cursor" once-only trick the completion sound uses, so only the on-screen pane rings
  # and catch-up scans stay silent — with no delete race (nobody deletes on read).
  #
  # No TTL: the marker persists until the worktree is gone (dir-GC), teardown wipes it
  # (clear_all), or a rename clears it. (Consumption itself is per-process — each sidebar's
  # mtime cursor — so the on-disk marker outlives a single ring; that's fine, the cursor
  # prevents a re-ring within a process, and a fresh process seeds silently on first scan.)
  # The
  # SOUND is announce-gated, so it rings only from a while-visible scan: if you're watching
  # the sidebar when the monitor surfaces something, it chimes; if you're fully away (no
  # visible pane) or a fresh sidebar seeds its cursor on first scan, the sound is missed —
  # by design. The BOLD is the durable guarantee (the CLI writes Attention directly, which
  # persists until viewed and is carried across rename), so a missed sound never means a
  # missed alert.
  module Notify
    module_function

    # Declare a "come look" for a worktree — write (or re-touch) its marker, giving it a
    # fresh mtime that the sidebar reads as "newer than last time → ring". Gated on the
    # dir existing so a stale path can't seed a junk marker. Idempotent; re-notifying just
    # bumps the mtime. Content is the realpath (like Attention), keyed by its digest.
    def mark(path)
      real = realpath(path)
      return unless real && Dir.exist?(real)

      KeyedMarkerStore.write(state_dir, key(real), real)
    end

    # Wipe every marker. Called on `quit` beside AgentState/Monitoring.clear_all: tearing
    # down every sb/ session kills the agents, so their pending alerts are moot. Per-file
    # isolated and fully rescued.
    def clear_all
      Dir.glob(File.join(state_dir, "*")).each do |file|
        File.delete(file) if File.file?(file)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # The pending notifies among the given worktree paths, as { raw_path => mtime }. Keyed
    # by the RAW input path (like Attention.marked / Monitoring.monitored) so every
    # downstream consumer — project_for_path for the sound, and the @prev_notify cursor —
    # keys on node.path directly. The mtime is the per-marker signal the cursor diffs.
    # Fully rescued to {} so a disk fault can't trip refresh_agents' broad rescue and blank
    # every dot for a scan.
    def pending(paths)
      live = live_mtimes
      paths.each_with_object({}) do |p, out|
        mtime = live[realpath(p)]
        out[p] = mtime if mtime
      end
    rescue StandardError
      {}
    end

    # { realpath => mtime } for every live marker, GC'ing any whose worktree is gone. Reuses
    # KeyedMarkerStore.scan (atomic-write / torn-read / .tmp safety) and captures the mtime
    # the scan already hands the predicate — a side effect, but it's the only way to get
    # both the survivor set AND its mtimes from the shared scan. Dir.exist? is the GC policy
    # (a filesystem fact, so a transient failure can never falsely wipe the store).
    def live_mtimes
      mtimes = {}
      KeyedMarkerStore.scan(state_dir) do |real, mtime|
        keep = Dir.exist?(real)
        mtimes[real] = mtime if keep
        keep
      end
      mtimes
    end

    # Clear a worktree's pending-alert marker. Idempotent (a missing marker is a no-op).
    # Rename CLEARS rather than carries (unlike Attention/Monitoring): the marker can't tell
    # a genuinely-pending alert from a long-consumed one — consumption lives only in each
    # process's mtime cursor, never on disk — so carrying it (which mints a fresh mtime under
    # the new realpath, where every process has a nil cursor) would replay a FALSE "come
    # look" for an event that already happened, right when the agent renames from inside the
    # workspace. Clearing also disposes of the old-realpath marker the bridge symlink would
    # otherwise keep alive forever (Dir.exist? true → never GC'd). The bold is the durable
    # signal and IS carried (Attention.carry), so a truly-pending alert keeps its bold across
    # the rename; only its best-effort sound is dropped — the sound-is-best-effort contract.
    def clear(path)
      real = realpath(path) or return

      KeyedMarkerStore.delete(state_dir, key(real))
    end

    def key(path)
      KeyedMarkerStore.key(path)
    end

    # Same XDG-rooted home as the agent-state / attention / monitoring dirs, a sibling leaf.
    def state_dir
      KeyedMarkerStore.dir("SWITCHBOARD_NOTIFY_DIR", "notify")
    end

    def realpath(path)
      return nil if path.nil? || path.empty?

      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
