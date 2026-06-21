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

    private

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
  end
end
