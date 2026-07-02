# frozen_string_literal: true

require "set"
require "zlib"
require "fileutils"
require "tmpdir"

module Switchboard
  # The shared machinery behind the "keyed-marker" stores: a directory of tiny
  # files, one per tracked thing (a worktree path, a project name, …), named by a
  # stable digest of that thing and holding the thing itself as content. Two stores
  # sit on this today — Attention (bold-until-viewed) and Collapse (project folds) —
  # and a third arrives with #107 (per-workspace folds); rather than three near-copies
  # of the same write/scan/GC plumbing, they share it here (issue #95).
  #
  # The pattern exists because every window's sidebar is its own process: state that
  # several processes must agree on (and that must survive a respawn) has to live on
  # disk, not in a sidebar ivar — the same reason the agent dots read hook files (see
  # AgentState). All writes are atomic (temp + rename) so a peer's concurrent scan
  # never reads a half-written marker — the established self-healing trick (also
  # HookFile.ensure_script and the synthesized WAVs). Everything degrades to nil/empty
  # rather than raising, per the UI's degrade-never-crash convention.
  #
  # What stays in each caller (NOT here): its key DOMAIN — Attention canonicalizes
  # paths and is cleared-on-view; Collapse keys by name and is a durable preference —
  # and its GC POLICY, supplied to scan as a keep?-predicate over the marker content.
  module KeyedMarkerStore
    module_function

    # Stable, process-independent filename for the tracked value. crc32 is plenty for
    # these tiny sets, and the value is stored as the file's content, so a collision
    # would at worst cost/misplace one marker, never corrupt state. (.to_s so a
    # non-String value — e.g. a symbol project name — keys without raising.)
    def key(value)
      Zlib.crc32(value.to_s).to_s(16)
    end

    # The store's directory: an env override (so the test sandbox can redirect it) or
    # an XDG-state-rooted sibling leaf. Resolved from ENV per call, never frozen at
    # load, for that redirect to take effect.
    #
    # Total (never raises): callers evaluate state_dir as an argument OUTSIDE the
    # rescued ops below, so a raise here would escape where the pre-extraction
    # whole-method rescue used to swallow it. File.expand_path raises on a bad ~user
    # override (or ~ with no resolvable home) — unreachable in a working install — but
    # we fall back to a tmpdir sibling so the op degrades instead of crashing the
    # sidebar paint, preserving degrade-not-crash.
    def dir(env_var, leaf)
      File.expand_path(
        ENV[env_var] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", leaf)
      )
    rescue StandardError
      File.join(Dir.tmpdir, "switchboard", leaf)
    end

    # Write a marker atomically: a peer scanning mid-write sees either the old file or
    # the new one, never a torn read. Degrades to nil on any I/O failure (the bold/fold
    # just doesn't persist) rather than crashing the paint.
    def write(dir, key, content)
      FileUtils.mkdir_p(dir)
      file = File.join(dir, key)
      tmp = "#{file}.#{Process.pid}.tmp"
      File.write(tmp, content)
      File.rename(tmp, file) # atomic on the same fs
    rescue StandardError
      nil
    end

    # Delete a marker. Idempotent — a missing file is a quiet no-op (rescued), so a
    # caller can clear/expand unconditionally on the relevant edge.
    def delete(dir, key)
      File.delete(File.join(dir, key))
    rescue StandardError
      nil
    end

    # Scan the store, returning the Set of live marker CONTENTS. The caller's block is
    # the GC policy: it receives each marker's content (and its mtime as a second arg,
    # for callers like Monitoring that GC on freshness — one-arg blocks just ignore it)
    # and returns whether to KEEP it.
    #
    # CAUTION — a falsy return DELETES that marker (garbage collection). Guard any
    # TRANSIENT input in your predicate, or a momentary model/config-load failure will
    # GC the whole store at once: Collapse only GCs when its `known` project list is
    # actually populated for exactly this reason; #107's predicate must carry the same
    # guard. Attention is safe because its predicate (`Dir.exist?`) is a filesystem fact.
    #
    # An in-flight/leftover ".tmp" is never a marker, and an empty (torn) read is
    # SKIPPED this cycle — never deleted, or a racing scan would erase the very state
    # the marker exists to hold (the atomic write rewrites it intact next time). Both
    # of these are handled BEFORE the block, so the keep?-predicate only ever sees a
    # real, fully-written value. Per-file failures skip that file; a broken store
    # degrades to an empty Set rather than raising.
    def scan(dir)
      Dir.glob(File.join(dir, "*")).each_with_object(Set.new) do |file, set|
        next if file.end_with?(".tmp") # an in-flight (or crashed) atomic write — never a marker

        content = File.read(file).chomp
        next if content.empty? # a torn read: skip this cycle, don't delete — write rewrites atomically

        if yield(content, File.mtime(file))
          set << content
        else
          File.delete(file) # the caller's GC policy rejected it -> remove
        end
      rescue StandardError
        next
      end
    rescue StandardError
      Set.new
    end

    # Move a marker from one key to another — used to carry a path-keyed marker across a
    # worktree rename, where the key (a realpath) changes but the marker should survive.
    # A no-op when nothing is stored at old_value. The content is rewritten to new_value
    # so the marker's stored path matches its new location, and the write is atomic
    # (temp+rename) like every other, so a peer scan never catches a torn carry. Fully
    # rescued: a failed carry drops the marker rather than crash the rename.
    def carry(dir, old_value, new_value)
      return unless File.exist?(File.join(dir, key(old_value)))

      write(dir, key(new_value), new_value)
      delete(dir, key(old_value))
    rescue StandardError
      nil
    end
  end
end
