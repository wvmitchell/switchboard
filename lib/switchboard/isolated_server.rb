# frozen_string_literal: true

require "securerandom"
require "fileutils"

module Switchboard
  # Shared scaffolding for a THROWAWAY tmux server on its own socket — the single
  # source of truth for the socket-safety guard and the leaked-server sweep, used
  # by BOTH the real-tmux smoke layer (SmokeCase, test/smoke) and the interactive
  # `switchboard sandbox` command (issue #126). One implementation so the guard
  # that stops a `kill-server` from ever reaching a real server can't drift.
  #
  # Isolation is TMUX_TMPDIR + the DEFAULT socket (never `tmux -L`): the binary's
  # bare-`tmux` calls must reach the same server both inside panes ($TMUX) and in
  # subcommands (TMUX_TMPDIR). macOS caps unix socket paths ~104 chars, so the dir
  # MUST be short (/tmp) with an UNPREDICTABLE suffix — a guessable name lets a
  # same-user attacker pre-plant a symlink mkdir would follow, past the guard.
  module IsolatedServer
    module_function

    # A fresh short 0700 socket dir /tmp/<prefix><pid>-<hex>. Dir.mkdir (NOT
    # mkdir_p) raises if the path already exists — including as a symlink — so we
    # only ever operate on a dir WE created fresh.
    def make_socket_dir(prefix)
      dir = "/tmp/#{prefix}#{Process.pid}-#{SecureRandom.hex(4)}"
      Dir.mkdir(dir, 0o700)
      dir
    end

    # Sweep abandoned <prefix>* dirs left by an INTERRUPTED run: a Ctrl-C / kill
    # that skipped teardown leaves the daemon server (and its sidebar panes) alive,
    # which is how orphaned `switchboard sidebar` processes pile up. Only dirs whose
    # owning pid is DEAD are swept, so a CONCURRENT run is never torn down. The whole
    # dir is removed — for the sandbox the seeded state tree lives INSIDE it, so one
    # sweep reaps both the server and its state. Best-effort: a dir we can't
    # kill/remove is skipped, never fatal.
    def sweep_stale(prefix)
      stale_sock_dirs(Dir.glob("/tmp/#{prefix}*"), prefix).each do |dir|
        kill_server(dir)                  # kill-server AND pid-kill — reaps even a socketless daemon
        FileUtils.remove_entry(dir)
      rescue StandardError
        next
      end
    end

    # The environment that CONFINES a `tmux kill-server` to the throwaway `dir`'s
    # server and nothing else. Pins TMUX_TMPDIR to the dir AND clears TMUX (nil ⇒ unset
    # for the child) — tmux resolves an inherited $TMUX BEFORE TMUX_TMPDIR, so a bare
    # kill launched with the caller's real $TMUX still set (the preflight sweep runs
    # before the sandbox unsets TMUX; or a teardown after an early failure that never
    # unset it) would hit the REAL server. With TMUX cleared the kill can ONLY reach the
    # default socket under `dir` — provably the throwaway server. Used by both the sweep
    # and the sandbox teardown, so the kill is structurally safe rather than gated on a
    # flaky socket-path readback. Pure so the safety property is unit-testable.
    def kill_env(dir)
      { "TMUX_TMPDIR" => dir, "TMUX" => nil }
    end

    # Pure: of `dirs`, the throwaway dirs (<prefix><pid>-<hex>) whose owning pid is
    # no longer alive — the ones safe to sweep. The pid is carried in the basename,
    # so liveness is a cheap Process.kill(0); a name without a parseable pid is left
    # alone (not ours to judge). The prefix is a parameter (NOT hardcoded), so a
    # caller using an "sbx" prefix actually matches its own dirs. Split out so the
    # selection is testable without real pids.
    def stale_sock_dirs(dirs, prefix, alive: method(:pid_alive?))
      re = /\A#{Regexp.escape(prefix)}(\d+)-/
      dirs.select do |dir|
        m = File.basename(dir).match(re)
        m && !alive.call(m[1].to_i)
      end
    end

    # Is `pid` a live process? ESRCH ⇒ dead (sweep it); EPERM ⇒ alive but not ours
    # (keep — never sweep a server we can't prove is dead).
    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Kill the throwaway server rooted at `sock_dir` and DO NOT RETURN until it's really
    # dead — the fix for orphaned daemons. A tmux server outlives its socket: once the
    # socket file is unlinked, `tmux kill-server` (path-based) can never reach it, so a
    # teardown/sweep that removed the dir after a merely-ATTEMPTED kill left the daemon
    # alive AND unfindable (only Process.kill can reach a socketless daemon). So two
    # steps: (1) `kill-server` confined by kill_env — the clean path while the socket is
    # live; (2) pid-kill the recorded pid as the GUARANTEE. The caller can then remove the
    # dir with zero risk of orphaning a live server. Safety: the pid comes ONLY from THIS
    # throwaway server (a read through its own confined socket, or its boot-time server.pid
    # which is identity-checked so a recycled pid is never returned — see recorded_pid),
    # and ensure_dead only signals a still-live tmux process, so it can never reach the
    # dev's real server. Best-effort.
    def kill_server(sock_dir)
      return if sock_dir.to_s.strip.empty? # an empty dir makes kill_env resolve the DEFAULT socket = real server

      pid = recorded_pid(sock_dir) || read_server_pid(sock_dir)
      system(kill_env(sock_dir), "tmux", "kill-server", out: File::NULL, err: File::NULL)
      ensure_dead(pid)
    rescue StandardError
      nil
    end

    # The file inside a socket dir holding the server's pid, written at boot. It's what
    # lets kill_server reap a daemon whose socket was already unlinked — the pid survives
    # in the dir even when the socket doesn't.
    def server_pid_file(sock_dir)
      File.join(sock_dir, "server.pid")
    end

    # Record the throwaway server's pid at boot so teardown/sweep can pid-kill it even
    # after the socket is gone. Reads the pid through the server's OWN confined socket
    # (never bare tmux) and persists it WITH its start-time as an identity token (see
    # recorded_pid). Returns the pid or nil; best-effort.
    def record_server_pid(sock_dir)
      pid = read_server_pid(sock_dir)
      File.write(server_pid_file(sock_dir), "#{pid}\t#{process_start(pid)}") if pid
      pid
    rescue StandardError
      nil
    end

    # The pid recorded in the socket dir's server.pid, VERIFIED still to be that same
    # process — or nil. It survives the socket being unlinked (the leak case), which is
    # why it's preferred over a live socket read. But a recorded pid can go stale (its
    # server died, its dir lingered), and the OS may have RECYCLED that pid to another live
    # process — including the dev's REAL tmux server. Killing on pid alone would then hit
    # the wrong process. So the file stores `pid<TAB>start-time`, and we return the pid
    # only when the live process's start-time still matches: a recycled or dead pid
    # mismatches → nil → never killed. A pid with no identity token can't be verified, so
    # it's also nil (fail-closed).
    def recorded_pid(sock_dir)
      pid_s, started = File.read(server_pid_file(sock_dir)).split("\t", 2)
      return nil unless pid_s&.match?(/\A\d+\z/)

      pid = pid_s.to_i
      started = started.to_s.strip
      return nil if started.empty? || process_start(pid) != started

      pid
    rescue StandardError
      nil
    end

    # Read the server's pid THROUGH ITS CONFINED SOCKET — kill_env clears TMUX and pins
    # TMUX_TMPDIR to sock_dir, so `display-message` can only ever reach OUR throwaway
    # server, never the dev's real one (a bare `tmux display-message` under the dev's real
    # $TMUX would return the REAL server's pid — the footgun this avoids). nil when the
    # socket is gone/unreachable or the reply is garbled.
    def read_server_pid(sock_dir)
      return nil if sock_dir.to_s.strip.empty? # empty TMUX_TMPDIR resolves to the DEFAULT socket = the real server

      raw = IO.popen(kill_env(sock_dir), ["tmux", "display-message", "-p", "#\{pid}"],
                     err: File::NULL, &:read).to_s.strip
      raw.match?(/\A\d+\z/) ? raw.to_i : nil
    rescue StandardError
      nil
    end

    # SIGKILL `pid` and wait (bounded) until it's actually gone — the guarantee step of
    # kill_server. Straight KILL: a throwaway server is disposable, and a wedged daemon
    # was observed to ignore TERM. The recycle guard (tmux_process?) is load-bearing: if
    # the server already died and its pid was reused, we must NOT kill the stranger — so
    # we only ever signal a pid that is STILL a live tmux process. Best-effort: a process
    # that refuses to die is left, never looped on forever.
    def ensure_dead(pid, attempts: 40, interval: 0.05)
      return unless pid && tmux_process?(pid)

      Process.kill("KILL", pid)
      attempts.times do
        return unless pid_alive?(pid)

        sleep interval
      end
    rescue Errno::ESRCH
      nil # already gone between the guard and the kill — the win condition
    rescue StandardError
      nil
    end

    # Is `pid` a live tmux process right now? The recycle guard before a pid-kill — `ps`
    # the pid's command name and require tmux. Split from tmux_comm? so the match is
    # unit-testable without a real process.
    def tmux_process?(pid)
      return false unless pid

      tmux_comm?(`ps -p #{pid.to_i} -o comm= 2>/dev/null`)
    end

    # Pure: does a `ps -o comm=` value name tmux? Basename so an absolute path
    # (/opt/homebrew/bin/tmux) matches; prefix so a "tmux: server" variant matches too.
    def tmux_comm?(comm)
      File.basename(comm.to_s.strip).start_with?("tmux")
    end

    # A pid's start timestamp (`ps -o lstart=`) — the identity token that tells THIS
    # process apart from a later one that reused its pid (pid + start-time is a strong
    # identity). Empty for a dead/unknown pid, so a stale recorded pid whose process is
    # gone or recycled never matches its recorded token.
    def process_start(pid)
      return "" unless pid

      `ps -p #{pid.to_i} -o lstart= 2>/dev/null`.strip
    end

    # Is `socket_path` under the throwaway `sock_dir`? The blast-radius backstop:
    # teardown's kill-server is gated on this so a leak (partial setup, a future
    # refactor) can NEVER reach the dev's real server. Boundary-aware (root + "/"),
    # NOT a raw start_with? — the socket lives at "<root>/tmux-<uid>/default", and a
    # raw prefix would let "/tmp/sbx123-10" match root "/tmp/sbx123-1". `sock_dir` is
    # resolved through symlinks (macOS reports the socket under /private/tmp while
    # the dir is /tmp), degrading to the raw path so the compare fails closed —
    # never a false ok.
    def isolated_socket?(sock_dir, socket_path)
      return false if sock_dir.nil? || socket_path.to_s.strip.empty?

      root = begin
        File.realpath(sock_dir)
      rescue StandardError
        sock_dir
      end
      !!(root && socket_path.strip.start_with?(root + File::SEPARATOR))
    end
  end
end
