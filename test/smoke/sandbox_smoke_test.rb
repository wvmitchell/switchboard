# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # The interactive twin's automated proof (issue #126, D7): the `switchboard sandbox`
  # SEED renders in a real attached sidebar, and shared view-state toggles persist to
  # the REDIRECTED (throwaway) state dirs — the isolation the command promises. Reuses
  # the SmokeCase harness (real server + attached PTY) but swaps in the sandbox's own
  # seed_repo + config, rather than spawning the blocking `sandbox` command (which owns
  # the terminal and generates its own socket the harness can't address — F7).
  class SandboxSmokeTest < SmokeCase
    # Override SmokeCase's fixture: seed the sandbox's varied worktrees + config, and
    # mirror the sandbox's SWITCHBOARD_SANDBOX flag so the guarded paths match production.
    def write_project_and_config
      ENV["SWITCHBOARD_SANDBOX"] = "1"
      # #145: mirror the two self-updater guards apply_env exports, BEFORE boot_server's
      # new-session, so the server (hence its panes) inherits them — the propagation path
      # test_updater_guards_propagate_to_a_sandbox_pane checks. Sourced from the real
      # sandbox_env so a regression to "0"/absent fails the smoke too, not just the unit.
      guards = Sandbox.sandbox_env(@sock_dir, path("state"), REPO)[:set]
      ENV["DISABLE_AUTOUPDATER"] = guards["DISABLE_AUTOUPDATER"]
      ENV["DISABLE_UPDATES"]     = guards["DISABLE_UPDATES"]
      @seed = path("sandbox-seed")
      Sandbox.write_git_config
      Sandbox.seed_repo(@seed)
      @project = File.join(@seed, "projects", "sandbox")
      File.write(ENV["SWITCHBOARD_CONFIG"], <<~YAML)
        worktree_root: #{File.join(@seed, 'worktrees')}
        projects_root: #{File.join(@seed, 'projects')}
        base: main
        auto_rename: false
        agent_state_hooks: false
        projects:
          - name: sandbox
            path: #{File.join(@seed, 'projects', 'sandbox')}
      YAML
    end

    # seed_repo already wrote the correctly-shaped, fresh PR cache.
    def seed_pr_cache; end

    def test_seeded_rows_render_and_view_state_stays_isolated
      pane = sidebar_pane_ids(HOME).first
      refute_nil pane, "home sidebar should exist"

      # 1. the seeded fixtures render: the open-PR badge (#12, NOT #?) + its worktree,
      #    and the multi-branch workspace's expanded branch row.
      wait_until("the seeded PR badge #12 renders") { capture(pane).include?("#12") }
      screen = capture(pane)
      assert_includes screen, "auth-token-refresh", "the open-PR worktree row"
      assert_includes screen, "sidebar-polish", "the multi-branch worktree row"
      assert_includes screen, "watch-ci", "the background-monitor worktree row"
      assert_includes screen, "∞", "the monitored workspace renders the ∞ dot (resting -> ∞, not ●)"

      # 2. isolation proof: two GLOBAL view-state toggles (branch-fold `z`, full-header
      #    `H`) must write their markers into the THROWAWAY state tree, never real state.
      #    (The markers resolve under XDG_STATE_HOME here, which SandboxTest roots in @dir.)
      tmux!("send-keys", "-t", pane, "z")
      wait_until("branch-fold marker lands under the throwaway state tree") { BranchFold.folded? }
      assert BranchFold.marker.start_with?(@dir), "branch-fold marker escaped the sandbox tree"

      tmux!("send-keys", "-t", pane, "H")
      wait_until("full-header marker lands under the throwaway state tree") { FullHeader.enabled? }
      assert FullHeader.marker.start_with?(@dir), "full-header marker escaped the sandbox tree"

      # 3. teardown will only ever kill OUR throwaway server — the shared guard agrees
      #    this socket is isolated, so kill-server on detach can't reach a real server.
      assert isolated_socket?, "the active socket must be recognized as the throwaway one"
    end

    # #145: the presence-in-hash unit test proves sandbox_env carries the guards; this
    # proves they actually REACH the child process the auto-updater runs in. The guard is
    # worthless if it stops at the ruby ENV and never lands in a pane shell. A background
    # new-window runs the probe in a real pane shell (which inherits the server env booted
    # with the guards set) — deterministic, unlike send-keys into an interactive prompt.
    def test_updater_guards_propagate_to_a_sandbox_pane
      probe = path("updater-probe")
      tmux!("new-window", "-t", HOME, "-d",
            "printf '%s,%s' \"$DISABLE_AUTOUPDATER\" \"$DISABLE_UPDATES\" > #{probe}")
      got = wait_until("a pane shell writes the inherited updater vars") do
        File.exist?(probe) && !File.read(probe).empty? && File.read(probe)
      end
      assert_equal "1,1", got, "a pane shell did not inherit both self-updater guards (#145)"
    end
  end
end
