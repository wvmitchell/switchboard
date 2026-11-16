# frozen_string_literal: true

module Switchboard
  # The ✓ / – / ✗ / ! marks that lead doctor, install and upgrade lines. Colored only when
  # stdout is a terminal (and NO_COLOR is unset): a pipe, a log or a `!` capture gets the
  # plain glyph instead of `[32m✓[0m`. Read per call, so a test's captured stdout is plain.
  module Marks
    module_function

    def ok    = paint("✓", 32)
    def note  = paint("–", 33)
    def bad   = paint("✗", 31)
    def alert = paint("!", 33)

    def paint(glyph, color)
      color? ? "\e[#{color}m#{glyph}\e[0m" : glyph
    end

    def color?
      $stdout.tty? && ENV["NO_COLOR"].to_s.empty?
    rescue StandardError
      false
    end
  end
end
