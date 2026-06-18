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
