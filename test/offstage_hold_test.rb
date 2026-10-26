# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The shared on-disk ◷ hold: written by any pane, claimed by exactly one.
  class OffstageHoldTest < SandboxTest
    def wt(name)
      d = path("worktrees", name)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def test_a_hold_is_seen_by_its_raw_path_with_its_pid
      w = wt("alpha")
      OffstageHold.hold(w, pid: 4242, now: Time.at(1_000))
      assert_equal({ w => { pid: 4242, at: 1_000 } }, OffstageHold.held([w, wt("beta")]))
    end

    # Value: protects=exactly one pane rings a matured hold; fails_when=claim succeeds without
    # deleting (or ignores a failed delete); why_new=new store; seam=none; no_claim=two real processes
    def test_claim_succeeds_once
      w = wt("alpha")
      OffstageHold.hold(w, pid: 1)
      assert OffstageHold.claim(w)
      refute OffstageHold.claim(w), "a second pane loses"
      assert_empty OffstageHold.held([w])
    end

    def test_release_drops_it_silently
      w = wt("alpha")
      OffstageHold.hold(w, pid: 1)
      OffstageHold.release(w)
      assert_empty OffstageHold.held([w])
      refute OffstageHold.claim(w)
    end

    def test_a_gone_worktree_is_gced
      w = wt("alpha")
      OffstageHold.hold(w, pid: 1)
      FileUtils.rm_rf(w)
      assert_empty OffstageHold.held([w])
      assert_empty Dir.children(OffstageHold.state_dir)
    end

    def test_carry_follows_a_rename
      a = wt("A")
      b = wt("B")
      OffstageHold.hold(a, pid: 7, now: Time.at(1_000))
      OffstageHold.carry(a, b)
      assert_equal({ b => { pid: 7, at: 1_000 } }, OffstageHold.held([a, b]), "pid and hold time carried")
    end

    def test_clear_all_wipes_every_hold
      OffstageHold.hold(wt("alpha"), pid: 1)
      OffstageHold.hold(wt("beta"), pid: 1)
      OffstageHold.clear_all
      assert_empty OffstageHold.held([path("worktrees", "alpha"), path("worktrees", "beta")])
    end
  end
end
