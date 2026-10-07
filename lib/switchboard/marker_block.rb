# frozen_string_literal: true

require "fileutils"

module Switchboard
  # Manage a marker-delimited region inside a user's config file —
  #
  #   # >>> switchboard ... >>>
  #   <our content>
  #   # <<< switchboard ... <<<
  #
  # — atomically and idempotently. Two callers: `Installer` (a `run-shell` line in
  # the user's `tmux.conf`) and `CodexHook` (a `[hooks]` block in `~/.codex/config.toml`).
  # Both need the identical file-surgery — append/replace/strip the marked region,
  # write through a symlink, never half-write — so it lives here ONCE rather than as
  # two copies that drift. The callers supply their own marks + inner content (and any
  # format-specific guards, e.g. CodexHook's TOML collision check).
  module MarkerBlock
    module_function

    # Drop the marked region (markers included) from `body`. Absent ⇒ unchanged.
    def strip(body, begin_mark, end_mark)
      body.gsub(region(begin_mark, end_mark), "")
    end

    # The text between the markers, or nil when there's no region.
    def inner(body, begin_mark, end_mark)
      body[region(begin_mark, end_mark), 1]
    end

    # A marker line may carry trailing text: older releases wrote
    # `# >>> … >>> (managed by …)`, so `strip` and `present?` must both accept it.
    def region(begin_mark, end_mark)
      /^#{Regexp.escape(begin_mark)}[^\n]*\n(.*?)^#{Regexp.escape(end_mark)}[^\n]*\n?/m
    end

    # `body` with the marked region holding `inner` appended at the end. Assumes
    # `body` is already stripped of a prior region (see `replace` for the idempotent
    # form). `inner` is normalized to exactly one trailing newline before the end mark.
    def build(body, begin_mark, end_mark, inner)
      body += "\n" unless body.empty? || body.end_with?("\n")
      "#{body}#{begin_mark}\n#{inner.chomp}\n#{end_mark}\n"
    end

    # Idempotent ensure: strip any existing region, then append a fresh one. This is
    # what re-running install / re-ensuring a hook block wants — exactly one region,
    # never a duplicate.
    def replace(body, begin_mark, end_mark, inner)
      build(strip(body, begin_mark, end_mark), begin_mark, end_mark, inner)
    end

    def present?(body, begin_mark)
      body.match?(/^#{Regexp.escape(begin_mark)}/)
    end

    # First-write-only backup: capture the user's pristine file once, never clobber a
    # known-good `.bak` on a re-run.
    def backup(path)
      bak = "#{path}.bak"
      FileUtils.cp(path, bak) if File.exist?(path) && !File.exist?(bak)
    end

    # Write via temp-file + rename so the update is atomic: a crash or ENOSPC mid-write
    # leaves the old file intact, never a truncated one (and never a half-written marker
    # block). Rename is atomic within a dir.
    #
    # Symlink-aware: when `path` is a symlink (a config file stowed into a dotfiles repo,
    # say), write THROUGH it to the file it points at, so the link itself survives.
    # Renaming onto the symlink would replace it with a detached regular-file copy —
    # silently decoupling the live config from the repo it links into. The temp lands
    # beside the resolved target, keeping the rename within one dir.
    #
    # Creates the target's parent dir if absent (a `~/.codex` codex hasn't materialized
    # yet — else the write ENOENTs and the feature silently no-ops), and carries the
    # existing file's mode onto the replacement so a private `0600` config isn't widened
    # to the umask default by the rewrite.
    def atomic_write(path, content)
      dest = real_target(path)
      FileUtils.mkdir_p(File.dirname(dest))
      tmp = "#{dest}.#{Process.pid}.sb-tmp"
      File.write(tmp, content)
      File.chmod(File.stat(dest).mode & 0o7777, tmp) if File.exist?(dest)
      File.rename(tmp, dest)
    end

    # Follow a symlink chain to the real file it ultimately points at, so writes go
    # through the link rather than clobbering it. A non-symlink path is returned
    # unchanged; a dangling link still resolves to its intended target (the write can
    # create it). Cycle-guarded against a pathological link loop.
    def real_target(path)
      seen = {}
      while File.symlink?(path) && !seen[path]
        seen[path] = true
        path = File.absolute_path(File.readlink(path), File.dirname(path))
      end
      path
    end
  end
end
