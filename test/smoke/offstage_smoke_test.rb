# frozen_string_literal: true

require_relative "smoke_helper"
require "json"

module Switchboard
  # The ◷ "waiting on background work" dot end to end in a real attached sidebar: a
  # resting row whose Claude session still reads busy (a background agent running after
  # the turn ended) draws ◷, and goes back to ● once the session settles idle. The
  # "Claude session" is a real process parked in the worktree (ClaudeSessions trusts only
  # a live pid with a matching start time, placed by its kernel cwd) plus the session
  # file Claude would write. No bridge id: the ◷ needs no phone link.
  class OffstageSmokeTest < SmokeCase
    def write_project_and_config
      super
      @wt = worktree_path("bg-ws")
      FileUtils.mkdir_p(File.dirname(@wt))
      git(@project, "worktree", "add", "-q", "-b", "bg-ws", @wt, "main")
      # A settled hand-off: the Stop's done is well past ClaudeSessions::SETTLE.
      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, "smoke-bg-ws"), "done\t#{File.realpath(@wt)}\t#{Time.now.to_i - 30}\n")
    end

    def teardown
      Process.kill("TERM", @sleeper) if @sleeper
      Process.wait(@sleeper) if @sleeper
    rescue StandardError
      nil
    ensure
      super
    end

    def write_session(status, at: Time.now)
      FileUtils.mkdir_p(ClaudeSessions.sessions_dir)
      File.write(File.join(ClaudeSessions.sessions_dir, "#{@sleeper}.json"), JSON.generate(
        "pid" => @sleeper, "sessionId" => "smoke", "cwd" => File.realpath(@wt), "kind" => "interactive",
        "procStart" => ProcessIdentity.start_of(@sleeper), "status" => status,
        "statusUpdatedAt" => (at.to_f * 1000).to_i
      ))
    end

    def row(pane)
      capture(pane).lines.find { |l| l.include?("bg-ws") }.to_s
    end

    def test_a_busy_session_after_its_turn_draws_the_clock_until_it_settles_idle
      pane = sidebar_pane_ids(HOME).first
      refute_nil pane, "home sidebar should exist"
      tmux!("send-keys", "-t", pane, "C-l") # pick up the worktree added before boot
      wait_until("the row renders with its resting ● dot") { row(pane).include?("●") }

      @sleeper = Process.spawn("sleep", "300", chdir: @wt, out: File::NULL, err: File::NULL)
      write_session("busy")
      wait_until("◷ replaces ● while the background work runs") { row(pane).include?("◷") }
      refute_includes row(pane), "●"

      write_session("idle", at: Time.now - 10)
      wait_until("● returns once the session settles idle") { row(pane).include?("●") && !row(pane).include?("◷") }
    end
  end
end
