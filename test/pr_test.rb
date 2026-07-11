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
      refute File.exist?("#{Pr.cache_file('proj')}.tmp") # temp gone after rename
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
    # afterward (the suite is stdlib-only, so no minitest/mock).
    def stub_fetch(value)
      original = Pr.method(:fetch)
      Pr.define_singleton_method(:fetch) { |*| value }
      yield
    ensure
      Pr.define_singleton_method(:fetch, original)
    end

    # Exercise the real fetch merge logic with canned gh results, one per state
    # ("all"/"open") — the value nil simulates a failed query. Also stubs the git
    # repo_slug shell-out so fetch doesn't bail at "no origin" before it queries.
    def stub_gh_pr_list(by_state)
      orig_list = Pr.method(:gh_pr_list)
      orig_slug = Pr.method(:repo_slug)
      Pr.define_singleton_method(:gh_pr_list) { |_repo, state, _limit| by_state.fetch(state) }
      Pr.define_singleton_method(:repo_slug) { |*| "owner/repo" }
      yield
    ensure
      Pr.define_singleton_method(:gh_pr_list, orig_list)
      Pr.define_singleton_method(:repo_slug, orig_slug)
    end
  end
end
