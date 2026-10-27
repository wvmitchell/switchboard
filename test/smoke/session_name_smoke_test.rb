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

    def test_the_worker_waits_while_the_agent_is_busy_watched_or_holds_a_draft
      start_agent(status: "busy")
      leaf = File.basename(@wt)
      @started = monotonic
      assert run_bin("sync-session-name", @wt, leaf)
      quiet_window
      assert_empty keys, "nothing typed mid-turn"

      switch_client("agent")
      set_status("idle")
      quiet_window
      assert_empty keys, "nothing typed while you're watching the pane"

      tmux!("send-keys", "-t", "agent", "-l", "my draft")
      wait_until("the draft is in the box before the pane goes off screen") { capture("agent").include?("my draft") }
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
