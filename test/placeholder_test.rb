# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Placeholder.generate — the throwaway "adjective-noun" name a new workspace gets
  # when you don't supply one (#94). Must be a clean, valid two-token leaf and vary.
  class PlaceholderTest < SandboxTest
    def test_generate_is_an_adjective_noun_leaf
      50.times do
        name = Placeholder.generate
        assert_match(/\A[a-z]+-[a-z]+\z/, name, "lowercase adjective-noun, hyphen-joined")
        # A clean leaf is also a valid branch name (it becomes the branch).
        assert_equal name, Creator.sanitize(name), "survives sanitize unchanged"
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
    end

    def test_generated_rejects_non_placeholders
      refute Placeholder.generated?("fix-auth"), "two tokens, not on the lists"
      refute Placeholder.generated?(Placeholder::ADJECTIVES.first), "single token"
      refute Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-#{Placeholder::NOUNS.first}-x"), "three tokens"
      refute Placeholder.generated?("#{Placeholder::ADJECTIVES.first}-notaword"), "adj on-list, noun off-list"
      refute Placeholder.generated?(""), "empty"
      refute Placeholder.generated?(nil), "nil"
    end
  end
end
