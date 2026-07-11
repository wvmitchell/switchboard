# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"

module Switchboard
  # PR badges sourced from `gh` and cached on disk, so the sidebar never blocks
  # on the network. The sidebar reads the cache (instant); `switchboard refresh`
  # re-fetches. Replaces reading emdash's pull_requests table.
  module Pr
    module_function

    # Cached PRs keyed by head branch — never hits the network.
    def for_project(name)
      cache = cache_file(name)
      return {} unless File.exist?(cache)

      JSON.parse(File.read(cache))
    rescue JSON::ParserError
      {}
    end

    # Fetch from gh and rewrite the cache. Returns the fresh map, or nil when the
    # fetch failed (gh unreachable / errored) — in which case the last good cache
    # is left untouched rather than clobbered with an empty map, so a transient
    # failure can't blank the badges (and the unchanged mtime lets the backstop
    # retry). The write is atomic (temp + rename): no torn reads, and the file's
    # mtime marks the last *successful* fetch.
    def refresh(name, repo_path)
      data = fetch(repo_path)
      return if data.nil?

      dir = cache_dir
      FileUtils.mkdir_p(dir)
      file = cache_file(name)
      tmp = "#{file}.tmp"
      File.write(tmp, JSON.dump(data))
      File.rename(tmp, file)
      data
    end

    # Returns the branch->PR map, or nil to signal failure (so refresh won't
    # clobber a good cache). A repo with no GitHub remote legitimately has no PRs
    # -> {}.
    #
    # Two queries, because the all-states sweep is capped at the 200 *newest* PRs:
    # on an active repo that window fills with merged/closed ones, so an
    # older-but-still-open PR falls off the edge and loses its badge. Open PRs are
    # the ones backing live worktrees and must never drop, so they get their own
    # generous-limit query and are merged in LAST (a reused head branch — an old
    # merged PR and a new open one sharing a name — resolves to the OPEN badge).
    # The all-states sweep stays: it's what gives merged/closed branches their
    # MERGED/CLOSED badge. If EITHER query fails the whole fetch fails (nil), so a
    # half-populated cache is never written.
    def fetch(repo_path)
      repo = repo_slug(repo_path)
      return {} unless repo

      recent = gh_pr_list(repo, "all", 200) # merged/closed + recent open badges
      return nil if recent.nil?

      open = gh_pr_list(repo, "open", 500) # every open PR, however old
      return nil if open.nil?

      (recent + open).each_with_object({}) do |pr, acc|
        acc[pr["headRefName"]] = {
          "identifier" => "##{pr['number']}",
          "status" => pr["state"],
          "is_draft" => pr["isDraft"] ? 1 : 0
        }
      end
    end

    # One `gh pr list` query -> the parsed PR array, or nil on failure. Shared by
    # fetch's two queries so both honor the same no-clobber contract.
    def gh_pr_list(repo, state, limit)
      parse_pr_json(`gh pr list -R #{Shellwords.escape(repo)} --state #{Shellwords.escape(state)} --limit #{limit.to_i} \
             --json number,state,isDraft,headRefName 2>/dev/null`)
    end

    # gh stdout -> the parsed PR array, or nil on failure. Empty output means the
    # call failed (a real empty list prints "[]"), and malformed JSON is a failure
    # too -> nil. This nil-vs-{} distinction is the crux of the no-clobber cache
    # guard, so it's a pure seam refresh's tests can exercise without shelling out.
    def parse_pr_json(out)
      return nil if out.strip.empty?

      JSON.parse(out)
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
