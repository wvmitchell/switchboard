# frozen_string_literal: true

module Switchboard
  class Sidebar
    # Bracketed paste for every reader of the sidebar's stdin
    # (docs/reference-sidebar.md#pasting). `setup` turns the mode on, so the terminal wraps a
    # paste in START … FINISH, and `feed` splits each read into key strings and `Text` items:
    # what a paste holds is never keys. A marker can straddle reads, so a read ending in part
    # of one holds that part for the next. Only real silence ends a paste whose end marker
    # was lost (`expire`), so a busy sidebar can't read the rest of a slow paste as keys.
    class PasteFrame
      START = "\e[200~".b.freeze
      FINISH = "\e[201~".b.freeze
      QUIET = 5 # seconds with no byte before a paste (or a held marker start) is given up
      STALL = 2 # a paste still open this long after it began is a stall, not one write

      # `paste` numbers each paste, so a notice can fire once per paste; `stalled` marks a
      # read that landed STALL or more after its paste began.
      Text = Data.define(:bytes, :paste, :stalled)

      def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      attr_reader :pastes

      def initialize
        @open = false
        @held = "".b
        @pastes = 0
        @began = nil
        @last = nil
      end

      def idle? = !@open && @held.empty?
      def open? = @open

      # The read as an ordered list of key strings and Texts. `full` says the read filled the
      # buffer, so a trailing lone `\e` outside a paste may be a split sequence, not Esc.
      def feed(bytes, full: false, now: PasteFrame.clock)
        rest = @held + bytes.b
        @held = "".b
        @last = now unless bytes.empty?
        items = []
        items << text_item(now) if @open
        until rest.empty?
          if @open
            text, sep, rest = rest.partition(FINISH)
            text, @held = hold(text, FINISH, 1) if sep.empty?
            items.last.bytes << text
            @open = false unless sep.empty?
          else
            keys, sep, rest = rest.partition(START)
            keys, @held = hold(keys, START, full ? 1 : 2) if sep.empty?
            items << keys unless keys.empty?
            next if sep.empty?

            @open = true
            @pastes += 1
            @began = now
            items << text_item(now)
          end
        end
        items
      end

      # Time-based, not "a timeout fired": a wake from the reload pipe mustn't end a paste early.
      def expire(now: PasteFrame.clock)
        return false if idle? || (@last && now - @last < QUIET)

        @open = false
        @held = "".b # a held lone `\e` is dropped, not replayed as Esc
        true
      end

      private

      def text_item(now)
        Text.new(bytes: "".b, paste: @pastes, stalled: now - @began >= STALL)
      end

      # [text, held]: the longest proper prefix of `marker`, at least `min` bytes, that
      # `text` ends with waits for the next read.
      def hold(text, marker, min)
        (marker.bytesize - 1).downto(min) do |k|
          return [text.byteslice(0, text.bytesize - k), marker.byteslice(0, k)] if text.end_with?(marker.byteslice(0, k))
        end
        [text, "".b]
      end
    end
  end
end
