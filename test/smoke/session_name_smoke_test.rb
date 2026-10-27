# frozen_string_literal: true

require_relative "smoke_helper"
require "json"

module Switchboard
  # Session-name sync end to end against a real tmux server: `switchboard rename` spawns
  # the worker, which finds the agent's pane by tty and types `/rename <name>`. The agent
  # is test/smoke/fake_claude.rb, a stand-in drawing Claude's prompt box — no test drives
  # real Claude. It runs under `sh -c`, so like a dispatched agent it's a grandchild of
  # the pane, not its process.
  class SessionNameSmokeTest < SmokeCase
    FAKE = File.expand_path("fake_claude.rb", __dir__)

    def write_project_and_config
      super
      @wt = worktree_path("first")
      FileUtils.mkdir_p(File.dirname(@wt))
      git(@project, "worktree", "add", "-q", "-b", "first", @wt, "main")
      @control = path("fake-control")
      FileUtils.mkdir_p(@control)
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
    end

    def start_agent(status: "idle")
      set_status(status)
      cmd = "#{Shellwords.escape(RbConfig.ruby)} #{Shellwords.escape(FAKE)} " \
            "#{Shellwords.escape(RemoteLink.sessions_dir)} #{Shellwords.escape(@control)}; true"
      tmux!("new-session", "-d", "-s", "agent", "-x", "120", "-y", "30", "-c", @wt, "sh", "-c", cmd)
      wait_until("the stand-in agent writes its session file") { session && session["status"] == status }
    end

    def set_status(status)
      File.write(File.join(@control, "status"), status)
    end

    def session
      f = Dir.glob(File.join(RemoteLink.sessions_dir, "*.json")).first
      f && JSON.parse(File.read(f))
    rescue JSON::ParserError
      nil
    end

    def keys
      File.exist?(File.join(@control, "keys")) ? File.binread(File.join(@control, "keys")) : ""
    end

    # The worker polls every SessionName::FAST seconds, so a window of two polls plus boot
    # margin proves a "nothing typed" phase actually saw the worker look.
    def quiet_window
      # Past the fast-poll phase the worker backs off and a window could see no poll at all.
      if @started
        assert_operator monotonic - @started, :<, SessionName::FAST_FOR - (2 * SessionName::FAST),
                        "the worker left its fast-poll phase; a quiet window no longer proves anything"
      end
      sleep((2 * SessionName::FAST) + 0.5) # gstack-timing-ok: a negative check needs >= 2 polls to observe
    end

    # The rename an agent would run from inside its workspace, with TMUX pointing at the
    # isolated server so Rename.perform spawns the worker.
    def rename_from_inside(dir, name)
      env = { "TMUX" => "#{current_socket_path},0,0" }
      system(env, BIN, "rename", name, chdir: dir, out: File::NULL, err: File::NULL)
    end

    def test_a_rename_renames_the_idle_off_screen_agent_session
      start_agent
      assert rename_from_inside(@wt, "second"), "the rename succeeds"
      wait_until("the agent's session is renamed") { session&.dig("name") == "second" }
      assert_equal "/rename second\r", keys
    end

    # The sidebar's `r`: the agent's pane stays in view while the keyboard is on the pane
    # beside it, so nobody can type into it — the worker shouldn't wait for you to leave.
    def test_an_agent_pane_in_view_but_not_focused_is_renamed_while_you_watch
      start_agent
      switch_client("agent")
      tmux!("split-window", "-h", "-l", "20", "-t", "agent", "cat") # the new pane takes focus
      leaf = File.basename(@wt)
      assert run_bin("sync-session-name", @wt, leaf)
      wait_until("the agent's session is renamed") { session&.dig("name") == leaf }
      assert_equal "/rename #{leaf}\r", keys
      assert_equal "agent", client_session, "renamed with the client still on the agent's window"
    end

    # Keys typed through a real attached client, in another session entirely, bump tmux's
    # client_activity: the worker holds while someone types anywhere and lands once they stop.
    # The stubs can't show that the live list-clients field moves.
    def test_typing_through_a_client_anywhere_holds_the_worker_until_it_stops
      start_agent
      tmux!("new-session", "-d", "-s", "typing", "cat > /dev/null") # a harmless pane to type into
      switch_client("typing")
      leaf = File.basename(@wt)
      typing = true
      typer = Thread.new do
        Thread.current.report_on_exception = false
        while typing
          @pty_in.write("x")
          sleep 0.4 # gstack-timing-ok: a steady trickle of real keystrokes through the client
        end
      end
      assert run_bin("sync-session-name", @wt, leaf)
      sleep(2 * SessionName::FAST + 0.5) # gstack-timing-ok: a negative check needs >= 2 polls to observe
      assert_empty keys, "nothing typed while someone types elsewhere"
      typing = false
      typer.value # re-raises if the typer died: then nothing was ever typed
      wait_until("the session is renamed once typing stops", timeout: WAIT + 4) { session&.dig("name") == leaf }
      assert_equal "/rename #{leaf}\r", keys
    end

    # A second client attaches, types, and detaches: its client_activity leaves with it, but the
    # live session_activity keeps the stamp, so back-out's last_input still sees the key.
    def test_a_key_from_a_client_that_detached_still_counts
      tmux!("new-session", "-d", "-s", "visit", "cat > /dev/null")
      sleep 1.1 # gstack-timing-ok: whole-second stamps; the key must land in a later second than setup
      before = Time.now.to_i
      io, input, pid = PTY.spawn("tmux", "attach", "-t", "visit")
      input.write("x")
      sleep 0.5 # gstack-timing-ok: let the server stamp the key
      Process.kill("TERM", pid)
      Process.wait(pid)
      wait_until("the visitor is gone") { !tmux("list-clients", "-F", fmt("client_session")).include?("visit") }
      row = Tmux.panes_by_tty.values.first
      assert_operator row[:last_input], :>=, before, "the detached client's key still counts"
    ensure
      io&.close
      input&.close
    end

    def test_the_worker_waits_while_the_agent_is_busy_focused_or_holds_a_draft
      start_agent(status: "busy")
      leaf = File.basename(@wt)
      @started = monotonic
      assert run_bin("sync-session-name", @wt, leaf)
      quiet_window
      assert_empty keys, "nothing typed mid-turn"

      switch_client("agent")
      set_status("idle")
      quiet_window
      assert_empty keys, "nothing typed while the pane is focused"

      tmux!("send-keys", "-t", "agent", "-l", "my draft")
      wait_until("the draft is in the box before focus moves away") { capture("agent").include?("my draft") }
      switch_client(HOME)
      quiet_window
      assert_equal "my draft", keys, "a draft is never touched"

      tmux!("send-keys", "-t", "agent", *Array.new(8, "BSpace"))
      wait_until("the session is renamed once the box is clear", timeout: SessionName::SLOW_CAP + WAIT) do
        session&.dig("name") == leaf
      end
      assert keys.end_with?("/rename #{leaf}\r")
    end
  end
end
