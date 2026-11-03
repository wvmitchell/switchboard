# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # `switchboard new`'s argument rules: every malformed brief is refused before a record
  # exists, because nobody watches the pane it would land in.
  class DispatchArgsTest < Minitest::Test
    def test_parse_target_and_task
      assert_equal [".", "research gov-1234", nil], DispatchArgs.parse([".", "research gov-1234"])
      assert_equal ["govly", "-", nil], DispatchArgs.parse(%w[govly -])
      assert_equal ["govly", nil, nil], DispatchArgs.parse(["govly"]), "no task is a bare create"
    end

    def test_parse_refuses_a_missing_or_flag_target
      assert_equal DispatchArgs::USAGE, DispatchArgs.parse([])[2]
      assert_equal DispatchArgs::USAGE, DispatchArgs.parse(["--help"])[2]
    end

    # An unquoted brief was already rewritten by the shell, so it's never joined (R5).
    def test_parse_refuses_unquoted_words
      err = DispatchArgs.parse(%w[. research gov-1234 and plan it])[2]
      assert_match(/too many arguments: quote the task/, err)
    end

    def test_task_error_refuses_a_dash_led_task_even_after_whitespace
      assert_match(/can't start with '-'/, DispatchArgs.task_error("- research gov-1234"))
      assert_match(/can't start with '-'/, DispatchArgs.task_error("  \n--model x"))
      assert_nil DispatchArgs.task_error("research - then plan")
    end

    def test_task_error_size_boundary
      assert_nil DispatchArgs.task_error("a" * 65_536)
      assert_match(/task is 65 KiB; the limit is 64 KiB/, DispatchArgs.task_error("a" * 65_537))
      assert_match(/limit is 64 KiB/, DispatchArgs.task_error("é" * 32_769), "measured in UTF-8 bytes, not characters")
    end

    # The brief reaches the agent intact or not at all: no silently dropped bytes, no backtrace.
    def test_invalid_utf8_is_refused_never_scrubbed_or_raised
      assert_equal [nil, "the brief on stdin isn't valid UTF-8"], read_from("caf\xE9 brief".b)
      assert_equal "the brief isn't valid UTF-8", DispatchArgs.task_error("\xE9t\xE9".dup.force_encoding(Encoding::UTF_8))
    end

    def test_task_error_refuses_nul
      assert_equal "the brief contains a NUL byte", DispatchArgs.task_error("plan\0it")
    end

    def test_read_stdin_takes_a_multiline_brief_byte_exact
      brief = "Research gov-1234.\n\n- read the ticket\n- \"quote\" it's $HOME ✓\n"
      assert_equal [brief, nil], read_from(brief)
    end

    def test_read_stdin_refuses_a_terminal
      io = IO.pipe.first
      io.define_singleton_method(:tty?) { true }
      assert_match(/pipe the brief in/, DispatchArgs.read_stdin(io)[1])
    end

    # The hang this guards: an agent's Bash stdin can be a pipe nobody ever closes.
    def test_read_stdin_gives_up_on_a_silent_pipe
      r, w = IO.pipe
      assert_equal [nil, "no brief arrived on stdin"], DispatchArgs.read_stdin(r, wait: 0.05)
    ensure
      w&.close
    end

    def test_read_stdin_gives_up_when_the_brief_stalls_mid_way
      r, w = IO.pipe
      w.write("half a brie")
      assert_equal [nil, "the brief stopped arriving"], DispatchArgs.read_stdin(r, wait: 0.05)
    ensure
      w&.close
    end

    def test_read_stdin_stops_as_soon_as_the_cap_is_passed
      r, w = IO.pipe
      writer = Thread.new { w.write("a" * 200) } # more than the limit, and never closed
      assert_equal [nil, DispatchArgs::TOO_BIG], DispatchArgs.read_stdin(r, wait: 1, limit: 100)
    ensure
      writer&.join
      w&.close
    end

    def test_read_stdin_refuses_an_empty_brief
      assert_equal [nil, "the brief on stdin is empty"], read_from(" \n\t\n")
    end

    private

    def read_from(text)
      r, w = IO.pipe
      w.write(text)
      w.close
      DispatchArgs.read_stdin(r, wait: 1)
    end
  end
end
