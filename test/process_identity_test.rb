# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # pid + start time as identity: the guard that keeps a recycled pid from reading as
  # the process that once owned it (IsolatedServer's kill guard, Creation's owner check).
  class ProcessIdentityTest < Minitest::Test
    DEAD = 2_147_483_600 # far above any real pid

    def test_a_live_pid_matches_its_own_start_time
      assert ProcessIdentity.same?(Process.pid, ProcessIdentity.start_of(Process.pid))
    end

    def test_a_dead_pid_has_no_start_time_and_never_matches
      assert_equal "", ProcessIdentity.start_of(DEAD)
      refute ProcessIdentity.same?(DEAD, "Mon Jan  1 00:00:00 2024")
    end

    def test_a_recycled_pid_mismatches_its_recorded_start_time
      refute ProcessIdentity.same?(Process.pid, "Mon Jan  1 00:00:00 1990"),
             "the same pid with a different start time is a different process"
    end

    def test_a_missing_token_fails_closed
      refute ProcessIdentity.same?(Process.pid, "")
      refute ProcessIdentity.same?(nil, "anything")
    end

    # The writer (a pane shell with your rc's env) and the checker (a sidebar with tmux's)
    # can differ in TZ/locale, and `lstart` follows both — so the token must not.
    def test_the_start_time_ignores_the_callers_timezone_and_locale
      saved = ENV.to_h.slice("TZ", "LC_ALL")
      ENV["TZ"] = "Asia/Kolkata"
      ENV["LC_ALL"] = "C"
      recorded = ProcessIdentity.start_of(Process.pid)
      ENV["TZ"] = "America/Los_Angeles"
      assert ProcessIdentity.same?(Process.pid, recorded)
    ensure
      %w[TZ LC_ALL].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
    end

    def test_alive
      assert ProcessIdentity.alive?(Process.pid)
      refute ProcessIdentity.alive?(DEAD)
    end

    # Value: protects=terminate_group is bounded: a group that ignores TERM still dies (KILL) within its grace; fails_when=the KILL escalation is dropped or the grace wait is open-ended, so a stalled fetch/add pins the worker forever; why_new=no test drives terminate_group or wait_within directly; seam=none; no_claim=which helpers a real git forks
    def test_terminate_group_escalates_to_kill_for_a_group_ignoring_term
      pid = Process.spawn("sh", "-c", "trap '' TERM; while :; do sleep 0.1; done", pgroup: true)
      sleep 0.2 # let the trap install before the TERM lands
      started = Time.now
      ProcessIdentity.terminate_group(pid, grace: 0.5)
      refute ProcessIdentity.alive?(pid), "reaped, not left running past TERM"
      assert_operator Time.now - started, :<, 3, "bounded by TERM grace + KILL grace"
      assert_nil ProcessIdentity.wait_within(Process.spawn("sleep", "5").tap { |p| @stray = p }, 0.2),
                 "still running inside the window reads as nil"
    ensure
      Process.kill("KILL", @stray) && Process.wait(@stray) if @stray
      begin
        Process.kill("KILL", -pid) if pid
        Process.wait(pid)
      rescue SystemCallError
        nil
      end
    end
  end
end
