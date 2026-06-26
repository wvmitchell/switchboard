# frozen_string_literal: true

module Switchboard
  # A throwaway "adjective-noun" name for a brand-new workspace, so you don't have
  # to invent a name before you know what the work is — you rename it (and its
  # branch) once you do (see Rename). Zero deps: two small word lists, NOT the
  # `faker` gem. Words are short, lowercase, and hyphen-free so the result is a
  # clean two-token leaf (and a valid branch name).
  module Placeholder
    module_function

    ADJECTIVES = %w[
      amber azure bold brave bright calm clever cozy crisp dapper
      eager fancy gentle jolly keen lively lucky mellow merry nimble
      placid plucky quiet rustic shady snug spry sunny tidy witty
      wandering quirky breezy frosty golden hidden humble silent
    ].freeze

    NOUNS = %w[
      acorn badger birch cedar cricket dawn ember falcon fern finch
      fjord glade grove harbor heron lark lichen maple meadow moss
      otter pine quill raven ridge river sparrow spruce thicket
      willow wren brook canyon hollow lantern pebble thistle
    ].freeze

    # A fresh "<adjective>-<noun>" leaf. Callers retry on a name collision (the
    # space is large but not infinite), so generation itself never dedupes.
    def generate
      "#{ADJECTIVES.sample}-#{NOUNS.sample}"
    end

    # Whether `leaf` looks like a name WE generated — exactly "<adjective>-<noun>"
    # with both halves on our lists. The inverse of `generate`. This is #92's "still
    # unnamed" signal (a placeholder workspace the agent should rename), so it needs
    # no on-disk marker: a real rename changes the leaf and this goes false. A user
    # who happens to type an on-list adjective-noun reads as a placeholder — rare, and
    # harmless (auto_rename is opt-in and the nudge self-gates).
    def generated?(leaf)
      adj, noun, extra = leaf.to_s.split("-", 3)
      extra.nil? && ADJECTIVES.include?(adj) && NOUNS.include?(noun)
    end
  end
end
