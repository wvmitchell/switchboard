# frozen_string_literal: true

module Switchboard
  # Carry a Claude Code conversation history across a workspace rename so `/resume`
  # still finds it (issue #42 follow-up). Claude stores each session transcript in
  #   <config>/projects/<encoded-cwd>/<session-id>.jsonl
  # keyed by the workspace's absolute path. `switchboard rename` moves the worktree
  # dir, so the cwd changes and a fresh agent looks under the NEW encoded path —
  # empty — while every transcript still sits under the OLD one. (Mid-conversation
  # survives only because the running agent froze its project dir at the old path
  # and the worktree bridge keeps that resolvable; a restart doesn't.) So on rename
  # we move the project dir to the new key too, mirroring `Git.move_worktree`:
  # relocate the real dir and leave a symlink bridge behind, so an in-flight
  # session's appends keep landing in the moved dir.
  #
  # The encoding is Claude's: every non-alphanumeric char becomes "-" (so "/",
  # "_" and "." all collapse — "/a/dvc_deal/x" and "/a/dvc.deal/x" both map to
  # "-a-dvc-deal-x"). It's lossy and NOT reversible, so we forward-encode both ends
  # of the rename rather than trying to decode a dir name back to a path.
  #
  # Best-effort throughout: this reaches into another tool's storage, so every
  # failure degrades to "history didn't move" rather than crashing the rename —
  # same contract as the rest of switchboard's shell-outs.
  #
  # Known limitations (deliberately deferred — context for if they ever surface):
  #   1. Clobber-on-name-reuse race. Rename A->B, keep that agent running, then
  #      reuse the freed name "A" for a NEW workspace: clear_link(dst) drops the
  #      A->B bridge and the still-running B agent, if it reopens by path, then
  #      appends into the new A's dir. Needs exact name reuse + a live renamed-away
  #      agent; not guarded.
  #   2. The bridge assumes Claude REOPENS the transcript by path each append. If
  #      it instead holds an fd, the dir move is transparent and the bridge is
  #      harmless dead weight. Unverified against Claude's internals; cheap either
  #      way, so we keep it.
  #   3. Lossy-encoding collision. Two sibling worktrees differing only in "_"/"."/"-"
  #      (foo_bar vs foo-bar) already SHARE one Claude dir (Claude's limitation, not
  #      ours); renaming one moves the shared dir. Won't happen with distinct names.
  module ClaudeHistory
    module_function

    def migrate(old_path, new_path)
      root = projects_root
      return unless root

      src = File.join(root, encode(canonical(old_path)))
      dst = File.join(root, encode(canonical(new_path)))
      return if src == dst # keys collapse equal (e.g. foo_bar -> foo-bar): already one dir

      # Follow a prior rename's bridge to the real transcript dir so repeated
      # renames don't build a symlink chain.
      real = resolve(src)
      return unless real && File.directory?(real)

      clear_link(dst) # a stale bridge squatting the target can't block the move
      if File.directory?(dst) && !File.symlink?(dst)
        merge_into(real, dst)  # real history already at the target: fold in, never clobber
        rmdir_if_empty(real)   # the merge drained it; clear the way so the bridge below can land
      else
        File.rename(real, dst) # the common case: move the dir wholesale
      end
      clear_link(src)      # drop any now-stale prior bridge so the new one can take its place
      leave_link(src, dst) # bridge: an in-flight session keeps appending into the moved dir
    rescue StandardError
      nil
    end

    # Sweep rename bridges (the old -> new symlinks migrate leaves in the projects
    # dir) once they dangle — i.e. the transcript dir they ultimately point at is
    # gone. File.exist? follows the whole chain, so a multi-rename chain is swept
    # only when its live endpoint dies, never while it still routes to real
    # transcripts. The ClaudeHistory twin of Reconcile.reap_bridges (which does the
    # same for worktree bridges), called from the same `prune` GC moment, but over
    # the single flat projects_root. Only ever deletes a dangling symlink, so it
    # can't touch a real project dir or a live bridge an in-flight agent needs.
    def reap_bridges
      root = projects_root
      return unless root && File.directory?(root)

      Dir.children(root).each do |name|
        path = File.join(root, name)
        File.delete(path) if File.symlink?(path) && !File.exist?(path)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # Claude's cwd -> project-dir encoding: every non-alphanumeric run to "-".
    def encode(path)
      path.to_s.gsub(/[^A-Za-z0-9]/, "-")
    end

    # Claude keys its project dir by the canonicalized cwd (`pwd -P`), so resolve
    # symlinked ancestors (/private/var, a symlinked HOME) — the same realpath rule
    # AgentState/Attention/Reconcile use to match git paths to Claude's view. But
    # keep the LEAF literal: by the time migrate runs, old_path's leaf is the rename
    # bridge symlink, and realpath'ing through it would resolve to the new dir and
    # miss the old key entirely. Degrades to the raw path if the parent is gone.
    def canonical(path)
      File.join(File.realpath(File.dirname(path)), File.basename(path))
    rescue StandardError
      path
    end

    # Where Claude keeps its per-project transcript dirs. A test/override seam
    # first (keeps the suite off the real ~/.claude), then Claude's own
    # CLAUDE_CONFIG_DIR, then the ~/.claude default.
    def projects_root
      override = ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"]
      return override unless override.nil? || override.empty?

      base = ENV["CLAUDE_CONFIG_DIR"]
      base = File.join(Dir.home, ".claude") if base.nil? || base.empty?
      File.join(base, "projects")
    end

    # The real dir behind a path: a bridge symlink's target, a plain dir as-is, or
    # nil when nothing's there. Rescued so a broken symlink degrades to "nothing".
    def resolve(path)
      return File.realpath(path) if File.symlink?(path)

      path if File.exist?(path)
    rescue StandardError
      nil
    end

    # Fold src's entries into an existing dst, never overwriting a collision (UUID
    # transcript names practically never collide; if one does, keep dst's).
    def merge_into(src, dst)
      Dir.each_child(src) do |name|
        target = File.join(dst, name)
        File.rename(File.join(src, name), target) unless File.exist?(target)
      end
    rescue StandardError
      nil
    end

    # Remove an emptied source dir so leave_link can put a bridge in its place
    # (Dir.rmdir refuses a non-empty dir, so a leftover collision keeps its files).
    def rmdir_if_empty(dir)
      Dir.rmdir(dir) if File.directory?(dir) && Dir.empty?(dir)
    rescue StandardError
      nil
    end

    # Mirror Git.leave_bridge/clear_bridge: best-effort symlink left at the old
    # location, only ever a symlink so it's safe to delete.
    def leave_link(src, dst)
      File.symlink(dst, src) unless File.exist?(src)
    rescue StandardError
      nil
    end

    def clear_link(path)
      File.delete(path) if File.symlink?(path)
    rescue StandardError
      nil
    end
  end
end
