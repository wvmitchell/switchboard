# frozen_string_literal: true

require_relative "../test_helper"
require "pty"
require "securerandom"

module Switchboard
  # Base class for the REAL-tmux smoke layer (issue #104) — the integration twin of
  # SandboxTest. SandboxTest walls off state but never boots a tmux server, so the bugs
  # #104 targets (pane recycling, hook firing, split/kill timing, attach/detach) can't be
  # reproduced against it. SmokeCase SUBCLASSES SandboxTest to reuse its env wall-off
  # verbatim (one source of truth — a missed override is the isolation hole the socket
  # guard backstops), then boots an isolated tmux server, attaches a real client via the
  # stdlib PTY (so the sidebar actually renders — an unattached server reads
  # session_attached=0 and the sidebar stays dormant), and drives the real binary.
  #
  # Isolation is a SHORT TMUX_TMPDIR + the DEFAULT socket (NOT `tmux -L`), so the binary's
  # bare-`tmux` calls reach the same server both inside panes ($TMUX) and in subcommands
  # (TMUX_TMPDIR). macOS caps unix socket paths ~104 chars, so the socket dir MUST be short
  # — SandboxTest's Dir.mktmpdir (/var/folders/...) is too deep; only the socket moves, the
  # state stays in the long sandbox dir. The home session IS Tmux::HOME so the #64
  # fall-home path (go_home) reuses it.
  #
  # Anti-flake by construction: every wait is wait_until (poll-until-condition), never a
  # fixed sleep-then-assert; the PTY master is drained so backpressure never stalls the
  # client; TERM is set so the PTY attach works under CI.
  class SmokeCase < SandboxTest
    REPO          = File.expand_path("../..", __dir__) # test/smoke -> repo root
    BIN           = File.join(REPO, "bin", "switchboard")
    TMUX_FRAGMENT = File.join(REPO, "switchboard.tmux")
    HOME          = Tmux::HOME                         # "sb/home" — what go_home reuses
    WAIT          = 15                                 # poll ceiling, comfortably > REFRESH(3s)

    # Sweep abandoned isolated tmux servers left by earlier INTERRUPTED smoke runs.
    # Each run's teardown kills its own server (kill-server below), but a Ctrl-C /
    # SIGKILL mid-run skips teardown and leaves the daemon server — and its sidebar
    # panes — alive: that's how orphaned `switchboard sidebar` processes pile up between
    # runs (the count `switchboard prune` later has to reap). bin/test-smoke calls this
    # BEFORE a fresh run so each run cleans up the last interrupted one. Only dirs whose
    # owning pid is DEAD are swept, so a CONCURRENT smoke run (CI parallelism) is never
    # torn down. Best-effort: a dir we can't kill/remove is skipped, never fatal.
    # Delegates to the shared IsolatedServer.sweep_stale — issue #126 extracted the
    # socket lifecycle (mkdir / guard / sweep) into lib so the smoke layer and
    # `switchboard sandbox` share ONE implementation and the socket guard can't drift.
    def self.sweep_stale_servers
      IsolatedServer.sweep_stale("sbk")
    end

    def setup
      super                                  # SandboxTest: the full env wall-off (incl TMUX_TMPDIR=@dir)
      skip "real-tmux smoke layer needs tmux on PATH" unless tmux_available?

      # SHORT path (the socket must fit macOS's ~104-char cap) with an UNPREDICTABLE suffix:
      # a guessable name lets a same-user attacker pre-plant a symlink to the real tmux dir
      # that mkdir would follow, slipping past the socket guard. Dir.mkdir (NOT mkdir_p) with
      # 0700 raises if the path already exists — including as a symlink — so we only ever
      # operate on a dir WE created fresh.
      @sock_dir = IsolatedServer.make_socket_dir("sbk") # shared symlink-safe 0700 dir (#126)
      ENV["TMUX_TMPDIR"]     = @sock_dir      # override SandboxTest's deep mktmpdir path
      ENV["SWITCHBOARD_BIN"] = BIN            # how tmux.rb spawns sidebar panes
      ENV["TERM"]            = "xterm-256color" # PTY.spawn("tmux","attach") fails on TERM=dumb/unset (CI)

      write_project_and_config
      seed_pr_cache                          # fresh cache -> visible reloads don't fork `switchboard refresh`
      boot_server
      source_tmux_fragment                   # real hooks: after-new-window / client-session-changed / window-changed
      attach_client                          # a real PTY client so session_attached=1 and the sidebar renders
      spawn_home_sidebar
    end

    def teardown
      close_pty  # close the master FIRST so the drain thread's blocking readpartial hits EOF...
      stop_drain # ...and this join returns at once instead of stalling on Thread#kill for up to 2s
      tmux("kill-server") if @sock_dir && isolated_socket? # only ever our own throwaway server
      FileUtils.remove_entry(@sock_dir) if @sock_dir && File.directory?(@sock_dir)
    ensure
      super                                  # SandboxTest: restore ENV + remove the state dir
    end

    # --- setup steps ---------------------------------------------------------

    def write_project_and_config
      @project = temp_git_repo("proj") # SandboxTest helper: hermetic repo, `main`, seeded commit, NO origin
      File.write(ENV["SWITCHBOARD_CONFIG"], <<~YAML)
        worktree_root: #{path('worktrees')}
        base: main
        agent_state_hooks: false
        projects:
          - name: proj
            path: #{@project}
      YAML
    end

    # Seed a fresh (current-mtime) PR cache so Pr.stale? is false and the sidebar never
    # forks a background `switchboard refresh --poke` mid-assertion (Codex review #5).
    def seed_pr_cache
      FileUtils.mkdir_p(Pr.cache_dir)
      File.write(Pr.cache_file("proj"), "{}") # a branch=>PR hash (empty: no PRs); NOT [] (Model does prs[branch])
    end

    def boot_server
      tmux!("new-session", "-d", "-s", HOME, "-x", "220", "-y", "50", "-c", ENV["HOME"])
      tmux!("set-option", "-t", HOME, "@sb_sidebar", "on") # opt the home session into a sidebar
    end

    # Apply switchboard's REAL tmux wiring to the isolated server. The fragment is a shell
    # script tmux runs via run-shell (the install marker line does `run-shell <fragment>`),
    # so it sets the hooks + binds against THIS server; run-shell children inherit $TMUX, so
    # `"$BIN" tmux-bind` and the set-hook lines target it. Synchronous (no -b) -> hooks are
    # live when it returns.
    def source_tmux_fragment
      tmux!("run-shell", TMUX_FRAGMENT)
    end

    # A genuinely attached client (stdlib PTY, zero-gem) so the sidebar isn't dormant.
    def attach_client
      @pty, @pty_pid = PTY.spawn("tmux", "attach", "-t", HOME)
      @pty.winsize = [50, 220] # pin the client size: openpty can come up 0x0 (esp. on CI), which would
      start_drain              # leave the session unsized and the render/split waits stuck
      wait_until("the PTY client attaches") { session_attached?(HOME) }
    end

    # Drain the PTY master so tmux's screen writes never fill the kernel pty buffer and
    # stall (or get the client dropped) — the duration-dependent render-flake source.
    def start_drain
      @drain = Thread.new do
        loop { @pty.readpartial(4096) }
      rescue StandardError
        nil # EOF/closed on teardown — done
      end
    end

    def spawn_home_sidebar
      Tmux.spawn_sidebar(target: HOME) # the real production primitive (titles the pane sb-sidebar)
      wait_until("the home sidebar renders") do
        pane = sidebar_pane_ids(HOME).first
        pane && capture(pane).include?("Switchboard")
      end
    end

    # --- teardown steps ------------------------------------------------------

    def stop_drain
      @drain&.kill
      @drain&.join(2)
    rescue StandardError
      nil
    end

    def close_pty
      Process.kill("TERM", @pty_pid) if @pty_pid
    rescue StandardError
      nil
    ensure
      begin
        @pty&.close
      rescue StandardError
        nil
      end
      begin
        Process.wait(@pty_pid) if @pty_pid
      rescue StandardError
        nil
      end
    end

    # --- the socket-safety guard (blast-radius backstop) ---------------------
    # Isolation rests on ENV["TMUX_TMPDIR"]; this is the belt-and-suspenders so a leak
    # (partial setup, a future refactor) can NEVER let a destructive op reach the dev's
    # real switchboard sessions. assert before quit/kill; the predicate gates teardown.

    def current_socket_path
      tmux("display-message", "-p", fmt("socket_path")).strip
    end

    # Delegates to the shared boundary-aware guard (#126) — the realpath + boundary
    # compare that keeps a raw "/tmp/sbk123-10" from matching "/tmp/sbk123-1" lives in
    # IsolatedServer now, so the smoke layer and the sandbox teardown can't diverge.
    def isolated_socket?
      IsolatedServer.isolated_socket?(@sock_dir, current_socket_path)
    end

    def assert_isolated_socket!
      return if isolated_socket?

      raise "SMOKE ABORT: active tmux socket #{current_socket_path.inspect} is not under the " \
            "throwaway #{@sock_dir.inspect} — refusing a destructive op"
    end

    # --- driving the binary --------------------------------------------------

    # Create a placeholder workspace by driving the REAL sidebar UI: press `n`, which
    # auto-creates a placeholder (Creator.create with a blank name) and switches into it —
    # no name prompt anymore (#114/#119). Returns the new session name once it exists, has a
    # sidebar, AND the client has switched into it.
    def create_workspace
      pane = sidebar_pane_ids(HOME).first or flunk "no home sidebar to create from"
      before = sb_sessions
      tmux!("send-keys", "-t", pane, "n")
      wait_until("a new workspace session + sidebar + client switch") do
        sess = (sb_sessions - before).find { |s| s.start_with?("sb/proj/") }
        sess && !sidebar_pane_ids(sess).empty? && client_session == sess && sess
      end
    end

    # Switch the attached client to a session (fires the real client-session-changed hook).
    def switch_client(session)
      tmux!("switch-client", "-t", session)
      wait_until("the client lands on #{session}") { client_session == session }
    end

    # Run a switchboard subcommand as a subprocess. It inherits the sandbox ENV
    # (TMUX_TMPDIR + SWITCHBOARD_BIN), so its bare-tmux calls hit the isolated server; TMUX
    # is unset (SandboxTest), which is correct for quit/rename/prune (no exec-attach path).
    def run_bin(*args)
      system(BIN, *args, out: File::NULL, err: File::NULL)
    end

    # --- tmux query helpers (all scrubbed: a non-UTF-8 pane title must not raise) --------

    def tmux_available?
      system("command -v tmux >/dev/null 2>&1")
    end

    def tmux(*args)
      `tmux #{args.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`.scrub
    end

    def tmux!(*args)
      system("tmux", *args, out: File::NULL, err: File::NULL)
    end

    # Build a literal tmux format token, e.g. fmt("pane_id") => the 9-char string
    # "#{pane_id}". The leading \# escapes Ruby's own interpolation; the inner #{field}
    # is real, so the field name is spliced inside a literal #{...}. Avoids writing the
    # tmux-format escape (#\{...}) at every call site.
    def fmt(field) = "\#{#{field}}"

    def sessions
      tmux("list-sessions", "-F", fmt("session_name")).split("\n").map(&:strip).reject(&:empty?)
    end

    def sb_sessions
      sessions.select { |s| s.start_with?("sb/") }
    end

    def session?(name)
      sessions.include?(name)
    end

    def window_ids(session)
      tmux("list-windows", "-t", session, "-F", fmt("window_id")).split("\n").map(&:strip).reject(&:empty?)
    end

    # [window_id, pane_id, title] for every pane in a session (all windows, -s).
    def session_panes(session)
      tmux("list-panes", "-s", "-t", session, "-F", "#{fmt('window_id')}\t#{fmt('pane_id')}\t#{fmt('pane_title')}")
        .lines.filter_map do |line|
          w, p, t = line.chomp.split("\t", 3)
          [w, p, t.to_s] if w && !w.empty? && p && !p.empty?
        end
    end

    def sidebar_pane_ids(session)
      session_panes(session).select { |_w, _p, t| t == Tmux::SIDEBAR_TITLE }.map { |_w, p, _t| p }
    end

    # The first non-sidebar (work) pane in a session, or nil.
    def work_pane_id(session)
      session_panes(session).find { |_w, _p, t| t != Tmux::SIDEBAR_TITLE }&.[](1)
    end

    # Where Creator puts a worktree: <worktree_root>/<project>/<leaf>.
    def worktree_path(leaf)
      File.join(path("worktrees"), "proj", leaf)
    end

    # Window ids of a session that currently hold a sidebar pane.
    def windows_with_sidebar(session)
      session_panes(session).select { |_w, _p, t| t == Tmux::SIDEBAR_TITLE }.map { |w, _p, _t| w }.uniq
    end

    # Pane count of a session's active window (the #64 lone/healed check).
    def active_window_pane_count(session)
      tmux("display-message", "-p", "-t", session, fmt("window_panes")).strip.to_i
    end

    # Pane ids of a session's active window (where the sidebar + `e`'s editor live).
    def active_window_pane_ids(session)
      tmux("list-panes", "-t", session, "-F", fmt("pane_id")).split("\n").map(&:strip).reject(&:empty?)
    end

    # A pane's #{pane_dead} flag ("1" once its command has exited under remain-on-exit).
    def pane_dead?(pane)
      tmux("display-message", "-p", "-t", pane, fmt("pane_dead")).strip == "1"
    end

    def capture(pane)
      tmux("capture-pane", "-t", pane, "-p")
    end

    def session_attached?(name)
      tmux("display-message", "-p", "-t", name, fmt("session_attached")).strip == "1"
    end

    # The session the (single) attached client is currently in.
    def client_session
      tmux("display-message", "-p", fmt("session_name")).strip
    end

    def sidebar_flag(session)
      tmux("show-options", "-v", "-t", session, "@sb_sidebar").strip
    end

    # --- the anti-flake core -------------------------------------------------

    # Poll `yield` until it returns truthy (returning that value) or `timeout` elapses, in
    # which case flunk with a tmux state dump. Every smoke assertion goes through this —
    # never a fixed sleep then a snapshot assert.
    def wait_until(what = "a condition", timeout: WAIT, interval: 0.05)
      deadline = monotonic + timeout
      loop do
        value = yield
        return value if value
        flunk("timed out after #{timeout}s waiting for #{what}\n#{state_dump}") if monotonic > deadline

        sleep interval
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def state_dump
      "tmux panes:\n" + tmux("list-panes", "-a", "-F",
                             "#{fmt('session_name')} #{fmt('window_index')} #{fmt('pane_id')} [#{fmt('pane_title')}]")
    end
  end
end
