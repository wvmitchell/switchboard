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
  end
end
