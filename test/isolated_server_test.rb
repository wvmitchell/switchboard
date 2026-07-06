# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Pure/offline coverage of the shared socket lifecycle (#126). The real
  # boot/attach path is exercised by the smoke layer; here we pin the safety guard
  # and the sweep selection — the bits that must never misjudge.
  class IsolatedServerTest < Minitest::Test
    def setup
      @tmp = Dir.mktmpdir("iso-test")
      @made = []
    end

    def teardown
      FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
      @made.each { |d| FileUtils.remove_entry(d) if File.directory?(d) }
    end

    # --- isolated_socket? (the blast-radius backstop) ------------------------

    def test_isolated_socket_true_for_socket_under_dir
      sock = File.join(@tmp, "sbx1-a")
      Dir.mkdir(sock)
      socket = File.join(File.realpath(sock), "tmux-501", "default")
      assert IsolatedServer.isolated_socket?(sock, socket)
    end

    def test_isolated_socket_false_outside
      sock = File.join(@tmp, "sbx1-a")
      Dir.mkdir(sock)
      refute IsolatedServer.isolated_socket?(sock, "/tmp/somewhere/else/default")
    end

    def test_isolated_socket_false_empty_socket
      sock = File.join(@tmp, "sbx1-a")
      Dir.mkdir(sock)
      refute IsolatedServer.isolated_socket?(sock, "")
    end

    def test_isolated_socket_false_nil_dir
      refute IsolatedServer.isolated_socket?(nil, "/tmp/x/tmux-501/default")
    end

    # The boundary the "+ File::SEPARATOR" defends: "sbx1-1" must NOT match a
    # socket living under the sibling "sbx1-10".
    def test_isolated_socket_boundary_sibling_prefix
      one = File.join(@tmp, "sbx1-1")
      ten = File.join(@tmp, "sbx1-10")
      Dir.mkdir(one)
      Dir.mkdir(ten)
      socket_in_ten = File.join(File.realpath(ten), "tmux-501", "default")
      refute IsolatedServer.isolated_socket?(one, socket_in_ten),
             "sbx1-1 must not match a socket under sbx1-10"
    end

    # --- stale_sock_dirs (the dead-pid sweep selection) ----------------------

    def test_stale_selects_only_dead_pids
      dirs = ["/tmp/sbx111-aa", "/tmp/sbx222-bb"]
      alive = ->(pid) { pid == 222 } # 222 alive, 111 dead
      assert_equal ["/tmp/sbx111-aa"], IsolatedServer.stale_sock_dirs(dirs, "sbx", alive: alive)
    end

    def test_stale_ignores_unparsable_names
      dirs = ["/tmp/sbx-nopid", "/tmp/other333-x"]
      assert_empty IsolatedServer.stale_sock_dirs(dirs, "sbx", alive: ->(_) { false })
    end

    # The prefix is parameterized (F8): an sbx sweep must not touch sbk dirs.
    def test_stale_prefix_is_scoped
      dirs = ["/tmp/sbk111-aa", "/tmp/sbx111-aa"]
      dead = ->(_) { false }
      assert_equal ["/tmp/sbx111-aa"], IsolatedServer.stale_sock_dirs(dirs, "sbx", alive: dead)
      assert_equal ["/tmp/sbk111-aa"], IsolatedServer.stale_sock_dirs(dirs, "sbk", alive: dead)
    end

    # --- kill_env (must never let an inherited $TMUX kill the real server) ---

    def test_kill_env_clears_tmux_and_pins_the_throwaway_dir
      env = IsolatedServer.kill_env("/tmp/sbx1-a")
      assert_equal "/tmp/sbx1-a", env["TMUX_TMPDIR"]
      assert env.key?("TMUX"), "TMUX must be present as a key so system() unsets it for the child"
      assert_nil env["TMUX"], "TMUX must be cleared — else a kill launched with an inherited real $TMUX hits the real server"
    end

    # --- make_socket_dir -----------------------------------------------------

    def test_make_socket_dir_is_unique_and_0700
      a = IsolatedServer.make_socket_dir("sbxtest")
      b = IsolatedServer.make_socket_dir("sbxtest")
      @made.push(a, b)
      refute_equal a, b
      assert File.directory?(a)
      assert_equal "700", format("%o", File.stat(a).mode & 0o777)
      assert File.basename(a).start_with?("sbxtest#{Process.pid}-")
    end

    # --- server.pid record/read (pid-kill a socketless daemon) ---------------

    def test_server_pid_file_lives_in_the_socket_dir
      assert_equal File.join(@tmp, "server.pid"), IsolatedServer.server_pid_file(@tmp)
    end

    def test_recorded_pid_round_trips_a_live_pid_with_matching_identity
      pid = Process.pid # genuinely live, so its start-time matches the recorded token
      File.write(IsolatedServer.server_pid_file(@tmp), "#{pid}\t#{IsolatedServer.process_start(pid)}")
      assert_equal pid, IsolatedServer.recorded_pid(@tmp)
    end

    def test_recorded_pid_rejects_a_recycled_pid_whose_start_time_differs
      # A LIVE pid but a start-time that doesn't match = the pid was recycled since we
      # recorded it. Returning it would let ensure_dead SIGKILL a stranger (maybe the dev's
      # real tmux server) — so an identity mismatch reads as nil and is never killed.
      File.write(IsolatedServer.server_pid_file(@tmp), "#{Process.pid}\tThu Jan  1 00:00:00 1970")
      assert_nil IsolatedServer.recorded_pid(@tmp)
    end

    def test_recorded_pid_is_nil_when_missing_garbled_or_identityless
      assert_nil IsolatedServer.recorded_pid(@tmp), "no server.pid -> nil, not a crash"
      File.write(IsolatedServer.server_pid_file(@tmp), "not-a-pid")
      assert_nil IsolatedServer.recorded_pid(@tmp), "a garbled pid file reads as nil"
      File.write(IsolatedServer.server_pid_file(@tmp), "4242")
      assert_nil IsolatedServer.recorded_pid(@tmp), "a pid with no identity token can't be verified -> nil"
    end

    def test_process_start_present_for_a_live_pid_and_empty_for_a_dead_one
      refute_empty IsolatedServer.process_start(Process.pid), "a live pid has a start time"
      assert_equal "", IsolatedServer.process_start(2_147_483_600), "an unused pid has no start time"
    end

    # --- tmux_comm? (the recycle guard before a pid-kill) --------------------

    def test_tmux_comm_matches_tmux_only
      assert IsolatedServer.tmux_comm?("tmux"),                    "bare name"
      assert IsolatedServer.tmux_comm?("/opt/homebrew/bin/tmux\n"), "absolute path + newline"
      assert IsolatedServer.tmux_comm?("tmux: server"),            "tmux server variant"
      refute IsolatedServer.tmux_comm?("ruby"),                    "a recycled non-tmux pid is NOT ours to kill"
      refute IsolatedServer.tmux_comm?(""),                        "empty (dead pid) is not tmux"
    end

    # ensure_dead must NOT signal a recycled pid whose process is no longer tmux — the
    # guard that keeps a pid-kill from ever hitting a stranger.
    def test_ensure_dead_skips_a_non_tmux_pid
      killed = false
      stub_method(IsolatedServer, :tmux_process?, ->(_) { false }) do
        stub_method(Process, :kill, ->(*) { killed = true }) do
          IsolatedServer.ensure_dead(999_999)
        end
      end
      refute killed, "a pid that isn't a live tmux process must never be signalled"
    end
  end
end
