# frozen_string_literal: true

require "shellwords"

module Switchboard
  # Git is the source of truth for what worktrees exist and what they contain.
  module Git
    module_function

    # All worktrees registered against a repo, parsed from porcelain output.
    def worktrees(repo)
      capture(repo, "worktree", "list", "--porcelain").split("\n\n").filter_map do |block|
        h = {}
        block.each_line do |line|
          key, _, val = line.strip.partition(" ")
          h[key] = val unless key.empty?
        end
        next if h["worktree"].nil?

        {
          path: h["worktree"],
          branch: h["branch"]&.sub("refs/heads/", ""),
          bare: h.key?("bare")
        }
      end
    end

    def dirty?(worktree)
      !capture(worktree, "status", "--porcelain").strip.empty?
    end

    # Best-effort refresh so a base ref like origin/main is current before we
    # branch a new worktree from it. Fetches the remote the base lives on
    # (origin for origin/main) when that's a real remote; else the default.
    def fetch_base(repo, base)
      remote = base.to_s.split("/").first
      args = ["git", "-C", repo, "fetch", "--quiet"]
      args << remote if remote && remotes(repo).include?(remote)
      system(*args, out: File::NULL, err: File::NULL)
    end

    def remotes(repo)
      `git -C #{Shellwords.escape(repo)} remote 2>/dev/null`.split
    end

    # The repo root for a path (resolving up from a subdir), or nil if the path
    # isn't inside a git working tree. Used to validate "register this dir".
    def toplevel(path)
      return nil unless File.directory?(path)

      top = capture(path, "rev-parse", "--show-toplevel").strip
      top.empty? ? nil : top
    end

    # The remote's default branch as a base ref (e.g. "origin/main"), read from
    # the local origin/HEAD symref — set by clone, so it's reliable for fresh
    # clones. nil when unset (caller falls back to the global base).
    def remote_head(repo)
      ref = capture(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD").strip
      ref.empty? ? nil : ref.sub(%r{\Arefs/remotes/}, "")
    end

    # Clone a repo to dest (quiet; output swallowed so it never corrupts the
    # sidebar TUI). `--` guards against a URL that looks like a flag.
    def clone(url, dest)
      system("git", "clone", "--quiet", "--", url.to_s, dest.to_s, out: File::NULL, err: File::NULL)
    end

    # Rename a worktree by moving its directory (keeps the branch/PR intact).
    def move_worktree(repo, old_path, new_path)
      system("git", "-C", repo, "worktree", "move", old_path, new_path, out: File::NULL, err: File::NULL)
    end

    # Remove a worktree. Without force, git refuses if it's dirty (returns false
    # so the caller can ask before forcing).
    def remove_worktree(repo, path, force: false)
      args = ["git", "-C", repo, "worktree", "remove"]
      args << "--force" if force
      args << path
      system(*args, out: File::NULL, err: File::NULL)
    end

    # Delete a branch. Default -d is safe (refuses if unmerged → returns false,
    # branch kept, no commit loss). -D force-deletes.
    def delete_branch(repo, branch, force: false)
      return false if blank?(branch)

      system("git", "-C", repo, "branch", force ? "-D" : "-d", branch, out: File::NULL, err: File::NULL)
    end

    def current_branch(worktree)
      capture(worktree, "rev-parse", "--abbrev-ref", "HEAD").strip
    end

    # Every branch ever checked out in this worktree, newest first, deduped.
    # Read from the worktree's own HEAD reflog — the signal neither GUI uses.
    # `limit` caps the result (dedicated worktrees are short-lived, but the
    # canonical checkout's reflog can be enormous).
    def branch_history(worktree, limit: nil)
      gitdir = capture(worktree, "rev-parse", "--git-dir").strip
      head_log = File.join(gitdir, "logs", "HEAD")
      return [] unless File.exist?(head_log)

      seen = {}
      File.readlines(head_log).reverse_each do |line|
        m = line.match(/checkout: moving from \S+ to (\S+)/)
        next unless m

        ref = m[1]
        next if ref.match?(/\A[0-9a-f]{40}\z/) # detached-HEAD checkout, not a branch
        seen[ref] = true unless seen.key?(ref)
        break if limit && seen.size >= limit
      end
      seen.keys
    end

    def diffstat(worktree, base)
      capture(worktree, "diff", "--stat", range(base))
    end

    # diff --stat for an arbitrary branch (not the current HEAD) vs base.
    def diffstat_ref(repo, base, ref)
      capture(repo, "diff", "--stat", blank?(base) ? ref : "#{base}...#{ref}")
    end

    def shortstat(worktree, base)
      capture(worktree, "diff", "--shortstat", range(base)).strip
    end

    # [ahead, behind] of HEAD relative to base.
    def ahead_behind(worktree, base)
      return [0, 0] if blank?(base)

      out = capture(worktree, "rev-list", "--left-right", "--count", "#{base}...HEAD").strip
      behind, ahead = out.split(/\s+/).map(&:to_i)
      [ahead || 0, behind || 0]
    end

    def range(base)
      blank?(base) ? "HEAD" : "#{base}...HEAD"
    end

    def blank?(str)
      str.nil? || str.empty?
    end

    def capture(repo, *args)
      cmd = ["git", "-C", repo, *args].map { |a| Shellwords.escape(a) }.join(" ")
      `#{cmd} 2>/dev/null`
    end
  end
end
