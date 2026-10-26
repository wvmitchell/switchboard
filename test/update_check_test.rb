# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # UpdateCheck (#47): the cache, the cadence and the compare behind the sidebar's
  # "↑ x.y.z available" line. Lookups point at a local tag repo, never GitHub.
  class UpdateCheckTest < SandboxTest
    # --- cue: compare against the INSTALLED version ---------------------------

    def test_cue_announces_only_a_newer_release
      assert_equal "0.57.0", UpdateCheck.cue("0.57.0", "0.56.2")
      assert_nil UpdateCheck.cue("0.56.2", "0.56.2"), "current: no line"
      assert_nil UpdateCheck.cue("0.56.0", "0.56.2"), "older tag (a local build ahead): no line"
      assert_equal "0.57.10", UpdateCheck.cue("0.57.10", "0.57.9"), "numeric, not text, order"
      assert_nil UpdateCheck.cue(nil, "0.56.2")
      assert_nil UpdateCheck.cue("0.57.0", nil)
    end

    # Value: protects=the line clears as soon as the upgrade lands, before sidebars restart
    # (D2); fails_when=the cue compares the loaded VERSION again; seam=none
    def test_installed_version_is_read_from_the_file_not_the_loaded_constant
      file = path("keg", "version.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "module Switchboard\n  VERSION = \"9.9.9\"\nend\n")
      assert_equal "9.9.9", UpdateCheck.installed_version(file)
      assert_nil UpdateCheck.cue("9.9.9", UpdateCheck.installed_version(file)),
                 "an upgraded keg already holding the latest shows no line, whatever VERSION this process loaded"
    end

    def test_installed_version_is_nil_for_a_missing_or_unparseable_file
      assert_nil UpdateCheck.installed_version(path("nope.rb"))
      File.write(path("odd.rb"), "VERSION = ENV['X']\n")
      assert_nil UpdateCheck.installed_version(path("odd.rb"))
    end

    def test_version_file_is_the_installed_checkouts_version_rb
      assert_equal File.join(Installer.repo_root, "lib", "switchboard", "version.rb"), UpdateCheck.version_file
      assert_equal VERSION, UpdateCheck.installed_version, "this checkout's own file parses"
    end

    # --- cache path (D5) ------------------------------------------------------

    def test_cache_path_resolution_order
      ENV["SWITCHBOARD_UPDATE_CACHE"] = path("over", "x.json")
      assert_equal path("over", "x.json"), UpdateCheck.cache_path
      assert_equal path("over", "latest.attempt"), UpdateCheck.attempt_path, "the attempt file sits beside it"

      ENV["SWITCHBOARD_UPDATE_CACHE"] = ""
      assert_equal File.join(ENV["XDG_CACHE_HOME"], "switchboard", "latest.json"), UpdateCheck.cache_path,
                   "an exported-but-empty override counts as unset"

      ENV.delete("SWITCHBOARD_UPDATE_CACHE")
      ENV.delete("XDG_CACHE_HOME")
      assert_equal File.join(Dir.home, ".cache", "switchboard", "latest.json"), UpdateCheck.cache_path
    end

    # --- read: fails closed ---------------------------------------------------

    def test_read_returns_the_cached_version
      UpdateCheck.write("latest" => "0.57.0", "checked_at" => 1)
      assert_equal "0.57.0", UpdateCheck.read
    end

    def test_read_is_nil_for_anything_unexpected
      FileUtils.mkdir_p(File.dirname(UpdateCheck.cache_path))
      assert_nil UpdateCheck.read, "missing"
      ["", "not json", "[1,2]", '{"latest":57}', '{"latest":"0.57"}', '{"latest":"0.57.0\u001b[31m"}',
       "{\"latest\":\"\xFF\"}"].each do |body|
        File.binwrite(UpdateCheck.cache_path, body)
        assert_nil UpdateCheck.read, "should not draw: #{body.inspect}"
      end
    end

    # --- cadence: due? + claim (D7) -------------------------------------------

    def test_due_needs_both_a_stale_answer_and_a_stale_attempt
      now = Time.now
      assert UpdateCheck.due?(now), "nothing cached, nothing tried"

      UpdateCheck.write("latest" => "0.57.0", "checked_at" => 1)
      File.utime(now - UpdateCheck::TTL + 60, now - UpdateCheck::TTL + 60, UpdateCheck.cache_path)
      refute UpdateCheck.due?(now), "an answer younger than TTL"

      File.utime(now - UpdateCheck::TTL - 60, now - UpdateCheck::TTL - 60, UpdateCheck.cache_path)
      assert UpdateCheck.due?(now), "an answer older than TTL, no attempt"

      UpdateCheck.claim
      File.utime(now - UpdateCheck::RETRY + 60, now - UpdateCheck::RETRY + 60, UpdateCheck.attempt_path)
      refute UpdateCheck.due?(now), "an attempt younger than RETRY holds it off"

      File.utime(now - UpdateCheck::RETRY - 60, now - UpdateCheck::RETRY - 60, UpdateCheck.attempt_path)
      assert UpdateCheck.due?(now)
    end

    def test_claim_makes_the_check_not_due_for_the_next_pane
      assert UpdateCheck.due?
      assert UpdateCheck.claim
      refute UpdateCheck.due?, "a second pane right after the claim reads not due"
    end

    # --- the child ------------------------------------------------------------

    def test_check_reads_the_newest_release_tag
      ENV.delete(UpdateCheck::DISABLE_ENV)
      repo = temp_git_repo("rel")
      git(repo, "tag", "v0.56.2")
      git(repo, "tag", "v0.57.0")
      ENV["SWITCHBOARD_RELEASES_URL"] = repo
      result = UpdateCheck.check
      assert_equal "0.57.0", result["latest"]
      assert_kind_of Integer, result["checked_at"]
    end

    def test_check_is_nil_when_disabled_or_unreadable
      assert_nil UpdateCheck.check, "the harness sets the kill switch"
      ENV.delete(UpdateCheck::DISABLE_ENV)
      assert_nil UpdateCheck.check, "the release URL points nowhere"
    end

    def test_run_child_writes_an_answer_and_touches_the_attempt
      ENV.delete(UpdateCheck::DISABLE_ENV)
      stub_method(UpdateCheck, :check, -> { { "latest" => "0.57.0", "checked_at" => 1 } }) do
        UpdateCheck.run_child
      end
      assert_equal "0.57.0", UpdateCheck.read
      assert File.exist?(UpdateCheck.attempt_path)
    end

    # Value: protects=offline keeps the last answer; fails_when=a nil result overwrites the cache
    def test_run_child_keeps_the_old_answer_when_the_lookup_fails
      ENV.delete(UpdateCheck::DISABLE_ENV)
      UpdateCheck.write("latest" => "0.57.0", "checked_at" => 1)
      stub_method(UpdateCheck, :check, -> { nil }) { UpdateCheck.run_child }
      assert_equal "0.57.0", UpdateCheck.read
      assert File.exist?(UpdateCheck.attempt_path), "a failed attempt still throttles the retry"
    end

    def test_run_child_skips_the_lookup_while_another_holds_the_lock
      ENV.delete(UpdateCheck::DISABLE_ENV)
      FileUtils.mkdir_p(File.dirname(UpdateCheck.attempt_path))
      File.open(UpdateCheck.attempt_path, File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        stub_method(UpdateCheck, :check, -> { flunk "a second child must not look up" }) do
          # flock is per open file description, so a fresh open in this process still contends
          UpdateCheck.run_child
        end
      end
    end

    def test_run_child_does_nothing_under_the_kill_switch
      stub_method(UpdateCheck, :check, -> { flunk "no lookup under SWITCHBOARD_NO_UPDATE_CHECK" }) do
        UpdateCheck.run_child
      end
      refute File.exist?(UpdateCheck.attempt_path)
    end

    # --- gates ----------------------------------------------------------------

    def test_disabled_by_env_reads_any_value_but_zero
      ENV[UpdateCheck::DISABLE_ENV] = "1"
      assert UpdateCheck.disabled_by_env?
      ENV[UpdateCheck::DISABLE_ENV] = "0"
      refute UpdateCheck.disabled_by_env?
      ENV.delete(UpdateCheck::DISABLE_ENV)
      refute UpdateCheck.disabled_by_env?
    end

    def test_applies_only_to_the_installed_homebrew_binary
      stub_method(Upgrade, :install_method, -> { :brew }) do
        stub_method(Installer, :installed_bin?, -> { true }) { assert UpdateCheck.applies? }
        stub_method(Installer, :installed_bin?, -> { false }) { refute UpdateCheck.applies?, "a dogfood checkout" }
      end
      %i[clone brew_head].each do |method|
        stub_method(Upgrade, :install_method, -> { method }) do
          stub_method(Installer, :installed_bin?, -> { true }) { refute UpdateCheck.applies?, "#{method}: no line (D11)" }
        end
      end
    end

    # --- `switchboard check-update` (D4) --------------------------------------

    # Value: protects=no ssh/credential prompt can reach the sidebar pane; fails_when=the
    # daemonize is dropped or moved after the lookup; seam=none; no_claim=a real tty probe
    def test_check_update_daemonizes_before_the_lookup
      ENV.delete(UpdateCheck::DISABLE_ENV)
      calls = []
      stub_method(Process, :daemon, ->(*args) { calls << [:daemon, args] }) do
        stub_method(UpdateCheck, :run_child, -> { calls << [:run_child] }) do
          CLI.run(["check-update"])
        end
      end
      assert_equal [[:daemon, [true, true]], [:run_child]], calls,
                   "setsid away from the pane's terminal first, keeping the /dev/null'd stdio"
    end

    def test_check_update_does_nothing_under_the_kill_switch
      stub_method(Process, :daemon, ->(*) { flunk "must not even fork under SWITCHBOARD_NO_UPDATE_CHECK" }) do
        CLI.run(["check-update"])
      end
    end
  end
end
