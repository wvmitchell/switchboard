# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Prompt (#57): the bottom-row raw-mode widget the actions lean on — the
    # y/N confirm, the inline line editor with its paste-safe token loop
    # (issue #68), the dim-hint prompt paint, and the flash message. Stays raw
    # the whole time so Esc/Ctrl-C arrive as bytes and always cancel.
    module Prompt
      PASTE_START = "\e[200~" # bracketed paste (the task prompt turns it on)
      PASTE_END = "\e[201~"

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
      # out but a bare ↵ (undiscoverable) or killing the sidebar. Shared by a/r/n so
      # every prompt cancels the same way. The hidden cursor is restored in an
      # ensure so a raise can't strand a visible block cursor; any read fault returns
      # nil (cancel), the same graceful-degrade contract the cooked version had.
      #
      # `task: true` is the dispatch prompt (`n`): a task is a sentence, not a name, so
      # an overflowing line scrolls to the caret instead of clipping what you're typing
      # (DR11), a multi-line paste folds into one line instead of submitting its first
      # line on the spot (DR12), and it keeps non-ASCII text (a task pasted from Slack
      # has smart quotes; a name stays ASCII). Pastes are fenced with bracketed paste,
      # so a paste spread over many reads stays text — none of it can submit early or
      # spill into the tree as keystrokes (where `d`…`y` deletes). Name prompts keep the
      # original behavior.
      def prompt_line(label, hint: " (esc cancel)", task: false)
        # bare ↵ ⇒ "": a name prompt cancels on it, the task prompt makes a bare create.
        # The task buffer holds raw bytes (UTF-8 can arrive split across reads).
        buf = task ? String.new : +""
        paste = { on: false }
        print "\e[?2004h" if task
        draw_prompt(label, display_text(buf, task), hint: hint, tail: task)
        typed = @typeahead&.join.to_s # keys already read past the one that opened us
        @typeahead&.clear
        loop do
          chunk = typed.empty? ? read_prompt_key : typed
          typed = ""
          return nil if chunk.nil? # read fault / dead pane: cancel
          case edit_buffer(chunk, buf, fold_newlines: task, paste: task ? paste : nil)
          when :cancel then return nil
          when :submit
            drain_input if task # whatever followed the ↵ in flight was never meant as keys
            return display_text(buf, task).strip
          end
          draw_prompt(label, display_text(buf, task), hint: hint, tail: task)
        end
      rescue StandardError
        nil
      ensure
        print "\e[?2004l" if task
        print "\e[?25l"
      end

      def display_text(buf, task)
        task ? buf.dup.force_encoding(Encoding::UTF_8).scrub("") : buf
      end

      # Discard input already waiting (never blocks).
      def drain_input
        loop { $stdin.read_nonblock(1024) }
      rescue IO::WaitReadable, EOFError, StandardError
        nil
      end

      # Fold one raw read into the prompt buffer, returning :submit / :cancel / :edit. A
      # read arrives as a burst — a paste (the `a` clone URL / local path), or a fast
      # key-repeat — so process it token by token the way the main loop's `handle`
      # does (escape-led tokens are 3 bytes), NOT all-or-nothing: a pasted URL must
      # land its printable bytes while an arrow burst ("\e[A") still drops whole rather
      # than leaking "[A" into the name. Cooked `gets` buffered pastes for free; raw
      # mode has to reassemble them here.
      #
      # With fold_newlines (the task prompt), text between bracketed-paste markers
      # (`paste:` carries the in-a-paste state across reads) is literal: newlines fold
      # to one space, nothing in it is a key. Outside a paste — a terminal without
      # bracketed paste — a ↵ submits when it's the read's ONLY newline and its last
      # byte (a lone ↵, or a fast last key + ↵ batched into one read); a read with
      # several lines folds them too.
      #
      # A marker can straddle two reads (a paste longer than one read), so a read that
      # ENDS in part of one holds that part back (`paste[:carry]`) for the next: a split
      # end marker would otherwise leave the prompt in paste mode, swallowing ↵/Esc/^C.
      # Outside a paste only a 3+ byte start (`\e[2`…) is held, so a lone Esc still
      # cancels and `\e[` + ↵ still submits.
      def edit_buffer(chunk, buf, fold_newlines: false, paste: nil)
        rest = paste ? paste.delete(:carry).to_s + chunk.b : chunk.b
        until rest.empty?
          if paste&.fetch(:on)
            text, sep, rest = rest.partition(PASTE_END)
            text, paste[:carry] = held_marker(text, PASTE_END, 1) if sep.empty?
            add_pasted(buf, text)
            paste[:on] = false unless sep.empty?
            next
          end
          keys, sep, rest = paste ? rest.partition(PASTE_START) : [rest, "", ""]
          keys, paste[:carry] = held_marker(keys, PASTE_START, 3) if paste && sep.empty?
          result = edit_keys(keys, buf, fold_newlines: fold_newlines)
          return result unless result == :edit

          paste[:on] = true unless sep.empty?
        end
        :edit
      end

      # [text, held]: the longest proper prefix of `marker` (at least `min` bytes) that
      # `text` ends with is split off to wait for the rest of the marker.
      def held_marker(text, marker, min)
        (marker.length - 1).downto(min) do |k|
          return [text[0...-k], marker[0, k]] if text.end_with?(marker[0, k])
        end
        [text, ""]
      end

      def edit_keys(chunk, buf, fold_newlines: false)
        typed_enter = chunk.match?(/\A[^\r\n]*(\r\n?|\n)\z/)
        chunk = chunk.dup # slice! mutates; never consume the caller's (possibly frozen) read
        until chunk.empty?
          token = chunk.start_with?("\e") ? chunk.slice!(0, 3) : chunk.slice!(0, 1)
          if fold_newlines && !typed_enter && ["\r", "\n"].include?(token)
            fold_space(buf)
            next
          end
          case token
          when "\e", "\x03" then return :cancel  # bare Esc / Ctrl-C
          when "\r", "\n"   then return :submit  # ↵ (a name prompt drops the rest of a paste, like gets; the task prompt folded it above)
          when "\x7F", "\b" then backspace(buf, fold_newlines)
          when "\x15"       then buf.clear       # Ctrl-U: clear the line
          else buf << token if printable?(token) || (fold_newlines && token.getbyte(0) >= 0x80)
          end
        end
        :edit
      end

      # Pasted text: printable and non-ASCII bytes land, newlines/tabs fold to a space,
      # other control bytes (a stray escape) drop.
      def add_pasted(buf, text)
        text.each_byte do |b|
          if b >= 0x80 || b.between?(0x20, 0x7E) then buf << b.chr
          elsif [0x0A, 0x0D, 0x09].include?(b) then fold_space(buf)
          end
        end
      end

      def fold_space(buf)
        buf << " " unless buf.empty? || buf.end_with?(" ") # "\r\n" folds to ONE space
      end

      # One CHARACTER back: in the task prompt that may be several UTF-8 bytes.
      def backspace(buf, task)
        return buf.chop! unless task

        text = buf.dup.force_encoding(Encoding::UTF_8).scrub("")
        text.chop!
        buf.replace(text.b)
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
      def draw_prompt(label, buf, hint: " (esc cancel)", tail: false)
        rows, cols = winsize
        prefix = "#{label} › "
        # The hint must live INSIDE the width budget. Truncating only prefix+buf and
        # tacking the hint on after let a long label + the hint overflow the 40-col pane;
        # the 41st char auto-wrapped (DECAWM) on the bottom row and scrolled a stale
        # prompt copy into scrollback every cancel→reopen (issue #80). Reserve the hint's
        # display width so the whole line fits — a long label is clipped while empty (the
        # hint always shows) and restored the moment you type (hint gone). Held plain for
        # the width count; the dim SGR is applied only at print time.
        hint   = buf.empty? ? hint : ""
        shown  = tail ? tail_view(prefix, buf, cols - hint.length) : trunc(prefix + buf, cols - hint.length)
        print "\e[#{rows};1H\e[K#{shown}#{hint.empty? ? '' : "\e[2m#{hint}\e[0m"}"
        caret = [columns(shown) + 1, cols].min # 1-based, parked right after the visible input
        print "\e[#{rows};#{caret}H\e[?25h"
        $stdout.flush
      end

      # The prompt line with the END of the input visible once it overflows: the label,
      # a leading `…`, then the tail of the buffer, so the caret and what you just typed
      # are always on screen. Falls back to the clipped line when even that won't fit.
      # Measured in COLUMNS (render's `columns`): a task keeps CJK/emoji, and a line one
      # column too wide on the bottom row would wrap and scroll the whole pane.
      def tail_view(prefix, buf, width)
        line = prefix + buf
        return line if columns(line) <= width

        keep = width - columns(prefix) - 1
        return trunc(line, width) if keep < 4

        tail = +""
        used = 0
        buf.each_char.reverse_each do |c|
          break if used + columns(c) > keep

          tail.prepend(c)
          used += columns(c)
        end
        "#{prefix}…#{tail}"
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
