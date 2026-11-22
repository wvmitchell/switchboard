# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Mouse: a left click selects a row, and a click on the highlighted row (so a
    # double-click too) does what ↵ does there, while
    # tmux's `mouse` is on and `sidebar_mouse` isn't false (docs/explanation-sidebar-views.md#clicking-a-row). Only
    # button 1 acts; the wheel, drags and other buttons are read and ignored. A concern
    # module on Sidebar (see CLAUDE.md conventions).
    module Mouse
      # SGR first: without it a click is \e[M plus three raw bytes, which tokenize would
      # fire as keys.
      MOUSE_ON = "\e[?1006h\e[?1000h"
      MOUSE_OFF = "\e[?1000l\e[?1006l"
      MOUSE_REPORT = /\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/n
      DOUBLE_CLICK = 0.5   # a second click on the same row within this opens it
      CLICK_SETTLE = 0.35  # tmux runs its DoubleClick1Pane binding this long after (open_due_click)
      FOCUS_SETTLE = 0.05  # a focus-in this fresh came with the press: the bar wasn't lit
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
        final == "M" ? mouse_press(y.to_i) : mouse_release(y.to_i)
        true
      end

      # The cursor moves on the press, so a click shows its row before the button comes up.
      # Whether the bar was already on that row is read first: tmux focuses the pane as part
      # of the click, so a focus-in just now means the bar wasn't showing when you clicked.
      def mouse_press(y)
        @mouse_press = nil
        key = row_key_at(y) or return
        i = @rows.index { |n| row_key(n) == key } or return
        lit = @painted_bar == key && elapsed?(@focused_at, FOCUS_SETTLE)
        @cursor = i
        @mouse_press = [key, y, monotonic, lit]
      end

      # A click (press and release on one line) selects; one on the row the bar already lit
      # opens it, as does the second of a double-click (in case no repaint lit it between) or
      # any click while that row's open is pending. It opens the row the press found, never
      # whatever is on that line now, so a repaint between press and release can't redirect it.
      def mouse_release(y)
        key, pressed_y, at, lit = @mouse_press
        @mouse_press = nil
        return unless key && pressed_y == y && monotonic - at <= PRESS_TTL

        i = @rows.index { |n| row_key(n) == key } or return
        @cursor = i
        last_key, last_y, till = @mouse_click
        again = last_key == key && last_y == y && monotonic < till
        if lit || again || @mouse_open&.first == key
          @mouse_click = nil
          @mouse_open = [key, monotonic + CLICK_SETTLE] # a pending one waits out the new click
        else
          @mouse_open = nil
          @mouse_click = [key, y, monotonic + DOUBLE_CLICK]
        end
      end

      # tmux sees a double-click too: ~0.3 s after it (waiting out a triple-click) its
      # DoubleClick1Pane binding selects the pane under the mouse. A switch before then would
      # hand it the new session's sidebar, taking focus from the agent, so every open waits
      # long enough to know no second click is coming.
      def open_due_click
        key, at = @mouse_open
        return unless key && monotonic >= at

        @mouse_open = nil
        return if @help || @link_view || @search.typing? # opened since: that has the keys now

        i = @rows.index { |n| row_key(n) == key } or return
        @cursor = i
        @search.committed? ? open_from_search : enter(current)
      end

      def mouse_open_wait
        [@mouse_open[1] - monotonic, 0].max if @mouse_open
      end

      # The row painted on screen line y (1-based), by identity; nil off the rows.
      def row_key_at(y)
        return nil unless @painted_top

        i = y - @painted_top - 1
        row_key(@visible_rows[i]) if i >= 0 && i < @visible_rows.size # a negative i would wrap
      end
    end
    include Mouse
  end
end
