# frozen_string_literal: true

module Switchboard
  # The local branches a workspace takes with it when it's deleted: the one it's on plus
  # every one its own HEAD reflog visited. The reflog dies with the worktree, so the list
  # is read before removal, then handed to whichever process does the removing.
  #
  # A branch another worktree is on or has visited stays: it isn't this workspace's alone,
  # and whichever of them is deleted last still takes it. Tips are pinned when the list is
  # shown, so a commit landing after that keeps its branch, and `branch -D` refuses
  # anything checked out (or mid-rebase) elsewhere.
  module WorkspaceBranches
    Entry = Struct.new(:name, :sha, :merged, keyword_init: true)

    ARGS_FLAG = "--branches"
    ALWAYS_KEPT = %w[main master].freeze

    module_function

    # nil when it can't tell: git couldn't list every worktree or read another's reflog,
    # and any unread one could hold a candidate. Empty means there's truly nothing to take.
    # Git's own listing names this tree's branch, since a row can lag a rename. Unmerged
    # branches come first, where they're easiest to see.
    def plan(repo, path, base)
      base = base.to_s
      worktrees = Git.worktrees(repo, strict: true)
      return nil unless worktrees

      here = real(path)
      own, others = worktrees.partition { |w| real(w[:path]) == here }
      return nil if own.empty?

      # A reflog holds what was typed. On a case-insensitive filesystem `MAIN` resolves to
      # main's ref and passes every name check, and `main~1` isn't a branch: only git's own
      # spelling of a branch counts.
      names = [own.first[:branch], *Git.visited_branches(path)].compact.uniq & Git.local_branches(repo)
      return [] if names.empty?

      # A worktree already being deleted has no say in what its history used, and mid-removal
      # its reflog may be unreadable. Its current branch still counts until it's gone.
      deleting = PendingDelete.pending(others.map { |w| w[:path] })
      elsewhere = others.reject { |w| deleting.include?(w[:path]) }.map { |w| Git.visited_branches(w[:path]) }
      return nil if elsewhere.any?(&:nil?)

      # Other worktrees' names stay as typed, so these compare the way APFS does: on that
      # filesystem `Feature` over there is `feature` here, and `branch -D` won't notice.
      taken = (kept_names(repo, base) + others.map { |w| w[:branch] } + elsewhere.flatten).compact.map { |n| same_file_key(n) }
      names.reject { |name| taken.include?(same_file_key(name)) }
           .map { |name| entry(repo, name, base) }.compact.sort_by { |e| e.merged ? 1 : 0 }
    end

    # Names a case- and normalization-insensitive filesystem treats as one file share a key.
    def same_file_key(name)
      name.scrub.unicode_normalize(:nfd).downcase(:fold)
    end

    # A renamed workspace's old path is a symlink, so the same tree can go by two names.
    def real(path)
      File.realpath(path)
    rescue SystemCallError
      path
    end

    # Never a project's trunk, even when this workspace visited it. A base can be spelled
    # `develop`, `origin/develop` or `refs/heads/develop`, and a remote's name can hold a
    # slash, so every tail of the ref is kept. Keeping one too many only leaves a branch.
    # The repo's own HEAD counts: a bare project's is listed nowhere else.
    def kept_names(repo, base)
      tails = [base, Git.remote_head(repo)].compact.flat_map do |ref|
        parts = ref.split("/")
        parts.each_index.map { |i| parts.drop(i).join("/") }
      end
      ALWAYS_KEPT + tails + [Git.current_branch(repo)]
    end

    def entry(repo, name, base)
      sha = Git.rev_parse(repo, "refs/heads/#{name}")
      Entry.new(name: name, sha: sha, merged: Git.ancestor?(repo, sha, base)) if sha
    end

    # What the confirm shows above its prompt. A lone merged branch is nothing to weigh, so
    # the plain "delete x?" stands alone.
    def listing(entries, base)
      return [] if entries.empty? || (entries.size == 1 && entries.first.merged)

      ["also deletes (! not in #{base}):", *entries.map { |e| "#{e.merged ? ' ' : '!'} #{e.name}" }]
    end

    # sha first: a ref name can't hold a colon.
    def to_args(entries)
      [ARGS_FLAG, *entries.map { |e| "#{e.sha}:#{e.name}" }]
    end

    # nil without the flag: an older caller, which still means its single-branch -d.
    def from_args(argv)
      at = argv.index(ARGS_FLAG)
      return nil unless at

      argv.drop(at + 1).map do |arg|
        sha, name = arg.split(":", 2)
        Entry.new(name: name, sha: sha)
      end
    end

    # Names of the branches that survived. One already gone isn't a survivor.
    def delete(repo, entries)
      entries.filter_map do |e|
        tip = Git.rev_parse(repo, "refs/heads/#{e.name}")
        next unless tip

        e.name unless tip == e.sha && Git.delete_branch(repo, e.name, force: true)
      end
    end

    # Runs after the row is gone, often from a daemon, so tmux is the only place to say so.
    def delete_and_report(repo, entries)
      kept = delete(repo, entries)
      return if kept.empty?

      Tmux.notify_everyone("switchboard: kept branch #{kept.join(', ')} (in use or changed)",
                           display_time: Tmux.display_time)
    end
  end
end
