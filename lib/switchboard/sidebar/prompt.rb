# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Prompt (#57): the bottom-row raw-mode widget the actions lean on — the
    # y/N confirm, the inline line editor with its paste-safe token loop
    # (issue #68), the dim-hint prompt paint, and the flash message. Stays raw
    # the whole time so Esc/Ctrl-C arrive as bytes and always cancel.
    module Prompt
      FOCUS_OUT = "\e[O"
      ONE_KEY_PASTE_NOTICE = "switchboard: paste ignored, so the prompt closed with no answer"
      C1_PAIR = /\xC2[\x80-\x9F]/n

      private

      # Single-key y/N confirmation on the bottom row.
      def confirm(message)
        rows, = winsize
        print "\e[#{rows};1H\e[K\e[?25h#{shown(message)} [y/N] "
        $stdout.flush
        answer = read_char
        print "\e[?25l"
        answer.to_s.downcase == "y"
      end

      # Context for the confirm that follows, on the rows above it. False when it can't all
      # fit, so the caller doesn't ask about what it couldn't show. Each line is cut by
      # columns, because a wrapped one would scroll the frame. The next render repaints these rows.
      def paint_above_prompt(lines)
        return true if lines.empty?

        rows, cols = winsize
        return false if lines.size > rows - 1

        top = rows - lines.size
        print lines.each_with_index.map { |text, i| "\e[#{top + i};1H\e[K#{fit_columns(shown(text), cols)}" }.join
        true
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
      # has smart quotes; a name stays ASCII). A bracketed paste is text in every prompt
      # (PasteFrame): only a ↵ you press submits.
      def prompt_line(label, hint: " (esc cancel)", task: false)
        # bare ↵ ⇒ "": a name prompt cancels on it, the task prompt makes a bare create.
        # The task buffer holds raw bytes (UTF-8 can arrive split across reads).
        buf = task ? String.new : +""
        draw_prompt(label, display_text(buf, task), hint: hint, tail: task)
        typed = take_typeahead
        loop do
          result = if typed.empty?
                     chunk = whole_escape(read_prompt_key) or return nil # read fault / dead pane: cancel
                     edit_buffer(chunk, buf, fold_newlines: task)
                   else
                     edit_items(typed, buf, fold_newlines: task, whole: true) # already framed and tokenized
                   end
          typed = []
          case result
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
        print "\e[?25l"
      end

      # Keys already read past the one that opened the prompt fill it, but can't act on it:
      # only a ↵ read after the prompt is up may submit, so you always see what would run.
      # So the batch stops at its first newline key (a pasted one is inside a Text), and the
      # rest is dropped. A partial sequence still pending is the next read's to finish, unless
      # the cut dropped the keys it followed.
      def take_typeahead
        items = @typeahead.to_a.dup
        @typeahead&.clear
        kept = items.take_while { |item| !["\r", "\n"].include?(item) }
        @pending = +"" if kept.size < items.size
        kept
      end

      def display_text(buf, task)
        task ? buf.dup.force_encoding(Encoding::UTF_8).scrub("") : buf
      end

      # Discard input already waiting (never blocks). The frame still sees it, so a paste cut
      # off here doesn't leave its end marker to be read as keys later.
      def drain_input
        @pending = +"" # what would have finished it was just discarded
        loop do
          chunk = $stdin.read_nonblock(Input::READ_BYTES)
          @paste_frame.feed(chunk, full: chunk.bytesize >= Input::READ_BYTES)
        end
      rescue IO::WaitReadable, EOFError, StandardError
        nil
      end

      # Fold one raw read into the prompt buffer, returning :submit / :cancel / :edit. A
      # read arrives as a burst (a fast key-repeat, an unbracketed paste), so it's split by
      # the terminal grammar the way `handle` splits it, NOT all-or-nothing: a typed URL lands
      # its printable bytes while an arrow (`\e[A`, Ctrl-← `\e[1;5D`) drops whole rather than
      # leaking `[A` into the name. A sequence split across reads is carried in @pending.
      def edit_buffer(chunk, buf, fold_newlines: false)
        full = chunk.bytesize >= Input::READ_BYTES
        edit_items(@paste_frame.feed(chunk, full: full), buf, fold_newlines: fold_newlines, full: full)
      end

      # Framed items: a Text is pasted text, a key string is keys. `whole` items are single
      # tokens already (typeahead), so they're never re-split or joined to @pending.
      def edit_items(items, buf, fold_newlines: false, full: false, whole: false)
        items.each_with_index do |item, i|
          result = if item.is_a?(PasteFrame::Text)
                     @pending = +"" unless whole # a paste start cut it off (typeahead's was cut when it was framed)
                     paste_notice(item, nil)
                     add_pasted(buf, item.bytes, keep_high: fold_newlines)
                     :edit
                   elsif whole
                     edit_tokens([item], buf, fold_newlines, false)
                   else
                     edit_keys(item, buf, fold_newlines: fold_newlines, full: full && i == items.size - 1)
                   end
          return result unless result == :edit
        end
        :edit
      ensure
        drop_c1(buf) if fold_newlines
      end

      # Outside a paste (a terminal without bracketed paste) the task prompt folds newlines
      # too, except a ↵ that is the key string's ONLY newline and its last byte (a lone ↵,
      # or a fast last key + ↵ batched into one read). Judged on the string as the frame
      # hands it over, so a ↵ typed right after a paste's end marker submits.
      def edit_keys(chunk, buf, fold_newlines: false, full: false)
        typed_enter = chunk.match?(/\A[^\r\n]*(\r\n?|\n)\z/)
        tokens, @pending = Input.tokenize(@pending.to_s + chunk, full: full)
        edit_tokens(tokens, buf, fold_newlines, typed_enter)
      end

      def edit_tokens(tokens, buf, fold_newlines, typed_enter)
        tokens.each do |token|
          if fold_newlines && !typed_enter && ["\r", "\n"].include?(token)
            fold_space(buf)
            next
          end
          case token
          when "\e", "\x03" then return :cancel  # bare Esc / Ctrl-C
          when "\r", "\n"   then return :submit  # ↵ (a name prompt drops the rest of the read, like gets)
          when "\x7F", "\b" then backspace(buf, fold_newlines)
          when "\x15"       then buf.clear       # Ctrl-U: clear the line
          else buf << token if printable?(token) || (fold_newlines && token.bytesize == 1 && token.getbyte(0) >= 0x80)
          end
        end
        :edit
      end

      # Pasted text: printable bytes land, newlines/tabs fold to a space, other control bytes
      # (a stray escape) drop. Non-ASCII lands only where `keep_high` (names stay ASCII).
      def add_pasted(buf, text, keep_high: false)
        text.each_byte do |b|
          if b.between?(0x20, 0x7E) || (keep_high && b >= 0x80) then buf << b.chr
          elsif [0x0A, 0x0D, 0x09].include?(b) then fold_space(buf)
          end
        end
      end

      # C1 controls (U+0080-U+009F, `C2 80`-`C2 9F` in UTF-8) act on the terminal when the
      # line is drawn. Run on the whole buffer, so a pair split across reads still goes, and
      # as a stack, so removing one pair can't splice its neighbours into another (one linear
      # pass, where stripping a pair at a time is quadratic on a nested run).
      def drop_c1(buf)
        return unless buf.force_encoding(Encoding::BINARY).match?(C1_PAIR)

        kept = []
        buf.each_byte { |b| b.between?(0x80, 0x9F) && kept.last == 0xC2 ? kept.pop : kept << b }
        buf.replace(kept.pack("C*"))
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
      #
      # While a paste is open (or a marker start held) the wait is capped at QUIET, so a lost
      # end marker heals on silence and Esc and ↵ work again.
      def read_prompt_key
        loop do
          if @paste_frame.idle?
            IO.select([$stdin]) # block until there's something to read
          elsif !IO.select([$stdin], nil, nil, PasteFrame::QUIET)
            @paste_frame.expire
            next
          end
          return $stdin.read_nonblock(Input::READ_BYTES)
        rescue IO::WaitReadable
          next
        rescue EOFError
          return nil
        end
      end

      # A read that stops inside an escape (Input.escape_tail?) gets the rest, which tmux has
      # already queued, so a split click can't type its tail and a split \e isn't an Esc. A
      # lone \e with nothing after it is the Esc key.
      def whole_escape(chunk)
        while chunk && Input.escape_tail?(chunk) && (more = read_prompt_key(timeout: Input::ESCAPE_WAIT))
          chunk = chunk.b + more.b
        end
        chunk
      end

      # A read that stops inside an escape (Input.escape_tail?) gets the rest, which tmux has
      # already queued, so a split click can't type its tail and a split \e isn't an Esc. A
      # lone \e with nothing after it is the Esc key.
      def whole_escape(chunk)
        while chunk && Input.escape_tail?(chunk) && (more = escape_rest)
          chunk = chunk.b + more.b
        end
        chunk
      end

      # Repaint the inline prompt on the bottom row and park a real cursor right after
      # the typed text. An empty buffer shows a dim hint advertising the escape hatch
      # (issue #68); it clears the moment you type so a long name isn't crowded on the
      # narrow pane. The caret column is set explicitly so the hint can trail the input
      # without the caret jumping past it.
      def draw_prompt(label, buf, hint: " (esc cancel)", tail: false)
        rows, cols = winsize
        prefix = "#{shown(label)} › "
        # The hint must live INSIDE the width budget. Truncating only prefix+buf and
        # tacking the hint on after let a long label + the hint overflow the 40-col pane;
        # the 41st char auto-wrapped (DECAWM) on the bottom row and scrolled a stale
        # prompt copy into scrollback every cancel→reopen (issue #80). Reserve the hint's
        # display width so the whole line fits — a long label is clipped while empty (the
        # hint always shows) and restored the moment you type (hint gone). Held plain for
        # the width count; the dim SGR is applied only at print time.
        hint   = buf.empty? ? hint : ""
        view   = tail ? tail_view(prefix, buf, cols - hint.length) : trunc(prefix + buf, cols - hint.length)
        print "\e[#{rows};1H\e[K#{view}#{hint.empty? ? '' : "\e[2m#{hint}\e[0m"}"
        caret = [columns(view) + 1, cols].min # 1-based, parked right after the visible input
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
        print "\e[#{rows};1H\e[K\e[31m#{trunc(shown(message), cols - 11)}\e[0m — any key "
        $stdout.flush
        read_char(leaving_closes: true)
      end

      # The next real key (nil on a dead pane). Tmux's pokes and focus reports share stdin but
      # aren't answers: they run after the prompt closes, only the last of each kind, since a
      # long-open prompt collects many. The sidebar is paused meanwhile, which a message or
      # menu isn't worth, so `leaving_closes` lets a focus-out end the wait.
      #
      # Keys batched before the prompt appeared or behind its answer are dropped: they can't
      # answer something you hadn't seen, and they mustn't fire on the tree once it closes.
      # A paste is no answer: it returns "", which every caller reads as no, and says so.
      def read_char(leaving_closes: false)
        @typeahead&.select! { |key| Input::POKE_BYTES.include?(key) }
        held = []
        after = []
        loop do
          chunk = whole_escape(read_prompt_key) or return nil
          tokens = input_items(chunk).reject { |t| Mouse.report?(t) } # a click can't answer, or dismiss a flash
          at = tokens.index { |t| !Input::POKE_BYTES.include?(t) || (leaving_closes && t == FOCUS_OUT) }
          next held.concat(tokens) unless at

          held.concat(tokens[0...at])
          after = tokens[(at + 1)..]
          if tokens[at].is_a?(PasteFrame::Text)
            paste_notice(tokens[at], ONE_KEY_PASTE_NOTICE)
            return ""
          end
          return tokens[at] unless tokens[at] == FOCUS_OUT

          after.unshift(FOCUS_OUT)
          return nil
        end
      rescue StandardError
        nil
      ensure
        @typeahead&.concat(held.reverse.uniq.reverse, after.select { |key| Input::POKE_BYTES.include?(key) })
      end
    end
    include Prompt
  end
end
