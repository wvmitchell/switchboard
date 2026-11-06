# frozen_string_literal: true

module Switchboard
  class Sidebar
    # The / search (docs/explanation-sidebar-views.md#vim-style-search): whether one is being
    # typed or is committed, its query, where it started, and the project it leaves unfolded.
    # Per-process and never on disk: a search is something you're doing now, not a view
    # preference. The rows and the cursor stay with the sidebar, which asks this what matches.
    class Search
      attr_reader :query, :origin
      attr_accessor :sticky # the one project a finished search leaves open in this sidebar

      def initialize
        @sticky = nil
        clear
      end

      def typing? = @state == :typing
      def committed? = @state == :committed
      def active? = @state != :idle

      def start(origin)
        clear
        @state = :typing
        @origin = origin
      end

      def commit
        @state = :committed
      end

      def clear
        @state = :idle
        @origin = nil
        self.query = ""
      end

      def append(char)
        self.query = query + char
      end

      def erase
        self.query = query[0..-2]
      end

      def match?(text) = !@pattern.nil? && @pattern.match?(text)

      # Non-overlapping [start, length] character ranges of the query in `text`, which the
      # caller has already scrubbed (`shown`), since a regexp raises on invalid bytes.
      def spans(text)
        return [] unless @pattern

        found = []
        at = 0
        while (hit = @pattern.match(text, at))
          found << [hit.begin(0), hit[0].length]
          at = hit.end(0)
        end
        found
      end

      private

      # Keys arrive as binary bytes, and printable ASCII is all that reaches here.
      def query=(value)
        @query = value.dup.force_encoding(Encoding::UTF_8)
        @pattern = @query.empty? ? nil : Regexp.new(Regexp.escape(@query), Regexp::IGNORECASE)
      end
    end
  end
end
