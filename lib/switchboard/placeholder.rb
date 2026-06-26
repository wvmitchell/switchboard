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
  end
end
