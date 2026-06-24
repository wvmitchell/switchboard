# frozen_string_literal: true

require "set"
require "zlib"
require "fileutils"

module Switchboard
  # Per-PROJECT collapse state behind the sidebar's ▸/▾ fold (a collapsed project
  # hides its workspace rows). State lives on disk, NOT in a sidebar ivar, because
  # every window's sidebar is its own process: only a shared, on-disk flag folds a
  # project consistently across all of them — the same reason the agent dots read
  # hook files (see AgentState) and the bold markers do (see Attention). Unlike the
  # attention markers, this is a durable VIEW PREFERENCE, so it is deliberately NOT
  # cleared on quit: a project you folded stays folded across restarts.
  #
  # One file per collapsed project (name digest -> name), so toggling is a single
  # atomic create/delete and the several sidebar processes that may fold the same
  # project at once never race on a read-modify-write of one shared list.
  module Collapse
    module_function

    # Fold a project. Atomic temp+rename so a peer's concurrent scan never reads a
    # half-written marker — the established multi-process pattern (Attention, the
    # synthesized WAVs, Hook.ensure_script).
    def collapse(project)
      name = project.to_s
      return if name.empty?

      FileUtils.mkdir_p(state_dir)
      file = File.join(state_dir, key(name))
      tmp = "#{file}.#{Process.pid}.tmp"
      File.write(tmp, name)
      File.rename(tmp, file) # atomic on the same fs
    rescue StandardError
      nil
    end

    # Unfold a project. Idempotent — a missing marker is a quiet no-op, so a toggle
    # can call it unconditionally on the expand edge.
    def expand(project)
      File.delete(File.join(state_dir, key(project.to_s)))
    rescue StandardError
      nil
    end

    # The set of currently-collapsed project names. Given the live (configured)
    # project names, GCs a marker whose project is gone so the dir can't grow
    # without bound — but ONLY when `known` is actually populated, so a transient
    # empty/failed config never wipes a user's folds. (The key is a name, not a
    # checkable path, so we can't self-heal off the filesystem the way Attention's
    # dead-worktree GC does; this guarded check is the substitute.)
    def collapsed(known = nil)
      gc = known.is_a?(Array) && !known.empty? ? known.map(&:to_s).to_set : nil
      Dir.glob(File.join(state_dir, "*")).each_with_object(Set.new) do |file, set|
        next if file.end_with?(".tmp") # an in-flight (or crashed) atomic write — never a marker

        name = File.read(file).chomp
        next if name.empty? # a torn read: skip this cycle, don't delete — collapse rewrites atomically

        if gc && !gc.include?(name)
          File.delete(file) # a fold for a project that's no longer configured -> GC
        else
          set << name
        end
      rescue StandardError
        next
      end
    rescue StandardError
      Set.new
    end

    # Stable, process-independent filename for a project name. crc32 (like the
    # hook's cksum and Attention's key) is plenty for this tiny set, and the name is
    # the content, so a collision would at worst fold the wrong project, never
    # corrupt state.
    def key(name)
      Zlib.crc32(name.to_s).to_s(16)
    end

    # XDG-state-rooted, a sibling of the attention markers. Resolved from ENV per
    # call (not frozen at load) so the test sandbox can redirect it.
    def state_dir
      File.expand_path(
        ENV["SWITCHBOARD_COLLAPSE_DIR"] ||
          File.join(ENV["XDG_STATE_HOME"] || "~/.local/state", "switchboard", "collapse")
      )
    end
  end
end
