# frozen_string_literal: true

require_relative "smoke_helper"
require "json"

module Switchboard
  # The ⇅ remote-link glyph end to end in a real attached sidebar (eng review D7):
  # a /remote-control link appears on its workspace row, clears when the link ends,
  # and never disturbs the agent dot beside it. The "Claude session" is a real
  # process parked in the worktree (RemoteLink trusts only a live pid with a matching
  # start time, placed by its kernel cwd) plus the session file Claude would write.
  class RemoteLinkSmokeTest < SmokeCase
    LINK_ID = "session_01SmokeTestLinkIdAbcdefG" # production-length: a 55-byte URL, a 33-module code

    def write_project_and_config
      super
      @wt = worktree_path("phone-ws")
      FileUtils.mkdir_p(File.dirname(@wt))
      git(@project, "worktree", "add", "-q", "-b", "phone-ws", @wt, "main")
      seed_done_dot(@wt)
    end

    def teardown
      Process.kill("TERM", @sleeper) if @sleeper
      Process.wait(@sleeper) if @sleeper
    rescue StandardError
      nil
    ensure
      super
    end

    # A fresh hook report so the row carries a resting ● we can watch for disturbance.
    def seed_done_dot(worktree)
      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, "smoke-phone-ws"), "done\t#{File.realpath(worktree)}\t#{Time.now.to_i}\n")
    end

    def write_session(**over)
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
      data = { "pid" => @sleeper, "sessionId" => "smoke", "cwd" => File.realpath(@wt), "kind" => "interactive",
               "procStart" => ProcessIdentity.start_of(@sleeper), "status" => "busy",
               "statusUpdatedAt" => (Time.now.to_f * 1000).to_i, "bridgeSessionId" => LINK_ID }.merge(over)
      data.delete_if { |_, v| v.nil? }
      File.write(File.join(RemoteLink.sessions_dir, "#{@sleeper}.json"), JSON.generate(data))
    end

    def row(pane)
      capture(pane).lines.find { |l| l.include?("phone-ws") }.to_s
    end

    def test_a_link_shows_and_clears_on_its_row_and_leaves_the_dot_alone
      pane = sidebar_pane_ids(HOME).first
      refute_nil pane, "home sidebar should exist"
      tmux!("send-keys", "-t", pane, "C-l") # pick up the worktree added before boot
      wait_until("the linked workspace row renders with its ● dot") { row(pane).include?("●") }
      refute_includes row(pane), "⇅", "no link yet"

      @sleeper = Process.spawn("sleep", "300", chdir: @wt, out: File::NULL, err: File::NULL)
      write_session
      wait_until("the ⇅ appears after /rc") { row(pane).include?("⇅") }
      assert_includes row(pane), "●", "the agent dot is untouched by the link"

      write_session("bridgeSessionId" => nil) # /rc off: Claude removes the key
      wait_until("the ⇅ clears after the link ends") { !row(pane).include?("⇅") }
      assert_includes row(pane), "●", "and the dot is still there"
    end

    # The p overlay in a real pane: the code paints at its real size, and the link
    # ending (a scan re-checks it) closes it back to the tree.
    def test_p_draws_the_link_as_a_qr_and_closes_when_the_link_ends
      pane = sidebar_pane_ids(HOME).first
      tmux!("send-keys", "-t", pane, "C-l")
      wait_until("the workspace row renders") { row(pane).include?("phone-ws") }
      @sleeper = Process.spawn("sleep", "300", chdir: @wt, out: File::NULL, err: File::NULL)
      write_session
      wait_until("the ⇅ appears") { row(pane).include?("⇅") }

      tmux!("send-keys", "-t", pane, "G", "p") # phone-ws is the last row
      url = "https://claude.ai/code/#{LINK_ID}"
      screen = nil
      wait_until("the code and the URL under it paint") { (screen = capture(pane)).delete("\n").include?(url) }
      width = tmux("display-message", "-p", "-t", pane, fmt("pane_width")).strip.to_i
      side = ((width - 33) / 2).clamp(2, 4)
      code = screen.lines.select { |l| l.include?("▀") }
      assert_equal [33 + (2 * side)], code.map { |l| l.count("▀") }.uniq, "a 33-module code with its margin"

      write_session("bridgeSessionId" => nil)
      wait_until("the overlay closes back to the tree") { !capture(pane).include?("▀") && row(pane).include?("phone-ws") }
    end
  end
end
