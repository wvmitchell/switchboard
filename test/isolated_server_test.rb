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
  end
end
