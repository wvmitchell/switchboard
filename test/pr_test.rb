# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Pr's cache-location resolution, staleness check, cached reads, and the
  # fetch-failure no-clobber guard. The gh/git shell-outs (fetch/repo_slug) stay
  # untested; what matters is that refresh never clobbers a good cache when the
  # fetch fails, which is exercised here by stubbing fetch.
  class PrTest < SandboxTest
    def setup
      super
      @cache = File.join(@dir, "cache")
      ENV["SWITCHBOARD_CACHE_DIR"] = @cache
    end

    # --- cache_dir resolution ---

    def test_cache_dir_honors_explicit_override
      assert_equal File.expand_path(@cache), Pr.cache_dir
    end

    def test_cache_dir_falls_back_to_xdg
      ENV.delete("SWITCHBOARD_CACHE_DIR")
      ENV["XDG_CACHE_HOME"] = "/tmp/xdg-cache"
      assert_equal "/tmp/xdg-cache/switchboard/prs", Pr.cache_dir
    end

    def test_cache_dir_default_when_unset
      ENV.delete("SWITCHBOARD_CACHE_DIR")
      ENV.delete("XDG_CACHE_HOME")
      assert_equal File.expand_path("~/.cache/switchboard/prs"), Pr.cache_dir
    end

    def test_cache_dir_treats_empty_env_as_unset
      ENV["SWITCHBOARD_CACHE_DIR"] = ""
      ENV.delete("XDG_CACHE_HOME")
      assert_equal File.expand_path("~/.cache/switchboard/prs"), Pr.cache_dir
    end

    # --- stale? ---

    def test_stale_when_cache_missing
      assert Pr.stale?("nope", 60)
    end

    def test_fresh_cache_is_not_stale
      seed("proj", { "main" => {} })
      refute Pr.stale?("proj", 60)
    end

    def test_old_cache_is_stale
      file = seed("proj", { "main" => {} })
      backdate(file, 120)
      assert Pr.stale?("proj", 60)
    end

    # --- cache_age (doctor freshness) ---

    def test_cache_age_is_nil_when_never_fetched
      assert_nil Pr.cache_age("nope")
    end

    def test_cache_age_reflects_the_cache_mtime
      file = seed("proj", { "main" => {} })
      backdate(file, 120)
      assert_in_delta 120, Pr.cache_age("proj"), 5,
                      "age is seconds since the last successful fetch (the cache mtime)"
    end

    # --- for_project ---

    def test_for_project_reads_the_overridden_dir
      seed("proj", { "feature" => { "identifier" => "#7" } })
      assert_equal({ "feature" => { "identifier" => "#7" } }, Pr.for_project("proj"))
    end

    def test_for_project_returns_empty_on_missing
      assert_equal({}, Pr.for_project("ghost"))
    end

    def test_for_project_returns_empty_on_malformed_json
      FileUtils.mkdir_p(@cache)
      File.write(Pr.cache_file("broken"), "{not json")
      assert_equal({}, Pr.for_project("broken"))
    end

    # --- refresh: no-clobber on failure, atomic on success ---

    def test_refresh_leaves_cache_untouched_when_fetch_fails
      file = seed("proj", { "main" => { "identifier" => "#1" } })
      backdate(file, 300)
      mtime = File.mtime(file).to_i

      stub_fetch(nil) { Pr.refresh("proj", "/whatever") }

      assert_equal({ "main" => { "identifier" => "#1" } }, Pr.for_project("proj"))
      assert_equal mtime, File.mtime(file).to_i # mtime not bumped -> backstop retries
    end

    def test_refresh_writes_atomically_on_success
      data = { "main" => { "identifier" => "#9", "status" => "OPEN", "is_draft" => 0 } }
      stub_fetch(data) { Pr.refresh("proj", "/whatever") }

      assert_equal data, Pr.for_project("proj")
      assert_equal [File.basename(Pr.cache_file("proj"))], Dir.children(@cache),
                   "no temp file left behind after the rename"
    end

    # --- refresh: the sticky merge — a badge outlives the query windows ---

    # The disappearing-badge bug (#156's residue): on an active repo a merged PR
    # eventually falls out of BOTH fetch windows, but its worktree/branch row can
    # outlive that by months. The cached entry must survive a fetch that no
    # longer contains it — a badge is removed with its branch/workspace, never by
    # newer PRs existing.
    def test_refresh_keeps_a_cached_badge_the_fetch_windows_dropped
      seed("proj", { "old-merged" => { "identifier" => "#15434", "status" => "MERGED", "is_draft" => 0 } })

      fresh = { "new-branch" => { "identifier" => "#15900", "status" => "OPEN", "is_draft" => 0 } }
      stub_fetch(fresh) { Pr.refresh("proj", "/whatever") }

      map = Pr.for_project("proj")
      assert_equal "#15434", map.dig("old-merged", "identifier"),
                   "a badge that fell out of the fetch windows must persist in the cache"
      assert_equal "#15900", map.dig("new-branch", "identifier") # fresh rows still land
    end

    # Sticky must never mean stale-frozen: a fresh row for the same head branch
    # (a state flip re-entering the update-ordered window) overwrites the old one.
    def test_refresh_fresh_entry_updates_a_sticky_one
      seed("proj", { "feature" => { "identifier" => "#7", "status" => "OPEN", "is_draft" => 0 } })

      fresh = { "feature" => { "identifier" => "#7", "status" => "MERGED", "is_draft" => 0 } }
      stub_fetch(fresh) { Pr.refresh("proj", "/whatever") }

      assert_equal "MERGED", Pr.for_project("proj").dig("feature", "status")
    end

    # --- refresh: the repo-identity guard on the sticky base ---

    # The sticky merge must not let a project name reused for a DIFFERENT
    # repository inherit the old repo's badges (the old replace-style refresh
    # washed those out on the first fetch; sticky would keep them forever).
    def test_refresh_wipes_the_sticky_base_when_the_repo_identity_changed
      seed("proj", { Pr::REPO_KEY => "old/repo", "feature" => { "identifier" => "#7" } })

      stub_fetch({}) { stub_backfill([], {}) { Pr.refresh("proj", "/whatever") } }

      map = Pr.for_project("proj")
      refute map.key?("feature"), "a different repo under the same name must not inherit badges"
      assert_equal "owner/repo", map[Pr::REPO_KEY] # re-stamped for the next guard
    end

    def test_refresh_keeps_the_sticky_base_when_identity_matches
      seed("proj", { Pr::REPO_KEY => "owner/repo", "feature" => { "identifier" => "#7" } })

      stub_fetch({}) { stub_backfill([], {}) { Pr.refresh("proj", "/whatever") } }

      assert_equal "#7", Pr.for_project("proj").dig("feature", "identifier")
    end

    # A pre-guard cache has no marker: identity can't be verified, so keep it
    # (wiping would trade a rare wrong badge for common lost ones) and stamp it.
    def test_refresh_keeps_a_legacy_cache_without_marker_and_stamps_it
      seed("proj", { "feature" => { "identifier" => "#7" } })

      stub_fetch({}) { stub_backfill([], {}) { Pr.refresh("proj", "/whatever") } }

      map = Pr.for_project("proj")
      assert_equal "#7", map.dig("feature", "identifier")
      assert_equal "owner/repo", map[Pr::REPO_KEY]
    end

    # --- fetch: two queries merged, open PRs never dropped ---

    # The bug: the all-states sweep is capped at the 200 newest PRs, so an
    # older-but-still-open PR falls off. The dedicated open query rescues it.
    def test_fetch_keeps_open_pr_outside_the_recent_window
      recent = [pr(9000, "MERGED", "old-merged")] # the 200-newest window, all closed/merged
      open   = [pr(8853, "OPEN", "feat-4207-part-3", draft: true)] # old but still open

      map = stub_gh_pr_list("all" => recent, "open" => open) { Pr.fetch("/whatever") }

      assert_equal({ "identifier" => "#8853", "status" => "OPEN", "is_draft" => 1 },
                   map["feat-4207-part-3"],
                   "an open PR below the recent-window cutoff must still get a badge")
      assert_equal "#9000", map["old-merged"]["identifier"] # sweep still badges merged/closed
    end

    # A reused head branch (old merged PR + new open PR) resolves to OPEN because
    # the open query is merged in last.
    def test_fetch_open_query_wins_a_reused_branch_name
      recent = [pr(10, "MERGED", "reused")]
      open   = [pr(42, "OPEN", "reused")]

      map = stub_gh_pr_list("all" => recent, "open" => open) { Pr.fetch("/whatever") }

      assert_equal({ "identifier" => "#42", "status" => "OPEN", "is_draft" => 0 }, map["reused"])
    end

    def test_fetch_returns_nil_when_the_all_states_query_fails
      map = stub_gh_pr_list("all" => nil, "open" => []) { Pr.fetch("/whatever") }
      assert_nil map, "a failed sweep must fail the whole fetch (no half cache)"
    end

    def test_fetch_returns_nil_when_the_open_query_fails
      map = stub_gh_pr_list("all" => [], "open" => nil) { Pr.fetch("/whatever") }
      assert_nil map, "a failed open query must fail the whole fetch (no half cache)"
    end

    def test_fetch_returns_empty_map_when_both_queries_are_empty
      map = stub_gh_pr_list("all" => [], "open" => []) { Pr.fetch("/whatever") }
      assert_equal({}, map, "a repo with genuinely no PRs is {}, not nil")
    end

    # The sweep must be UPDATE-ordered (a state flip on an old PR re-enters the
    # window and corrects its sticky cache entry); the open query needs no sort
    # (it grabs every open PR regardless).
    def test_fetch_sweep_is_update_ordered
      calls = []
      stub_gh_pr_list({ "all" => [], "open" => [] }, calls) { Pr.fetch("/whatever") }
      assert_equal [["all", 200, "updated-desc"], ["open", 500, nil]], calls
    end

    # The search-API sweep failing (quota, an incompatible gh) must degrade to
    # the plain creation-ordered list, not fail the refresh — a permanent search
    # breakage would otherwise freeze every badge at its last-cached state.
    def test_fetch_falls_back_to_the_plain_sweep_when_search_fails
      calls = []
      by = { ["all", "updated-desc"] => nil, ["all", nil] => [pr(1, "MERGED", "b")], "open" => [] }

      map = stub_gh_pr_list(by, calls) { Pr.fetch("/whatever") }

      assert_equal "#1", map["b"]["identifier"]
      assert_equal [["all", 200, "updated-desc"], ["all", 200, nil], ["open", 500, nil]], calls
    end

    # gh returns the sweep newest-first; a plain fold's last-write-wins would
    # hand a head branch naming several windowed PRs to the STALEST one.
    def test_fetch_newest_entry_wins_a_head_branch_with_two_recent_prs
      recent = [pr(20, "MERGED", "reused"), pr(10, "CLOSED", "reused")] # updated-desc order

      map = stub_gh_pr_list("all" => recent, "open" => []) { Pr.fetch("/whatever") }

      assert_equal "#20", map["reused"]["identifier"],
                   "the most recently updated PR must win a reused head branch"
    end

    # --- backfill: the targeted --head rescue for branches the windows missed ---

    def test_backfill_rescues_a_worktree_branch_the_windows_missed
      data = {}
      results = { "lost-branch" => [pr(15_434, "MERGED", "lost-branch")] }
      stub_backfill(["lost-branch"], results) { Pr.backfill(data, "/whatever") }

      assert_equal({ "identifier" => "#15434", "status" => "MERGED", "is_draft" => 0 },
                   data["lost-branch"],
                   "a worktree branch absent from every window gets a targeted query")
    end

    def test_backfill_skips_branches_already_cached
      data = { "cached" => { "identifier" => "#1" } }
      calls = []
      stub_backfill(["cached"], {}, calls) { Pr.backfill(data, "/whatever") }
      assert_empty calls, "a branch already in the map must not be re-queried"
    end

    # A branch with no PR is negative-cached as an explicit null: asked once,
    # then never again — a later PR overwrites it via the update-ordered window.
    def test_backfill_caches_no_pr_as_null_and_asks_only_once
      data = {}
      stub_backfill(["no-pr"], { "no-pr" => [] }) { Pr.backfill(data, "/whatever") }
      assert data.key?("no-pr")
      assert_nil data["no-pr"]

      calls = []
      stub_backfill(["no-pr"], {}, calls) { Pr.backfill(data, "/whatever") }
      assert_empty calls, "the null entry must suppress the query on later refreshes"
    end

    def test_backfill_failed_query_writes_nothing
      data = {}
      stub_backfill(["flaky"], { "flaky" => nil }) { Pr.backfill(data, "/whatever") }
      refute data.key?("flaky"), "a failed query is not 'no PR' — leave it for the next refresh"
    end

    # The provable-staleness rule: a cached OPEN badge whose branch the open
    # query no longer returns CANNOT still be open (that query lists every open
    # PR), so the sticky entry is re-queried instead of trusted forever.
    def test_backfill_requeries_a_cached_open_badge_the_open_query_dropped
      data = { "wt" => { "identifier" => "#5", "status" => "OPEN", "is_draft" => 0 } }

      stub_backfill(["wt"], { "wt" => [pr(5, "MERGED", "wt")] }) { Pr.backfill(data, "/whatever") }

      assert_equal "MERGED", data["wt"]["status"],
                   "an OPEN entry absent from the fresh fetch must be re-resolved"
    end

    def test_backfill_trusts_an_open_badge_the_fresh_fetch_still_lists
      entry = { "identifier" => "#5", "status" => "OPEN", "is_draft" => 0 }
      data = { "wt" => entry.dup }
      calls = []

      stub_backfill(["wt"], {}, calls) { Pr.backfill(data, "/whatever", { "wt" => entry }) }

      assert_empty calls, "a branch the fresh fetch covered needs no targeted query"
    end

    # The staleness proof needs a non-full open window: a truncated open result
    # can't prove absence, and trusting it would re-query every beyond-the-cap
    # OPEN badge on each refresh.
    def test_backfill_skips_the_stale_open_requery_when_the_open_window_is_full
      full = (1..Pr::OPEN_LIMIT).to_h { |i| ["b#{i}", { "identifier" => "##{i}", "status" => "OPEN", "is_draft" => 0 }] }
      data = { "wt" => { "identifier" => "#5", "status" => "OPEN", "is_draft" => 0 } }
      calls = []

      stub_backfill(["wt"], {}, calls) { Pr.backfill(data, "/whatever", full) }

      assert_empty calls, "absence from a FULL open window proves nothing"
    end

    def test_backfill_caps_the_query_fanout
      branches = (1..12).map { |i| "b#{i}" }
      results = branches.to_h { |b| [b, []] }
      calls = []
      stub_backfill(branches, results, calls) { Pr.backfill({}, "/whatever") }
      assert_equal Pr::BACKFILL_LIMIT, calls.size
    end

    # End-to-end through refresh: the null negative-cache survives the JSON
    # round trip, so the next refresh issues no query for that branch.
    def test_refresh_persists_the_null_negative_cache
      stub_fetch({}) do
        stub_backfill(["no-pr"], { "no-pr" => [] }) { Pr.refresh("proj", "/whatever") }
      end
      assert Pr.for_project("proj").key?("no-pr")

      calls = []
      stub_fetch({}) do
        stub_backfill(["no-pr"], {}, calls) { Pr.refresh("proj", "/whatever") }
      end
      assert_empty calls
    end

    # --- pr_list_cmd: the sort/head wiring, testable without gh ---

    def test_pr_list_cmd_sorts_via_search
      cmd = Pr.pr_list_cmd("owner/repo", "all", 200, sort: "updated-desc")
      assert_includes cmd, "--search sort:updated-desc"
      assert_includes cmd, "--state all"
    end

    def test_pr_list_cmd_omits_search_without_a_sort
      refute_includes Pr.pr_list_cmd("owner/repo", "open", 500), "--search"
    end

    def test_pr_list_cmd_targets_a_head_branch
      cmd = Pr.pr_list_cmd("owner/repo", "all", 1, head: "feature/x")
      assert_includes cmd, "--head feature/x"
    end

    # A branch name is user/git-controlled input reaching a backtick shell-out,
    # and `;` is legal in a git ref — dropping the escape must fail this test.
    def test_pr_list_cmd_escapes_a_metacharacter_head_branch
      cmd = Pr.pr_list_cmd("owner/repo", "all", 1, head: "a;b")
      assert_includes cmd, "--head #{Shellwords.escape('a;b')}"
      refute_includes cmd, "--head a;b", "an unescaped branch name reaches the shell"
    end

    # --- rendered_branches: the seam every backfill test stubs, pinned real ---

    # One unstubbed test against a live repo so a Git.worktrees shape drift (or
    # losing the refs/heads/ strip --head matching depends on) can't silently
    # disable backfill: short names, reflog lineage included, primary excluded.
    def test_rendered_branches_reads_lineage_and_skips_the_primary_checkout
      repo = temp_git_repo
      wt = path("wt-feature")
      git(repo, "worktree", "add", "-q", "-b", "feat-a", wt)
      git(wt, "checkout", "-q", "-b", "feat-b")

      assert_equal %w[feat-a feat-b], Pr.rendered_branches(repo).sort,
                   "lineage + current branch as short names; the primary's trunk stays out"
    end

    # --- parse_pr_json: the gh-stdout -> nil/[] discrimination the cache guard rides ---
    # This is the crux the fetch-level tests can't reach (they stub past the string):
    # empty stdout is a FAILED call (-> nil, no clobber), only a literal "[]" is a
    # real empty list (-> []). Collapsing these would silently blank a good cache.

    def test_parse_pr_json_treats_empty_output_as_failure
      assert_nil Pr.parse_pr_json(""), "empty gh stdout means the call failed -> nil"
      assert_nil Pr.parse_pr_json("   \n"), "whitespace-only stdout is still a failure"
    end

    def test_parse_pr_json_treats_empty_list_as_a_real_result
      assert_equal [], Pr.parse_pr_json("[]"), "a literal [] is a genuine empty list, not a failure"
    end

    def test_parse_pr_json_treats_malformed_json_as_failure
      assert_nil Pr.parse_pr_json("{not json"), "malformed JSON is a failure -> nil"
    end

    # An API error body is valid JSON but not an array; a truthy non-array would
    # defeat fetch's sort-fallback `||` and crash the fold.
    def test_parse_pr_json_treats_non_array_json_as_failure
      assert_nil Pr.parse_pr_json('{"message":"API rate limit exceeded"}')
      assert_nil Pr.parse_pr_json("null")
    end

    def test_parse_pr_json_returns_the_parsed_array
      assert_equal [{ "number" => 7 }], Pr.parse_pr_json('[{"number":7}]')
    end

    private

    def pr(number, state, head, draft: false)
      { "number" => number, "state" => state, "isDraft" => draft, "headRefName" => head }
    end

    def seed(name, data)
      FileUtils.mkdir_p(@cache)
      file = Pr.cache_file(name)
      File.write(file, JSON.dump(data))
      file
    end

    def backdate(file, seconds)
      t = Time.now - seconds
      File.utime(t, t, file)
    end

    # Gem-free stub: swap Pr.fetch for a constant, restore the original Method
    # afterward (the suite is stdlib-only, so no minitest/mock). Also stubs
    # repo_slug to nil so refresh's identity check and backfill are EXPLICITLY
    # inert — without this the refresh tests stayed offline only because the
    # fake repo path made the real git shell-out fail (nest stub_backfill inside
    # to give them a live repo_slug instead).
    def stub_fetch(value)
      orig_fetch = Pr.method(:fetch)
      orig_slug = Pr.method(:repo_slug)
      Pr.define_singleton_method(:fetch) { |*| value }
      Pr.define_singleton_method(:repo_slug) { |*| nil }
      yield
    ensure
      Pr.define_singleton_method(:fetch, orig_fetch)
      Pr.define_singleton_method(:repo_slug, orig_slug)
    end

    # Exercise the real fetch merge logic with canned gh results — keyed by
    # state ("all"/"open"), or by [state, sort] when a test needs to tell the
    # search-sorted sweep from its plain fallback; the value nil simulates a
    # failed query. Also stubs the git repo_slug shell-out so fetch doesn't bail
    # at "no origin" before it queries. Pass a calls array to record each
    # query's (state, limit, sort) for wiring asserts. Positional, not a kwarg:
    # a kwarg would make the braceless string-key by_state hashes at the call
    # sites parse as keywords.
    def stub_gh_pr_list(by_state, calls = nil)
      orig_list = Pr.method(:gh_pr_list)
      orig_slug = Pr.method(:repo_slug)
      Pr.define_singleton_method(:gh_pr_list) do |_repo, state, limit, sort: nil, head: nil|
        calls << [state, limit, sort] if calls
        by_state.fetch([state, sort]) { by_state.fetch(state) }
      end
      Pr.define_singleton_method(:repo_slug) { |*| "owner/repo" }
      yield
    ensure
      Pr.define_singleton_method(:gh_pr_list, orig_list)
      Pr.define_singleton_method(:repo_slug, orig_slug)
    end

    # Exercise the real backfill with canned rendered branches and per-head gh
    # results (missing key -> the branch is never queried; value nil -> a failed
    # query). Pass a calls array to record each query's (state, limit, sort, head).
    def stub_backfill(branches, by_head, calls = nil)
      orig_list = Pr.method(:gh_pr_list)
      orig_slug = Pr.method(:repo_slug)
      orig_rb   = Pr.method(:rendered_branches)
      Pr.define_singleton_method(:gh_pr_list) do |_repo, state, limit, sort: nil, head: nil|
        calls << [state, limit, sort, head] if calls
        by_head.fetch(head)
      end
      Pr.define_singleton_method(:repo_slug) { |*| "owner/repo" }
      Pr.define_singleton_method(:rendered_branches) { |*| branches }
      yield
    ensure
      Pr.define_singleton_method(:gh_pr_list, orig_list)
      Pr.define_singleton_method(:repo_slug, orig_slug)
      Pr.define_singleton_method(:rendered_branches, orig_rb)
    end
  end
end
