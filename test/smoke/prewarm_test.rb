# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # The off-screen pre-warm (prewarm), against a REAL tmux server — the one behavior
  # the stubbed unit suite structurally can't reach: an off-screen sidebar process
  # rendering a fresh frame into its pane's grid so a later switch-in shows correct
  # content with no flash. We prove it the strongest way: an agent dot appears in an
  # OFF-screen sidebar's captured buffer WITHOUT ever switching to it. (The config
  # gate, the no-locate/no-throttle invariants, and the hooks-only scan are pinned by
  # the offline unit suite; this is the real-tmux render-to-hidden-buffer proof.)
  class PrewarmTest < SmokeCase
    def test_offscreen_sidebar_warms_in_an_agent_dot_without_a_switch
      sess = create_workspace            # client switches INTO the workspace; HOME goes off-screen
      home_pane = sidebar_pane_ids(HOME).first
      refute_nil home_pane, "home keeps its sidebar process after the switch"
      assert_equal sess, client_session, "precondition: client is in the workspace, HOME is off-screen"
      refute_includes capture(home_pane), "●", "precondition: no done dot yet"

      # Report a 'done' state for the workspace's worktree, exactly as the hook reporter
      # would (<state>\t<cwd>\t<epoch>). HOME's tree lists this worktree, so its row's dot
      # should turn green (●) once HOME's off-screen sidebar warms.
      wt = File.realpath(worktree_path(sess.sub(%r{\Asb/proj/}, "")))
      FileUtils.mkdir_p(AgentState.state_dir)
      File.write(File.join(AgentState.state_dir, "smoke"), "done\t#{wt}\t#{Time.now.to_i}\n")

      # The proof: HOME's OFF-screen sidebar warm-renders the dot into its buffer.
      # Poll gently (every 0.3s, not the 0.05s default) and with generous headroom:
      # the warm rides HOME's off-screen IDLE wake, so a tight capture-pane poll would
      # hammer the tmux server and starve that very wake under load (the flake source).
      wait_until("the off-screen home sidebar warms in the ● done dot", timeout: 60, interval: 0.5) do
        capture(home_pane).include?("●")
      end
      # ...and we never left the workspace — the buffer went fresh with NO switch-in.
      assert_equal sess, client_session, "the dot appeared without ever switching back to HOME"
    end
  end
end
