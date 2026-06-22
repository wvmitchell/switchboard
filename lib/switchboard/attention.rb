# frozen_string_literal: true

require "set"
require "zlib"
require "fileutils"

module Switchboard
  # Per-worktree "needs attention" markers behind the sidebar's bold highlight. A
  # workspace is marked when a hooked agent newly finishes a turn (:done) or asks
  # for input (:waiting) — the same completion edge that rings the sound — and
  # unmarked the moment you view it (switch into its session). The bold persists
  # until then, so a completion you weren't watching can't slip past unnoticed.
  #
  # State lives on disk, NOT in a sidebar ivar, because every window's sidebar is
  # its own process: only a shared, on-disk flag renders bold consistently across
  # all of them — the same reason the agent dots read hook files (see AgentState).
  # mark/clear are a single file create/delete, so the several sidebar processes
  # that may touch one path at once never race on a read-modify-write.
  module Attention
    module_function

    # Mark a worktree as needing attention. Gated on the dir existing so a stale
    # path can't seed a junk marker — scan's GC is then the only cleanup needed.
    # Stores the canonical path as the content, keyed by a stable digest of it.
    # Written atomically (temp + rename) so a racing sidebar's scan never reads a
    # half-written marker — same self-healing trick as Hook.ensure_script and the
    # synthesized WAVs, the established pattern for our multi-process state files.
    def mark(path)
      real = realpath(path)
      return unless real && Dir.exist?(real)

      FileUtils.mkdir_p(state_dir)
      file = File.join(state_dir, key(real))
      tmp = "#{file}.#{Process.pid}.tmp"
      File.write(tmp, real)
      File.rename(tmp, file) # atomic on the same fs
    rescue StandardError
      nil
    end

    # Clear a worktree's mark — it's been viewed. Idempotent (a missing marker is
    # a no-op), so locate can clear unconditionally on every switch-in.
    def clear(path)
      real = realpath(path) or return

      File.delete(File.join(state_dir, key(real)))
    rescue StandardError
      nil
    end

    # The subset of the given worktree paths that are currently marked, keyed by
    # the RAW input path so the renderer can test node.path directly. Canonicalizes
    # both sides (like AgentState) so a symlinked worktree root still matches.
    def marked(worktree_paths)
      live = scan
      worktree_paths.select { |p| live.include?(realpath(p)) }.to_set
    end

    # All marked worktree paths (canonicalized). Self-healing: a marker whose
    # worktree is gone is deleted, so the dir can't grow without bound — mirrors
    # AgentState's hook-file GC.
    def scan
      Dir.glob(File.join(state_dir, "*")).each_with_object(Set.new) do |file, set|
        next if file.end_with?(".tmp") # an in-flight (or crashed) atomic write — never a marker

        path = File.read(file).chomp
        next if path.empty? # a torn read: skip this cycle, don't delete — mark rewrites atomically

        if Dir.exist?(path)
          set << path
        else
          File.delete(file) # a fully-written marker whose worktree is gone -> GC
        end
      rescue StandardError
        next
      end
    rescue StandardError
      Set.new
    end

    # True if two paths resolve to the same worktree dir — the test the marking
    # skip uses to leave the workspace you're sitting in alone (edge paths arrive
    # realpath'd from the hook, the located path raw from git).
    def same_path?(one, two)
      real = realpath(one)
      !real.nil? && real == realpath(two)
    end

    # Stable, per-process-independent filename for a path. crc32 (like the hook's
    # cksum) is plenty for this tiny set, and the path is stored as the content, so
    # a collision would at worst cost a marker, never mismatch a worktree.
    def key(path)
      Zlib.crc32(path).to_s(16)
    end

    # Same XDG-rooted home as the agent-state dir, a sibling leaf. Resolved from
    # ENV per call (not frozen at load) so the test sandbox can redirect it.
    def state_dir
      File.expand_path(
        ENV["SWITCHBOARD_ATTENTION_DIR"] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", "attention")
      )
    end

    def realpath(path)
      return nil if path.nil? || path.empty?

      File.realpath(path)
    rescue StandardError
      path
    end
  end
end
