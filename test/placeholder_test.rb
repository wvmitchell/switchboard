# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Placeholder.generate — the throwaway "adjective-noun-hex" name a new workspace gets
  # when you don't supply one (#94). Must be a clean, valid leaf and vary.
  class PlaceholderTest < SandboxTest
    # The hex suffix is what keeps a deleted workspace's folder path (and so its agent
    # history) from being handed to a new one.
    def test_generate_is_an_adjective_noun_hex_leaf
      50.times do
        name = Placeholder.generate
        assert_match(/\A[a-z]+-[a-z]+-[0-9a-f]{4}\z/, name, "lowercase adjective-noun-hex, hyphen-joined")
        # A clean leaf is also a valid branch name (it becomes the branch).
        assert_equal name, Placeholder.sanitize(name), "survives sanitize unchanged"
      end
    end

    def test_generate_varies
      names = Array.new(50) { Placeholder.generate }
      assert_operator names.uniq.size, :>, 1, "repeated calls don't return one fixed name"
    end

    # generated? is #92's "still unnamed" signal — true only for our exact adj-noun shape.
    def test_generated_recognizes_a_generated_name
      assert Placeholder.generated?(Placeholder.generate)
      assert Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-#{Placeholder::NOUNS.first}")
      assert Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-#{Placeholder::NOUNS.first}-3f9a")
    end

    def test_generated_rejects_non_placeholders
      refute Placeholder.generated?("fix-auth"), "two tokens, not on the lists"
      refute Placeholder.generated?(Placeholder::ADJECTIVES.first), "single token"
      refute Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-#{Placeholder::NOUNS.first}-x"), "a non-hex third token"
      refute Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-#{Placeholder::NOUNS.first}-abcde"), "a five-digit suffix"
      refute Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-notaword"), "adj on-list, noun off-list"
      refute Placeholder.generated?(""), "empty"
      refute Placeholder.generated?(nil), "nil"
    end

    def test_sanitize_neutralizes_traversal
      assert_equal "etc", Placeholder.sanitize("../../etc")
      assert_equal "tmp/x", Placeholder.sanitize("/tmp/x")
      assert_equal "", Placeholder.sanitize("..")
      assert_equal "my-feature", Placeholder.sanitize("my feature")
    end

    # Names handed out before the lists grew must still read as placeholders, or the
    # rename nudge would stop firing on existing workspaces.
    OLD_ADJECTIVES = %w[amber azure bold brave bright calm clever cozy crisp dapper eager fancy gentle jolly keen
                        lively lucky mellow merry nimble placid plucky quiet rustic shady snug spry sunny tidy witty
                        wandering quirky breezy frosty golden hidden humble silent].freeze
    OLD_NOUNS = %w[acorn badger birch cedar cricket dawn ember falcon fern finch fjord glade grove harbor heron lark
                   lichen maple meadow moss otter pine quill raven ridge river sparrow spruce thicket willow wren
                   brook canyon hollow lantern pebble thistle].freeze

    # Only the original lists ever produced suffixless names, so a two-word name built from
    # a newer word is the user's own and must not draw the rename nudge.
    def test_a_suffixless_name_counts_only_from_the_original_lists
      assert Placeholder.generated?("brave-otter")
      refute Placeholder.generated?("silver-fox"), "newer words, no suffix"
      refute Placeholder.generated?("brave-fox"), "one newer word, no suffix"
      assert Placeholder.generated?("silver-fox-3f9a"), "newer words carry the suffix"
    end

    def test_word_lists_grew_and_keep_every_old_word
      assert_equal OLD_ADJECTIVES, Placeholder::LEGACY_ADJECTIVES, "the legacy lists never change"
      assert_equal OLD_NOUNS, Placeholder::LEGACY_NOUNS
      assert_empty OLD_ADJECTIVES - Placeholder::ADJECTIVES
      assert_empty OLD_NOUNS - Placeholder::NOUNS
      [Placeholder::ADJECTIVES, Placeholder::NOUNS].each do |words|
        assert_operator words.size, :>=, 120
        assert_equal words, words.uniq
        assert(words.all? { |w| w.match?(/\A[a-z]+\z/) }, "lowercase, hyphen-free")
      end
    end
  end
end
