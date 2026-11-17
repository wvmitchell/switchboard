# frozen_string_literal: true

require_relative "smoke_helper"
require "open3"

module Switchboard
  # `switchboard delete` against a REAL tmux server: the clients, panes, sidebar processes
  # and agent processes the offline suite stubs. Every workspace here is dispatched by the
  # real sidebar, then deleted by the real binary from outside it.
  class DeleteSmokeTest < SmokeCase
    # Run the binary from the test process, on this isolated server.
    def delete(*args)
      env = { "TMUX" => "#{current_socket_path},0,0" } # the dispatch record names this server
      out, err, status = Open3.capture3(env, BIN, "delete", *args)
      [status.exitstatus, out, err]
    end

    def workspace
      sess = create_workspace
      leaf = sess.delete_prefix("sb/proj/")
      wait_until("the build settles") { Creation.all.none? { |r| Creation::PRE_READY.include?(r["state"]) } }
      [sess, leaf, File.realpath(worktree_path(leaf))]
    end

    def sidebar_pids(sess)
      tmux("list-panes", "-s", "-t", sess, "-F", "#{fmt('pane_pid')}\t#{fmt('pane_title')}").lines
        .select { |l| l.include?(Tmux::SIDEBAR_TITLE) }.map(&:to_i)
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    # Value: protects=an attached person blocks an unforced delete, and once they leave it
    # removes the session, its sidebar and the folder; fails_when=clients aren't asked, or
    # the session or sidebar outlives the delete; why_new=the monitor's path; seam=none
    def test_a_client_blocks_the_delete_until_it_leaves
      sess, leaf, real = workspace
      pty, pty_in, pid = PTY.spawn("tmux", "attach", "-t", sess)
      wait_until("a second client is on #{sess}") { tmux("list-clients", "-t", sess).lines.any? }

      code, _out, err = delete(leaf)
      assert_equal 5, code, err
      assert_match(/\A\[busy\] .*client .* attached/, err)
      assert File.exist?(real), "nothing changed"
      assert session?(sess)

      tmux!("detach-client", "-s", sess)
      wait_until("the second client is gone") { tmux("list-clients", "-t", sess).strip.empty? }
      sidebars = sidebar_pids(sess)
      code, out, err = delete(leaf)
      assert_equal 0, code, err
      assert_includes out, "removed: folder"
      refute session?(sess)
      refute File.exist?(real)
      wait_until("its sidebar process is gone") { sidebars.none? { |p| alive?(p) } }
    ensure
      [pty, pty_in].each { |io| io&.close rescue nil }
      Process.wait(pid) rescue nil
    end

    # Value: protects=a human's --force with someone attached leaves them in switchboard;
    # fails_when=the kill detaches the client; why_new=D6; seam=none
    def test_a_forced_delete_sends_an_attached_client_home
      sess, leaf, real = workspace
      pty, pty_in, pid = PTY.spawn("tmux", "attach", "-t", sess)
      wait_until("a client is on #{sess}") { tmux("list-clients", "-t", sess).lines.any? }

      code, _out, err = delete(leaf, "--force")
      assert_equal 0, code, err
      refute session?(sess)
      refute File.exist?(real)
      wait_until("the client lands on #{Tmux::HOME}") do
        tmux("list-clients", "-F", fmt("client_session")).lines.map(&:strip).include?(Tmux::HOME)
      end
      assert_nil Process.waitpid(pid, Process::WNOHANG), "the client is still attached, not detached"
    ensure
      [pty, pty_in].each { |io| io&.close rescue nil }
      Process.wait(pid) rescue nil
    end

    # Value: protects=an agent idle at its prompt (as Claude stays after the ◷ check) doesn't
    # block the monitor's delete, and one with no idle report does; fails_when=any live agent
    # reads as busy, or a hookless one doesn't; why_new=the strict scan; seam=none (a real
    # process whose argv names claude, and a real hook file)
    def test_an_idle_agent_does_not_block_and_a_hookless_one_does
      sess, leaf, real = workspace
      tmux!("send-keys", "-t", work_pane_id(sess), "ruby -e 'sleep' -- claude-stand-in", "Enter")
      wait_until("the stand-in agent runs") { `pgrep -f claude-stand-in`.strip != "" }

      code, _out, err = delete(leaf)
      assert_equal 5, code, err
      assert_match(/no fresh idle state/, err)

      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, "1"), "done\t#{real}\t#{Time.now.to_i}\n")
      code, _out, err = delete(leaf)
      assert_equal 0, code, err
      wait_until("the agent died with its session") { `pgrep -f claude-stand-in`.strip == "" }
    end

    # Value: protects=an agent can't delete the workspace it runs in; fails_when=the pane or
    # cwd check goes; why_new=new refusal; seam=none
    def test_deleting_from_inside_the_workspace_is_refused
      sess, leaf, real = workspace
      result = path("inside-result")
      tmux!("send-keys", "-t", work_pane_id(sess), "#{BIN} delete #{leaf} 2>#{result}; echo $? >>#{result}", "Enter")
      wait_until("the delete ran in the pane") { File.exist?(result) && File.read(result).lines.size >= 2 }
      assert_match(/\A\[inside\]/, File.read(result))
      assert_equal "4", File.read(result).lines.last.strip
      assert File.exist?(real)
    end
  end
end
