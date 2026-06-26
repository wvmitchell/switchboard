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
    # With bridge:, leave a symlink behind at old_path -> new_path. A Claude
    # session that was already running freezes its project dir
    # (CLAUDE_PROJECT_DIR) at the OLD path and chdir's there for every hook; once
    # the real dir moves out from under it those hooks land on a now-dead path
    # and the process falls back to $HOME — silencing the agent-state dots. The
    # bridge keeps the old path resolvable, so the hooks resolve through to the
    # new dir and `pwd -P` reports it, matching the worktree again. It's invisible
    # to git (not a registered worktree) and reaped once it dangles
    # (Reconcile.reap_bridges).
    def move_worktree(repo, old_path, new_path, bridge: false)
      clear_bridge(new_path) # a stale bridge squatting the target must not block the move
      moved = system("git", "-C", repo, "worktree", "move", old_path, new_path, out: File::NULL, err: File::NULL)
      leave_bridge(old_path, new_path) if moved && bridge
      moved
    end

    # Best-effort: a bridge hiccup must never fail an otherwise-good rename.
    def leave_bridge(old_path, new_path)
      File.symlink(new_path, old_path) unless File.exist?(old_path)
    rescue StandardError
      nil
    end

    # Drop a bridge symlink (only ever a symlink, never a real worktree) so its
    # name can be reused. Rescued: a delete race (a concurrent prune reap) or a
    # permission error must degrade, not crash the caller — same rule as the rest
    # of the shell-outs here.
    def clear_bridge(path)
      File.delete(path) if File.symlink?(path)
    rescue StandardError
      nil
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
    #
    # `cache` (optional, a Hash owned by the caller — the Sidebar, which persists
    # across reloads) memoizes per worktree so a reload that finds the reflog
    # unchanged skips BOTH the rev-parse subprocess and the re-parse. Keyed on
    # logs/HEAD mtime + limit: a new checkout appends to the reflog (bumping mtime)
    # and invalidates the entry, while the git-dir is stable per worktree so it's
    # remembered after the first lookup. cache nil ⇒ no memo (every call recomputes).
    def branch_history(worktree, limit: nil, cache: nil)
      entry = cache && cache[worktree]
      # --absolute-git-dir, not --git-dir: the latter returns a relative ".git",
      # which would resolve logs/HEAD against the process cwd (one worktree) for
      # every row in the tree. Absolute makes it the worktree's own reflog. Reused
      # from the cache when present (it doesn't change for a given worktree).
      gitdir = entry ? entry[0] : capture(worktree, "rev-parse", "--absolute-git-dir").strip
      head_log = File.join(gitdir, "logs", "HEAD")
      return [] unless File.exist?(head_log)

      mtime = File.mtime(head_log)
      return entry[3] if entry && entry[1] == mtime && entry[2] == limit

      branches = parse_branch_history(head_log, limit)
      cache[worktree] = [gitdir, mtime, limit, branches] if cache
      branches
    end

    # The HEAD-reflog parse behind branch_history, split out so the cache wrapper
    # above stays readable. Newest first, deduped, detached-HEAD checkouts dropped.
    def parse_branch_history(head_log, limit)
      seen = {}
      File.readlines(head_log).reverse_each do |line|
        m = line.match(/checkout: moving from (\S+) to (\S+)/)
        next unless m

        # Each checkout names two branches used in THIS worktree: the one moved TO
        # (newer) and the one moved FROM (older). Capturing the "from" matters: the
        # branch a worktree was born on — or any branch you `checkout -b`'d AWAY
        # from — has no "moving to" line of its own, so to-only parsing dropped it
        # (the multiple-branches-on-one-worktree case this whole feature exists for).
        # Add to-then-from so the result stays newest-first.
        #
        # Drop a detached-HEAD endpoint: its token is the commit-ish you typed (a
        # full/abbrev SHA), always a hex prefix of the OID on THAT side of the move —
        # the new OID (2nd field) for "to", the old OID (1st field) for "from". A real
        # branch name, even all-hex like "deadbeef", won't prefix its own commit
        # except by astronomical coincidence. >=4 is git's min abbreviation; below it
        # a token is a branch name. Downcase: OIDs are lowercase, a typed abbrev may not be.
        old_oid, new_oid = line.split[0].to_s, line.split[1].to_s
        [[m[2], new_oid], [m[1], old_oid]].each do |ref, oid|
          # A ref-navigation spelling git records by name when you detach onto it
          # (HEAD~1, HEAD@{2}, main^) is not a local branch — drop tokens carrying a
          # character git forbids in a branch name. Tags / remote-refs (v1.0,
          # origin/main) are valid branch spellings, so they're indistinguishable
          # here and still slip through; switching to one just detaches, harmless.
          next if ref.match?(%r{[~^:?*\[\\]|@\{|\.\.}) || ref == "@"
          next if ref.match?(/\A[0-9a-f]{4,}\z/i) && oid.downcase.start_with?(ref.downcase)

          seen[ref] = true unless seen.key?(ref)
        end
        break if limit && seen.size >= limit
      end
      limit ? seen.keys.first(limit) : seen.keys
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

    # [additions, deletions] of ref vs base (the branch's own committed work,
    # base...ref). --numstat, not --shortstat: the shortstat summary line is
    # gettext-localized, so a non-English git would slip past a word regex; the
    # numstat columns are never translated. ref defaults to HEAD (the worktree's
    # current branch). Blank base => [0, 0]; any git failure degrades to [0, 0].
    def diff_counts(worktree, base, ref = "HEAD")
      return [0, 0] if blank?(base)

      sum_numstat(capture(worktree, "diff", "--numstat", range(base, ref)))
    end

    # Sum the added/deleted columns of --numstat output. A binary file's columns
    # are "-\t-"; "-".to_i is 0, so they fall out of the sum without a special case.
    def sum_numstat(text)
      text.each_line.reduce([0, 0]) do |(adds, dels), line|
        a, d, = line.split("\t")
        [adds + a.to_i, dels + d.to_i]
      end
    end

    # [ahead, behind] of HEAD relative to base.
    def ahead_behind(worktree, base)
      return [0, 0] if blank?(base)

      out = capture(worktree, "rev-list", "--left-right", "--count", "#{base}...HEAD").strip
      behind, ahead = out.split(/\s+/).map(&:to_i)
      [ahead || 0, behind || 0]
    end

    def range(base, ref = "HEAD")
      blank?(base) ? ref : "#{base}...#{ref}"
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
