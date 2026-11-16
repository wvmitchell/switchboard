# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  class MarksTest < SandboxTest
    # A StringIO that says it's a terminal.
    def tty_out
      StringIO.new.tap { |io| io.define_singleton_method(:tty?) { true } }
    end

    def with_stdout(io)
      old = $stdout
      $stdout = io
      yield
    ensure
      $stdout = old
    end

    # Value: protects=a pipe, log or `!` capture of doctor/install/upgrade shows plain marks,
    # not `[32m✓[0m`; fails_when=a mark is colored regardless of the terminal; seam=$stdout
    def test_marks_are_plain_off_a_terminal
      with_stdout(StringIO.new) do
        assert_equal %w[✓ – ✗ !], [Marks.ok, Marks.note, Marks.bad, Marks.alert]
      end
    end

    def test_marks_are_colored_on_a_terminal
      with_stdout(tty_out) do
        assert_equal "\e[32m✓\e[0m", Marks.ok
        assert_equal "\e[31m✗\e[0m", Marks.bad
      end
    end

    def test_no_color_turns_color_off_on_a_terminal
      ENV["NO_COLOR"] = "1"
      with_stdout(tty_out) { assert_equal "✓", Marks.ok }
    end
  end
end
