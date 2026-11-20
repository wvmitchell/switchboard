# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # A bracketed paste into the real sidebar on real tmux is never keys
  # (docs/reference-sidebar.md#pasting): the sidebar turns the mode on, tmux brackets
  # `paste-buffer -p`, and the tree drops what it holds.
  class PasteSmokeTest < SmokeCase
    def write_project_and_config
      super
      @proj2 = temp_git_repo("proj2")
      File.open(ENV["SWITCHBOARD_CONFIG"], "a") { |f| f.puts "  - name: proj2\n    path: #{@proj2}" }
    end

    def on_first_project?(pane) = cursor_row(pane).include?("proj") && !cursor_row(pane).include?("proj2")

    # Value: protects=a pasted line runs none of its letters in the tree; fails_when=the sidebar stops
    # turning bracketed paste on, or the tree dispatches a paste's bytes; why_new=the offline suite feeds
    # markers by hand, never a real terminal's bracketing; seam=none; no_claim=an outer terminal's paste
    def test_a_bracketed_paste_into_the_tree_runs_none_of_its_keys
      pane = sidebar_pane_ids(HOME).first
      flag = tmux("display-message", "-p", "-t", pane, fmt("bracket_paste_flag")).strip
      assert_equal "1", flag, "the sidebar turned bracketed paste on" unless flag.empty? # tmux 3.7+

      tmux!("select-pane", "-t", pane)
      wait_until("the cursor bar shows") { !cursor_row(pane).strip.empty? }
      wait_until("the cursor is on the first project") do
        tmux!("send-keys", "-t", pane, "k") unless on_first_project?(pane)
        on_first_project?(pane)
      end
      before = sb_sessions
      row = cursor_row(pane)

      tmux!("set-buffer", "-b", "sbpaste", "jjq y d y") # jj: a move PR 1's confirm guard doesn't stop
      tmux!("paste-buffer", "-p", "-d", "-b", "sbpaste", "-t", pane)
      deadline = monotonic + 1.5
      while monotonic < deadline
        assert_equal row, cursor_row(pane), "a pasted j moved the cursor"
        sleep 0.05
      end

      assert_equal before, sb_sessions, "nothing quit or closed"
      assert_includes File.read(ENV["SWITCHBOARD_CONFIG"]), "name: proj2", "no project was removed"
      assert_empty Creation.all, "no dispatch was recorded"
      tmux!("send-keys", "-t", pane, "j")
      wait_until("the sidebar still answers a key") { cursor_row(pane) != row }
    end
  end
end
