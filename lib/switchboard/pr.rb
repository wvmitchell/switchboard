# frozen_string_literal: true

require "json"
require "shellwords"
require_relative "git"
require_relative "tree"
require_relative "marker_block"

module Switchboard
  # PR badges sourced from `gh` and cached on disk, so the sidebar never blocks
  # on the network. The sidebar reads the cache (instant); `switchboard refresh`
  # re-fetches. Replaces reading emdash's pull_requests table.
  module Pr
    module_function

    # Backfill queries per refresh — bounds the per-branch gh fan-out; the
    # un-queried remainder just waits a refresh (and negative caching means the
    # missing set shrinks to zero after the first pass anyway).
    BACKFILL_LIMIT = 10

    # Reserved cache key carrying the repo identity the entries belong to. A git
    # ref can never start with "/", so no branch name can collide with it.
    REPO_KEY = "//repo"

    # The open query's window. Beyond it the open result is truncated, so it can
    # no longer PROVE a branch has no open PR (the stale-OPEN gate below).
    OPEN_LIMIT = 500

    # Cached PRs keyed by head branch — never hits the network. Two shape notes
    # for consumers: a value may be null (a negative-cached "no PR here" branch —
    # treat it exactly like an absent key), and the reserved REPO_KEY entry
    # carries the cache's repo identity for refresh's reuse guard. Total: a
    # missing, torn, or non-object payload reads as empty rather than raising
    # into the UI (or into refresh's merge).
    def for_project(name)
      cache = cache_file(name)
      return {} unless File.exist?(cache)

      parsed = JSON.parse(File.read(cache))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    # Fetch from gh and fold the result ONTO the previous cache — merge, never
    # replace. The fetch's queries are windows (the 200 most recently *updated*
    # PRs + every open one), so on an active repo a long-quiet merged PR
    # eventually falls out of both — but its branch row (worktree or reflog
    # history) can outlive that by months, and a badge must persist as long as
    # its row renders: you remove a workspace or a branch, never a badge. So a
    # cached entry is only ever *updated* (a fresh row for the same head branch
    # wins), never dropped; entries whose branch no longer renders anywhere are
    # inert, ~100 bytes each, so the cache needs no GC. Rendered branches still
    # missing after the merge get a targeted backfill query (below) — the
    # recovery path for a badge the windows lost before stickiness existed.
    # Returns the merged map, or nil when the fetch failed (gh unreachable /
    # errored) — in which case the last good cache is left untouched rather than
    # clobbered with an empty map, so a transient failure can't blank the badges
    # (and the unchanged mtime lets the backstop retry). Concurrency: several
    # sidebars spawn refresh children for the same project, so the write goes
    # through MarkerBlock.atomic_write (pid-UNIQUE temp + rename — a shared temp
    # path would let two writers interleave into torn JSON and rename it into
    # place, permanently wiping the sticky memory when the next merge starts
    # from the {} a torn parse reads as), and the pre-write re-read merges a
    # concurrent writer's additions under ours — shrinking the lost-update
    # window to the final read→rename; an entry lost in that residue reads as
    # missing again next refresh and self-heals. The file's mtime still marks
    # the last *successful* fetch.
    def refresh(name, repo_path)
      fresh = fetch(repo_path)
      return if fresh.nil?

      repo = repo_slug(repo_path)
      data = previous_map(name, repo).merge(fresh)
      backfill(data, repo_path, fresh)
      data = previous_map(name, repo).merge(data)
      data[REPO_KEY] = repo if repo
      MarkerBlock.atomic_write(cache_file(name), JSON.dump(data))
      data
    end

    # The previous cache as the sticky base — emptied when its recorded repo
    # identity (REPO_KEY) contradicts the current origin, so a project name
    # reused for a DIFFERENT repository can't inherit the old repo's badges (the
    # old replace-style refresh washed those out; the sticky merge would keep
    # them forever). An absent marker (legacy cache) or an unresolvable current
    # slug keeps the cache: identity can't be verified then, and wiping on a
    # transient git failure would trade a rare wrong badge for common lost ones.
    def previous_map(name, repo)
      previous = for_project(name)
      return {} if repo && previous[REPO_KEY] && previous[REPO_KEY] != repo

      previous
    end

    # Returns the branch->PR map, or nil to signal failure (so refresh won't
    # clobber a good cache). A repo with no GitHub remote legitimately has no PRs
    # -> {}.
    #
    # Two windowed queries; refresh's sticky merge (above) is what makes the
    # windows safe to fall out of. The all-states sweep is ordered by *update*
    # recency (sort:updated-desc, via gh's --search — the list API has no sort
    # flag), not creation: a state flip on an old PR (an aged open one finally
    # merging or closing) bumps it back into the window, so the sticky entry it
    # left behind is corrected on the next refresh — under creation order it
    # would re-enter never, freezing at its last-seen state once 200 newer PRs
    # existed (the disappearing-badge bug, #156's residue). Open PRs additionally
    # get their own generous-limit query, merged in LAST: they back live
    # worktrees, and a reused head branch — an old merged PR and a new open one
    # sharing a name — must resolve to the OPEN badge. If EITHER query fails the
    # whole fetch fails (nil), so a half-populated cache is never written.
    def fetch(repo_path)
      repo = repo_slug(repo_path)
      return {} unless repo

      # merged/closed + recently-touched badges. The sorted form rides GitHub's
      # search API (its own, scarcer rate limit), so on failure fall back to the
      # plain creation-ordered list: a quota hit or a gh that rejects the combo
      # degrades to the pre-sticky window instead of failing the refresh — a
      # permanent search breakage would otherwise freeze every badge forever.
      recent = gh_pr_list(repo, "all", 200, sort: "updated-desc") || gh_pr_list(repo, "all", 200)
      return nil if recent.nil?

      open = gh_pr_list(repo, "open", OPEN_LIMIT) # every open PR up to the window
      return nil if open.nil?

      # Fold oldest-first: gh returns both queries newest-first, and a plain
      # fold's last-write-wins would hand a head branch naming several PRs to
      # the STALEST one. Reversed, the newest entry wins — with any open PR
      # (folded last) still beating the rest.
      (recent.reverse + open.reverse).each_with_object({}) do |pr, acc|
        acc[pr["headRefName"]] = pr_entry(pr)
      end
    end

    # Rendered branches the windowed queries never saw get one targeted --head
    # query each, mutated into data — the recovery path for a badge that fell
    # out of the windows before the sticky cache could hold it, and for a fresh
    # worktree on an old branch. A branch with genuinely no PR is cached as an
    # explicit null so it's asked exactly once, not every refresh; a PR later
    # opened on it lands via the open query and overwrites the null. A FAILED
    # query writes nothing (failure and "no PR" must never be conflated) — it
    # just retries next refresh, and can't fail the whole refresh: the windowed
    # data already merged, and backfill rows are additive-or-corrective.
    def backfill(data, repo_path, fresh = {})
      repo = repo_slug(repo_path)
      return unless repo

      branches = rendered_branches(repo_path)
      missing = branches - data.keys
      # A cached OPEN badge for a branch the open query no longer returns cannot
      # still be open — its close/merge aged out of the sweep unseen, and the
      # sticky entry would stay wrong forever. Re-query it like a missing one.
      # The proof only holds while the open window wasn't FULL: a truncated
      # result can't prove absence, and trusting it would re-query every
      # beyond-the-cap OPEN badge each refresh (the count of open entries in
      # fresh stands in for the query's own size — head-branch dupes could
      # undercount near the cap, an acceptable margin).
      open_seen = fresh.count { |_, v| v.is_a?(Hash) && v["status"] == "OPEN" }
      stale_open = branches.select do |b|
        open_seen < OPEN_LIMIT && data[b].is_a?(Hash) && data[b]["status"] == "OPEN" && !fresh.key?(b)
      end
      # Shuffled so a persistently failing head can't starve the ones behind it.
      (missing + stale_open).shuffle.first(BACKFILL_LIMIT).each do |branch|
        list = gh_pr_list(repo, "all", 1, head: branch) # newest PR wins a reused branch
        next if list.nil?

        data[branch] = list.empty? ? nil : pr_entry(list.first)
      end
    end

    # The branches the sidebar actually renders for this repo: each non-primary
    # worktree's reflog lineage (what Tree expands into branch rows, same cap)
    # plus its current branch. These rows are the badge contract, so backfill
    # covers exactly this set — the primary checkout never renders (Tree rejects
    # it), and querying --head on its trunk branch would happily match a fork PR
    # whose head happens to share the name. That bare-name keying is DELIBERATE
    # for the rendered branches themselves (a `gh pr checkout`'d fork branch
    # should badge its fork PR); the trunk is the one name where collision is
    # likely and the row never shows.
    def rendered_branches(repo_path)
      # identical?, not string equality: git prints resolved paths, the config
      # may hold a symlinked spelling of the same checkout.
      Git.worktrees(repo_path).reject { |w| w[:bare] || File.identical?(w[:path], repo_path) }.flat_map do |w|
        Git.branch_history(w[:path], limit: Tree::MAX_BRANCHES) | [w[:branch]].compact
      end.uniq
    end

    def pr_entry(pr)
      {
        "identifier" => "##{pr['number']}",
        "status" => pr["state"],
        "is_draft" => pr["isDraft"] ? 1 : 0
      }
    end

    # One `gh pr list` query -> the parsed PR array, or nil on failure. Shared by
    # fetch's two queries and backfill's targeted ones so all honor the same
    # no-clobber contract.
    def gh_pr_list(repo, state, limit, sort: nil, head: nil)
      parse_pr_json(`#{pr_list_cmd(repo, state, limit, sort: sort, head: head)} 2>/dev/null`)
    end

    # The command string behind gh_pr_list, split out so the sort/head wiring is
    # testable without gh. Sort rides --search (the list API has no sort flag);
    # --state composes with --search (gh folds the state into the search query).
    def pr_list_cmd(repo, state, limit, sort: nil, head: nil)
      cmd = "gh pr list -R #{Shellwords.escape(repo)} --state #{Shellwords.escape(state)} " \
            "--limit #{limit.to_i} --json number,state,isDraft,headRefName"
      cmd += " --search #{Shellwords.escape("sort:#{sort}")}" if sort
      cmd += " --head #{Shellwords.escape(head)}" if head
      cmd
    end

    # gh stdout -> the parsed PR array, or nil on failure. Empty output means the
    # call failed (a real empty list prints "[]"), malformed JSON is a failure,
    # and so is valid-but-non-array JSON (an API error object) — a truthy
    # non-array would otherwise defeat fetch's sort-fallback `||` and crash the
    # fold. This nil-vs-[] distinction is the crux of the no-clobber cache
    # guard, so it's a pure seam refresh's tests can exercise without shelling out.
    def parse_pr_json(out)
      return nil if out.strip.empty?

      parsed = JSON.parse(out)
      parsed.is_a?(Array) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # owner/repo from the origin remote (git@github.com:o/r.git or https://…).
    def repo_slug(repo_path)
      url = `git -C #{Shellwords.escape(repo_path)} remote get-url origin 2>/dev/null`.strip
      return nil if url.empty?

      m = url.match(%r{[:/]([^/]+/[^/]+?)(?:\.git)?\z})
      m && m[1]
    end

    # On-disk cache location, resolved at call time (so tests and XDG can
    # override it). An exported-but-empty env var is treated as unset.
    def cache_dir
      override = ENV["SWITCHBOARD_CACHE_DIR"]
      return File.expand_path(override) if override && !override.empty?

      xdg = ENV["XDG_CACHE_HOME"]
      return File.join(xdg, "switchboard", "prs") if xdg && !xdg.empty?

      File.expand_path("~/.cache/switchboard/prs")
    end

    def cache_file(name)
      File.join(cache_dir, "#{name.gsub(/[^\w.-]/, '_')}.json")
    end

    # True when a project's cache is missing or older than ttl seconds — the
    # sidebar uses this to decide when to fire a background refresh. A file that
    # vanishes mid-check reads as stale.
    def stale?(name, ttl)
      file = cache_file(name)
      return true unless File.exist?(file)

      Time.now - File.mtime(file) > ttl
    rescue SystemCallError
      true
    end

    # Is gh authenticated? `gh auth status` exits non-zero when not. A seam (not an
    # inline shell-out in doctor) so the suite can stub it and stay offline — the
    # real call validates the token against the API.
    def authenticated?
      system("gh", "auth", "status", out: File::NULL, err: File::NULL)
    end

    # Seconds since a project's PR cache was last successfully written (its mtime
    # marks the last good fetch), or nil if it's never been fetched. `doctor` reads
    # this so a silently-frozen badge set (e.g. gh auth lapsed) is visible — the
    # honest counterpart to the UI degrading quietly.
    def cache_age(name)
      file = cache_file(name)
      return nil unless File.exist?(file)

      Time.now - File.mtime(file)
    rescue SystemCallError
      nil
    end
  end
end
