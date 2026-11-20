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
    # reads as busy, or a hookless one, or one older than the agent, doesn't; why_new=the strict scan; seam=none (a real
    # process whose argv names claude, and a real hook file)
    def test_an_idle_agent_does_not_block_and_a_hookless_one_does
      sess, leaf, real = workspace
      tmux!("send-keys", "-t", work_pane_id(sess), "ruby -e 'sleep' -- claude-stand-in", "Enter")
      wait_until("the stand-in agent runs") { `pgrep -f claude-stand-in`.strip != "" }

      code, _out, err = delete(leaf)
      assert_equal 5, code, err
      assert_match(/no idle report since it started/, err)

      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, "1"), "done\t#{real}\t#{Time.now.to_i - 3600}\n")
      code, _out, err = delete(leaf)
      assert_equal 5, code, "a `done` from before the agent started (read from the real ps) can't vouch for it"
      assert_match(/no idle report since it started/, err)

      # A report from the agent's own start second reads busy (a tie), so a fast runner could
      # land here inside it: write the fresh `done` once the clock is past that second.
      start = ProcessIdentity.start_epoch(`pgrep -f claude-stand-in`.split.first.to_i) or flunk "no start time"
      wait_until("a second past the agent's start") { Time.now.to_i > start }
      File.write(File.join(AgentState.state_dir, "1"), "done\t#{real}\t#{Time.now.to_i}\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      code, _out, err = delete(leaf)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal 0, code, err
      # Delete waits (up to POST_CLOSE_WAIT) for the agents it recorded to exit after the
      # session kill, so this one is already gone when it returns.
      assert_equal "", `pgrep -f claude-stand-in`.strip, "the agent exited within the post-close wait"
      puts format("\n  delete with a live agent took %.2fs (post-close wait cap %.0fs)", took, Deletion::POST_CLOSE_WAIT)
    end

    # Value: protects=a process that escaped the session (a daemonized dev server) blocks an
    # unforced delete by name, and a forced one too, unsignalled, until someone stops it;
    # then the delete finishes; fails_when=the real scan misses it (lsof on a Mac, /proc on
    # Linux) or --force signals it; why_new=item 1, D7; seam=none (our own daemon, on
    # SmokeCase's isolated server)
    def test_a_process_that_escaped_the_session_blocks_until_stopped
      sess, leaf, real = workspace
      tmux!("send-keys", "-t", work_pane_id(sess), "ruby -e 'Process.daemon(true); sleep' -- escaped-stand-in", "Enter")
      pid = nil
      wait_until("the escaped process runs on its own") do # the daemon, once its parent has exited
        pid = (Processes.in_tree(real) || []).find { |p| p[:comm] == "ruby" && Processes.detached?(p) }&.dig(:pid)
      end

      code, _out, err = delete(leaf)
      assert_equal 5, code, err
      assert_match(/process #{pid} \(ruby\) runs in it outside its tmux session/, err)
      code, _out, err = delete(leaf, "--force")
      assert_equal 8, code, err
      assert_match(/\A\[process-alive\] process #{pid} \(ruby\)/, err)
      assert alive?(pid), "never signalled"
      assert File.exist?(real), "nothing changed"

      Process.kill("KILL", pid)
      wait_until("it is gone") { !alive?(pid) }
      code, _out, err = delete(leaf)
      assert_equal 0, code, err
      refute File.exist?(real)
    ensure
      Process.kill("KILL", pid) if pid&.positive? && alive?(pid)
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
