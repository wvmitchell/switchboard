# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # J/K end to end: workspaces show newest first, K in the on-screen sidebar moves one, and
  # a second, off-screen sidebar repaints in the new order without being switched to (the
  # broadcast and the warm fingerprint, which the stubbed suite can't cross processes for).
  class OrderSmokeTest < SmokeCase
    PEER = "sb/peer"

    def write_project_and_config
      super
      # Created in this order, so newest first is mike, alpha, zeta: not A–Z.
      %w[zeta alpha mike].each do |leaf|
        wt = worktree_path(leaf)
        FileUtils.mkdir_p(File.dirname(wt))
        git(@project, "worktree", "add", "-q", "-b", leaf, wt, "main")
        sleep 0.01 # distinct creation times on coarse filesystems
      end
    end

    def order(pane)
      lines = capture(pane).lines
      %w[zeta alpha mike].sort_by { |n| lines.index { |l| l.include?(n) } || Float::INFINITY }
    end

    def test_k_reorders_and_an_off_screen_sidebar_follows
      home = sidebar_pane_ids(HOME).first
      refute_nil home, "home sidebar should exist"
      tmux!("new-session", "-d", "-s", PEER, "-x", "220", "-y", "50", "-c", ENV["HOME"])
      tmux!("set-option", "-t", PEER, "@sb_sidebar", "on")
      Tmux.spawn_sidebar(target: PEER)
      peer = wait_until("the peer sidebar renders") { (p = sidebar_pane_ids(PEER).first) && capture(p).include?("mike") && p }

      wait_until("newest first in the home sidebar") { order(home) == %w[mike alpha zeta] }
      assert_equal %w[mike alpha zeta], order(peer)

      tmux!("send-keys", "-t", home, "G")
      tmux!("send-keys", "-t", home, "K")
      wait_until("K moves zeta up one in the home sidebar") { order(home) == %w[mike zeta alpha] }
      assert_equal HOME, client_session, "the peer is still off screen"
      # Well inside Sidebar::WARM_TTL: only the broadcast gets it there this fast.
      wait_until("the off-screen peer repaints in the new order", timeout: 8, interval: 0.3) do
        order(peer) == %w[mike zeta alpha]
      end
    end
  end
end
