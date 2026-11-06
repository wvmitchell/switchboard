# frozen_string_literal: true

module Switchboard
  # "Is this still the same process?" — a pid alone can't say, because the OS recycles
  # pids. A pid PLUS its start time is a strong identity: a dead pid has no start time,
  # and a recycled one has a different start time, so neither matches a recorded token.
  # Shared by IsolatedServer (never pid-kill a recycled pid that might be the dev's real
  # tmux server) and Creation (a dead build owner reads as dead, not as a stranger that
  # happens to wear its pid).
  module ProcessIdentity
    module_function

    # A pid's start timestamp (`ps -o lstart=`), or "" for a dead/unknown pid. `lstart`
    # follows the caller's TZ/locale, and the writer (a pane shell with your rc's env)
    # and the checker (a sidebar with tmux's) may differ — so pin both.
    def start_of(pid)
      return "" unless pid

      IO.popen({ "LC_ALL" => "C", "TZ" => "UTC" }, ["ps", "-p", pid.to_i.to_s, "-o", "lstart="],
               err: File::NULL, &:read).to_s.strip
    rescue StandardError
      ""
    end

    # Is `pid` still the process that was started at `started`? A missing token can't
    # be verified, so it's false (fail-closed) — like an unrecorded pid.
    def same?(pid, started)
      return false if pid.nil? || started.to_s.strip.empty?

      start_of(pid) == started.to_s.strip
    end

    # A child's Process::Status if it exited within `secs`, else nil (still running).
    def wait_within(pid, secs)
      stop = Time.now + secs
      while Time.now < stop
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status

        sleep 0.05
      end
      nil
    end

    # Stop a child we spawned as its own process GROUP (pgroup: true) — the whole group,
    # so a helper it forked (git's ssh, a credential helper) goes too: TERM, a short
    # grace, then KILL. Bounded: never an open-ended wait on something that ignores TERM.
    def terminate_group(pid, grace: 2)
      signal_group("TERM", pid)
      return if wait_within(pid, grace)

      signal_group("KILL", pid)
      wait_within(pid, grace)
    end

    def signal_group(sig, pid)
      Process.kill(sig, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Is `pid` a live process? ESRCH ⇒ dead; EPERM ⇒ alive but not ours.
    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
