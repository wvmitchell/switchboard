# frozen_string_literal: true

require_relative "../test_helper"

module Switchboard
  # Real-tmux proof that IsolatedServer.kill_server reaps a throwaway daemon EVEN AFTER
  # its socket is unlinked — the socketless-server leak that stranded ~15 zombie servers.
  # A tmux daemon outlives its socket, so `kill-server` (path-based) can't reach it; only
  # the recorded-pid SIGKILL can. Boots a BARE server on an isolated short socket, so it
  # needs neither SmokeCase's PTY/sidebar rig nor its SWITCHBOARD_SANDBOX wiring — just
  # SandboxTest's env wall-off plus a real tmux.
  class IsolatedServerSmokeTest < SandboxTest
    def setup
      super
      skip "real-tmux smoke layer needs tmux on PATH" unless system("command -v tmux >/dev/null 2>&1")
      @dirs = []
    end

    def teardown
      @dirs.each do |dir|
        IsolatedServer.kill_server(dir) # idempotent: reaps anything a test left running
        FileUtils.remove_entry(dir) if File.directory?(dir)
      end
    ensure
      super
    end

    # Boot a bare throwaway daemon on a fresh short socket; return [dir, pid].
    def boot
      dir = IsolatedServer.make_socket_dir("sbk")
      @dirs << dir
      system(IsolatedServer.kill_env(dir), "tmux", "new-session", "-d", "-s", "smoke",
             out: File::NULL, err: File::NULL)
      [dir, IsolatedServer.record_server_pid(dir)]
    end

    def test_kill_server_reaps_a_reachable_server
      dir, pid = boot
      assert pid, "recorded the server pid at boot"
      assert IsolatedServer.pid_alive?(pid), "server is up"

      IsolatedServer.kill_server(dir)
      refute IsolatedServer.pid_alive?(pid), "kill-server + ensure_dead reaps a live server"
    end

    # The regression: unlink the socket out from under the daemon (keep server.pid), then
    # kill_server must STILL reap it — via the recorded pid, since kill-server can no longer
    # reach a socketless daemon. This is the exact state the ~15 stranded zombies were in.
    def test_kill_server_reaps_a_socketless_daemon_by_recorded_pid
      dir, pid = boot
      assert pid && IsolatedServer.pid_alive?(pid), "daemon is up with a recorded pid"

      FileUtils.remove_entry(File.join(dir, "tmux-#{Process.uid}")) # unlink the socket
      assert_nil IsolatedServer.read_server_pid(dir), "socket gone -> a live pid read fails"
      assert_equal pid, IsolatedServer.recorded_pid(dir), "but server.pid survives in the dir"
      assert IsolatedServer.pid_alive?(pid), "the daemon outlives its socket"

      IsolatedServer.kill_server(dir)
      refute IsolatedServer.pid_alive?(pid), "a socketless daemon is still reaped via server.pid"
    end
  end
end
