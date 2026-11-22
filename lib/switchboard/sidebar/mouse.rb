# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Mouse: a left click on a row does what ↵ does there, while tmux's `mouse` is on and
    # `sidebar_mouse` isn't false (docs/explanation-sidebar-views.md#clicking-a-row). Only
    # button 1 acts; the wheel, drags and other buttons are read and ignored. A concern
    # module on Sidebar (see CLAUDE.md conventions).
    module Mouse
      # SGR first: without it a click is \e[M plus three raw bytes, which tokenize would
      # fire as keys.
      MOUSE_ON = "\e[?1006h\e[?1000h"
      MOUSE_OFF = "\e[?1000l\e[?1006l"
      MOUSE_REPORT = /\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/n
      CLICK_QUIET = 0.4    # a double-click's second half lands within this
      PRESS_TTL = 1.0      # a press older than this (a drag that ended elsewhere) is forgotten
      MOUSE_READ_TTL = 1.0 # focus_in re-reads tmux's `mouse` at most this often

      def self.report?(token)
        token.start_with?("\e[<") && token.b.match?(MOUSE_REPORT)
      end

      private

      # Ask the terminal for mouse reports only while clicks can act, so with either gate off
      # the sidebar's text selects natively. @mouse starts nil, so the first sync always
      # writes: a hot-reloaded image inherits whatever modes the old one left on the pane.
      def sync_mouse(throttle: false)
        return if throttle && !elapsed?(@mouse_read_at, MOUSE_READ_TTL)

        want = @config.sidebar_mouse? && tmux_mouse?
        return if want == @mouse

        @mouse = want
        @mouse_press = nil
        print(want ? MOUSE_ON : MOUSE_OFF)
        $stdout.flush
      end

      def tmux_mouse?
        @mouse_read_at = monotonic
        Tmux.mouse?(ENV["TMUX_PANE"])
      end

      # A report that can't act, so a read of nothing else needn't repaint.
      def ignored_report?(token)
        Mouse.report?(token) && (!@mouse || token.b[MOUSE_REPORT, 1] != "0")
      end

      # Always true: a report never ends the run loop.
      def mouse(token)
        return true unless @mouse && !@help && !@link_view && !@search.typing?

        button, _x, y, final = token.b.match(MOUSE_REPORT).captures
        return true unless button == "0"

        @count = nil
        y = y.to_i
        @mouse_press = nil if final == "M"
        # Checked before the hit test: a guarded report on a blank or header line still
        # hands focus back.
        return true if quiet_line?(y)
        return click_switch_tail if click_switch_tail?

        final == "M" ? mouse_press(y) : mouse_release(y)
        true
      end

      def mouse_press(y)
        key = row_key_at(y) or return
        i = @rows.index { |n| row_key(n) == key } or return
        @cursor = i
        @mouse_press = [key, y, monotonic]
      end

      # Opens the row the press found, never whatever is on that line now: a repaint between
      # press and release can't redirect the click.
      def mouse_release(y)
        key, pressed_y, at = @mouse_press
        @mouse_press = nil
        return unless key && pressed_y == y && monotonic - at <= PRESS_TTL

        i = @rows.index { |n| row_key(n) == key } or return
        @cursor = i
        @via_click = true
        @search.committed? ? open_from_search : enter(current)
        @mouse_quiet = [y, monotonic + CLICK_QUIET]
      ensure
        @via_click = false
      end

      # The row painted on screen line y (1-based), by identity; nil off the rows.
      def row_key_at(y)
        return nil unless @painted_top

        i = y - @painted_top - 1
        row_key(@visible_rows[i]) if i >= 0 && i < @visible_rows.size # a negative i would wrap
      end

      # The second click of a double-click on the line the first one acted on. Keyed on the
      # line, not the row, because a fold can move another row under it.
      def quiet_line?(y)
        line, till = @mouse_quiet
        line == y && monotonic < till
      end

      # A click switched the client into this session just now (Tmux.stamp_click), so this
      # report is that double-click's second half. Judged on when it could have ARRIVED:
      # input queued while the sidebar was busy (a switch-in reload) is read late, so its
      # earliest possible arrival is @input_since, not the read time. One tmux read a batch.
      def click_switch_tail?
        batch = (@click_batch ||= {})
        marker = batch.fetch(:marker) { batch[:marker] = Tmux.click_switch_at(ENV["TMUX_PANE"]) }
        return false unless marker && @read_at

        (@input_since || @read_at) <= marker + CLICK_QUIET && @read_at >= marker
      end

      # tmux already focused this pane (MouseDown1Pane's select-pane): hand focus back to the
      # work pane, so typing goes to the agent the first click opened.
      def click_switch_tail
        batch = (@click_batch ||= {})
        Tmux.focus_work(Tmux.session_of, ENV["TMUX_PANE"]) unless batch[:handed]
        batch[:handed] = true
        true
      end
    end
    include Mouse
  end
end
