# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Prompt (#57): the bottom-row raw-mode widget the actions lean on — the
    # y/N confirm, the inline line editor with its paste-safe token loop
    # (issue #68), the dim-hint prompt paint, and the flash message. Stays raw
    # the whole time so Esc/Ctrl-C arrive as bytes and always cancel.
    module Prompt
      private

      # Single-key y/N confirmation on the bottom row.
      def confirm(message)
        rows, = winsize
        print "\e[#{rows};1H\e[K\e[?25h#{message} [y/N] "
        $stdout.flush
        answer = read_char
        print "\e[?25l"
        answer.to_s.downcase == "y"
      end

      # Inline line prompt on the bottom row, edited in raw mode (issue #68). We stay
      # raw — never drop to cooked — so the line discipline can't swallow Esc as a
      # literal byte: Esc and Ctrl-C cancel (return nil), ↵ submits the stripped text,
      # Backspace/Ctrl-U edit. The old cooked `$stdin.gets` left the prompt with no way
      # out but a bare ↵ (undiscoverable) or killing the sidebar. Shared by a/r so
      # every name prompt cancels the same way (`n` no longer prompts — #114). The hidden cursor is restored in an
      # ensure so a raise can't strand a visible block cursor; any read fault returns
      # nil (cancel), the same graceful-degrade contract the cooked version had.
      def prompt_line(label)
        buf = +"" # collects the typed text; bare ↵ ⇒ "" ⇒ blank_input? cancels
        draw_prompt(label, buf)
        loop do
          chunk = read_prompt_key
          return nil if chunk.nil? # read fault / dead pane: cancel
          case edit_buffer(chunk, buf)
          when :cancel then return nil
          when :submit then return buf.strip # bare ↵ ⇒ "" ⇒ blank_input? cancels too
          end
          draw_prompt(label, buf)
        end
      rescue StandardError
        nil
      ensure
        print "\e[?25l"
      end

      # Fold one raw read into the name buffer, returning :submit / :cancel / :edit. A
      # read arrives as a burst — a paste (the `a` clone URL / local path), or a fast
      # key-repeat — so process it token by token the way the main loop's `handle`
      # does (escape-led tokens are 3 bytes), NOT all-or-nothing: a pasted URL must
      # land its printable bytes while an arrow burst ("\e[A") still drops whole rather
      # than leaking "[A" into the name. Cooked `gets` buffered pastes for free; raw
      # mode has to reassemble them here.
      def edit_buffer(chunk, buf)
        chunk = chunk.dup # slice! mutates; never consume the caller's (possibly frozen) read
        until chunk.empty?
          token = chunk.start_with?("\e") ? chunk.slice!(0, 3) : chunk.slice!(0, 1)
          case token
          when "\e", "\x03" then return :cancel  # bare Esc / Ctrl-C
          when "\r", "\n"   then return :submit  # ↵ (rest of a multi-line paste is dropped, like gets)
          when "\x7F", "\b" then buf.chop!       # Backspace (DEL / ^H)
          when "\x15"       then buf.clear       # Ctrl-U: clear the line
          else buf << token if printable?(token) # printable byte ⇒ name; arrow/fn bursts drop
          end
        end
        :edit
      end

      # Block for the next raw read and return its bytes — a keypress, an escape
      # sequence, or a whole paste (read big so a pasted URL lands in one go, not 8
      # bytes at a time). We're already raw, so Esc and Ctrl-C arrive as bytes here,
      # not as a swallowed control or a signal. nil on a dead pane (EOF) so prompt_line
      # cancels rather than spinning; a spurious select wakeup with nothing to read
      # retries rather than cancelling, matching read_key's no-op on the same race.
      def read_prompt_key
        IO.select([$stdin]) # block until there's something to read
        $stdin.read_nonblock(1024)
      rescue IO::WaitReadable
        retry
      rescue EOFError
        nil
      end

      # Repaint the inline prompt on the bottom row and park a real cursor right after
      # the typed text. An empty buffer shows a dim hint advertising the escape hatch
      # (issue #68); it clears the moment you type so a long name isn't crowded on the
      # narrow pane. The caret column is set explicitly so the hint can trail the input
      # without the caret jumping past it.
      def draw_prompt(label, buf)
        rows, cols = winsize
        prefix = "#{label} › "
        # The hint must live INSIDE the width budget. Truncating only prefix+buf and
        # tacking the hint on after let a long label + the hint overflow the 40-col pane;
        # the 41st char auto-wrapped (DECAWM) on the bottom row and scrolled a stale
        # prompt copy into scrollback every cancel→reopen (issue #80). Reserve the hint's
        # display width so the whole line fits — a long label is clipped while empty (the
        # hint always shows) and restored the moment you type (hint gone). Held plain for
        # the width count; the dim SGR is applied only at print time.
        hint   = buf.empty? ? " (esc cancel)" : ""
        shown  = trunc(prefix + buf, cols - hint.length)
        print "\e[#{rows};1H\e[K#{shown}#{hint.empty? ? '' : "\e[2m#{hint}\e[0m"}"
        caret = [shown.length + 1, cols].min # 1-based, parked right after the visible input
        print "\e[#{rows};#{caret}H\e[?25h"
        $stdout.flush
      end

      # An empty prompt result — nil (read failed / cancelled) or "" (bare enter) — means cancel.
      def blank_input?(text)
        text.nil? || text.empty?
      end

      # Surface an error on the bottom row and wait for a keypress, so it's
      # readable before the next repaint wipes it.
      def flash(message)
        rows, cols = winsize
        print "\e[#{rows};1H\e[K\e[31m#{trunc(message, cols - 11)}\e[0m — any key "
        $stdout.flush
        read_char
      end

      # One key in raw mode (nil if the read fails).
      def read_char
        $stdin.getc
      rescue StandardError
        nil
      end
    end
    include Prompt
  end
end
