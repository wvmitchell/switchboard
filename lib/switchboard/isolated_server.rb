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
        system(kill_env(dir), "tmux", "kill-server", out: File::NULL, err: File::NULL)
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
