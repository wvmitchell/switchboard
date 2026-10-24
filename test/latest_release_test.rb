# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # LatestRelease reads the newest vX.Y.Z tag. The live lookups point at a local repo (or
  # a stalled ssh remote), never GitHub, so the suite stays offline.
  class LatestReleaseTest < SandboxTest
    def test_highest_picks_the_greatest_version_numerically
      raw = <<~OUT
        aaa\trefs/tags/v0.9.0
        bbb\trefs/tags/v0.51.1
        ccc\trefs/tags/v0.51.0
        ddd\trefs/tags/v0.10.3
      OUT
      assert_equal "0.51.1", LatestRelease.highest(raw)
    end

    def test_highest_ignores_tags_that_are_not_plain_releases
      raw = "a\trefs/tags/v9.0.0-rc1\nb\trefs/tags/nightly\nc\trefs/tags/v1.2.3\nd\trefs/tags/v1.2.3.4\n"
      assert_equal "1.2.3", LatestRelease.highest(raw)
    end

    def test_highest_is_nil_without_release_tags
      assert_nil LatestRelease.highest("")
      assert_nil LatestRelease.highest(nil)
    end

    def test_compare_orders_by_number_not_text
      assert_operator LatestRelease.compare("0.51.10", "0.51.9"), :>, 0
      assert_equal 0, LatestRelease.compare("1.2.3", "1.2.3")
      assert_operator LatestRelease.compare("0.9.0", "0.10.0"), :<, 0
    end

    def test_latest_reads_tags_from_a_remote
      repo = temp_git_repo("rel")
      git(repo, "tag", "v0.1.0")
      git(repo, "tag", "v0.2.0")
      assert_equal "0.2.0", LatestRelease.latest(url: repo, timeout: 10)
    end

    def test_latest_is_nil_when_the_remote_cant_be_read
      assert_nil LatestRelease.latest(url: path("nope"), timeout: 10)
    end

    # Value: protects=doctor/upgrade never hanging offline; fails_when=the deadline or the
    # group kill is dropped; why_new=new lookup; seam=none; no_claim=GitHub itself
    def test_latest_gives_up_on_a_stalled_remote_at_its_deadline
      # `#` swallows the host + command git appends, so this ssh really blocks (a bare
      # `sleep 3` fails on those extra args at once and never reaches the deadline).
      ENV["GIT_SSH_COMMAND"] = "sleep 3 #"
      started = Time.now
      assert_nil LatestRelease.latest(url: "ssh://example.invalid/x.git", timeout: 0.5)
      elapsed = Time.now - started
      assert_operator elapsed, :>=, 0.5, "waited for the deadline, not a fast failure"
      assert_operator elapsed, :<, 2.5, "killed at the deadline, not after the stall"
    ensure
      ENV.delete("GIT_SSH_COMMAND")
    end

    # Value: protects=the anonymous lookup surviving a user's insteadOf rewrite (a common
    # https→ssh one would stall it on every doctor run); fails_when=the spawn honors user
    # git config again; why_new=D3; seam=none
    def test_latest_ignores_url_rewrites_in_the_users_git_config
      repo = temp_git_repo("rel")
      git(repo, "tag", "v0.3.0")
      File.write(ENV["GIT_CONFIG_GLOBAL"], "[url \"#{path('nowhere')}/\"]\n\tinsteadOf = #{File.dirname(repo)}/\n")
      assert_equal "0.3.0", LatestRelease.latest(url: repo, timeout: 10)
    end

    # Value: protects=the lookup ignoring the config of whatever repo doctor/upgrade runs inside
    # (a repo-local insteadOf); fails_when=the spawn stops running from a neutral dir; why_new=the
    # rewrite test covers only global config; seam=none; no_claim=system config
    def test_latest_ignores_url_rewrites_in_the_current_repos_config
      repo = temp_git_repo("rel")
      git(repo, "tag", "v0.4.0")
      here = temp_git_repo("here")
      git(here, "config", "url.#{path('nowhere')}/.insteadOf", "#{File.dirname(repo)}/")
      assert_equal "0.4.0", Dir.chdir(here) { LatestRelease.latest(url: repo, timeout: 10) }
    end

    # Value: protects=a lookup killed at its deadline leaving no git/ssh helper running behind;
    # fails_when=the group kill after the deadline is dropped; why_new=the stall test only times
    # the return, which holds without the kill; seam=none; no_claim=TERM vs KILL escalation
    def test_a_stalled_lookup_leaves_nothing_running
      marker = path("still-running")
      ENV["GIT_SSH_COMMAND"] = "sleep 1; touch #{marker} #"
      assert_nil LatestRelease.latest(url: "ssh://example.invalid/x.git", timeout: 0.3)
      sleep 1.5
      refute File.exist?(marker), "the stalled ssh outlived the lookup"
    ensure
      ENV.delete("GIT_SSH_COMMAND")
    end

    # Value: protects=a failed lookup never reporting a release (git can print refs and still
    # fail); fails_when=ls_remote_tags reads the output without checking git's exit status;
    # why_new=every failing-remote test printed nothing, so the status gate was unpinned;
    # seam=a `git` shim on PATH (real git doesn't fail after printing refs); no_claim=real git's
    # failure modes
    def test_tag_output_from_a_failed_ls_remote_is_ignored
      bin = path("shim")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "git"), "#!/bin/sh\nprintf 'abc\\trefs/tags/v9.9.9\\n'\nexit 1\n")
      File.chmod(0o755, File.join(bin, "git"))
      orig = ENV["PATH"]
      ENV["PATH"] = "#{bin}:#{orig}"
      assert_nil LatestRelease.latest(url: "https://example.invalid/x.git", timeout: 10)
    ensure
      ENV["PATH"] = orig
    end

    def test_highest_skips_a_tag_with_invalid_bytes_instead_of_raising
      raw = "a\trefs/tags/v1.0.0\nb\trefs/tags/caf\xC3\n".dup.force_encoding(Encoding::UTF_8)
      assert_equal "1.0.0", LatestRelease.highest(raw)
    end
  end
end
