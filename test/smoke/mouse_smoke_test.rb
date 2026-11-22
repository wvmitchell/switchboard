# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # A click on a sidebar row, through a real tmux and the PTY client: what the unit suite
  # stubs (tmux turning the bytes into a report, the pane's modes, the switch) all run here.
  class MouseSmokeTest < SmokeCase
    # Value: protects=the end-to-end click and double-click on a real tmux; fails_when=modes
    # aren't enabled, the hit test is off by the header or status line, a selecting click opens,
    # or the double-click misses; why_new=unit tests stub tmux; seam=none; no_claim=real
    # terminals and a real mouse's timing (checked by hand in the sandbox)
    def test_a_click_selects_and_a_double_click_switches_there
      home = mouse_on # before the workspace's sidebar starts, as it would be for a real user
      sess = create_workspace
      x, y = click_row(home, sess)
      sleep 0.8 # past the double-click window
      assert_equal HOME, client_session, "one click only selects"
      click_at(x, y)
      sleep 0.15
      click_at(x, y)
      wait_until("the double-click switches the client to #{sess}") { client_session == sess }
      sleep 0.3
      assert_equal work_pane_id(sess), tmux("display-message", "-p", "-t", sess, fmt("pane_id")).strip, "focus on the agent"
    end

    # Value: protects=one click on the highlighted row opens it; fails_when=the bar isn't
    # recorded or the hit misses it; why_new=the double-click test always starts unlit;
    # seam=none; no_claim=real terminals
    def test_a_click_on_the_highlighted_row_switches_there
      home = mouse_on
      sess = create_workspace
      x, y = click_row(home, sess)
      sleep 0.8 # the selecting click is long done, and the bar is painted on the row
      assert_equal HOME, client_session, "the first click only selects"
      click_at(x, y)
      wait_until("one click on the lit row switches the client to #{sess}") { client_session == sess }
      sleep 0.3
      assert_equal work_pane_id(sess), tmux("display-message", "-p", "-t", sess, fmt("pane_id")).strip, "focus on the agent"
    end

    # Value: protects=the wheel over the sidebar doesn't freeze it in copy-mode; fails_when=the
    # sidebar stops asking for reports; why_new=new mode handling; seam=none; no_claim=none beyond protects
    def test_the_wheel_over_the_sidebar_does_nothing
      home = mouse_on
      x, y = client_xy(home, 1, 0)
      @pty_in.write("\e[<64;#{x};#{y}M")
      sleep 0.3
      assert_equal "0", tmux("display-message", "-p", "-t", home, fmt("pane_in_mode")).strip
    end

    # Value: protects=keyboard users keep native selection; fails_when=sync_mouse misses focus_in;
    # why_new=no mode test exists; seam=none; no_claim=the lag without a focus-in
    def test_mouse_off_turns_the_sidebars_reports_off_on_focus_in
      home = mouse_on
      tmux!("set-option", "-g", "mouse", "off")
      # focus_in re-reads tmux at most once a second, so keep coming back
      wait_until("the sidebar stops asking for mouse reports", interval: 0.6) do
        refocus(home)
        modes(home) == "00"
      end
    end

    private

    def modes(pane) = tmux("display-message", "-p", "-t", pane, "#{fmt('mouse_standard_flag')}#{fmt('mouse_sgr_flag')}").strip

    # Turn tmux's mouse on and give home's sidebar the focus-in that applies it.
    def mouse_on
      tmux!("set-option", "-g", "status-position", "bottom")
      tmux!("set-option", "-g", "mouse", "on")
      home = sidebar_pane_ids(HOME).first
      refocus(home)
      wait_until("the sidebar asks for mouse reports") { modes(home) == "11" }
      home
    end

    def refocus(pane)
      other = active_window_pane_ids(HOME).find { |p| p != pane }
      tmux!("select-pane", "-t", other) if other
      tmux!("select-pane", "-t", pane)
    end

    # A pane's (col, line), 0-based, to the client's 1-based mouse coordinates.
    def client_xy(pane, col, line)
      left, top = tmux("display-message", "-p", "-t", pane, "#{fmt('pane_left')} #{fmt('pane_top')}").split.map(&:to_i)
      [left + col + 1, top + line + 1]
    end

    def click_at(x, y) = @pty_in.write("\e[<0;#{x};#{y}M\e[<0;#{x};#{y}m")

    def click_row(pane, sess)
      name = sess.delete_prefix("sb/proj/")
      line = wait_until("#{name}'s row is painted") { capture(pane).lines.index { |l| l.include?(name) } }
      x, y = client_xy(pane, 4, line)
      click_at(x, y)
      [x, y]
    end
  end
end
