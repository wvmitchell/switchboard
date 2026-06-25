# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The shared sidebar pane width (the tree's ←/→ keys, issue #78). Like Collapse's
  # folds and FullHeader's marker, it's a tiny file on disk so every sidebar process
  # sizes the same — we set it in the sandbox and assert on resolved, so the real
  # temp+rename write runs.
  class WidthTest < SandboxTest
    def test_default_with_no_file
      assert_equal Width::DEFAULT, Width.resolved, "no file yet → the historical default width"
    end

    def test_set_then_resolved_round_trips
      Width.set(56)
      assert_equal 56, Width.resolved
    end

    def test_set_clamps_to_bounds
      Width.set(Width::MAX + 100)
      assert_equal Width::MAX, Width.resolved, "an over-max set is clamped before it's stored"
      Width.set(Width::MIN - 100)
      assert_equal Width::MIN, Width.resolved, "an under-min set is clamped before it's stored"
    end

    def test_resolved_clamps_an_out_of_range_file_value
      File.write(Width.state_file, "999")
      assert_equal Width::MAX, Width.resolved, "a file value past the bounds resolves clamped"
    end

    def test_resolved_falls_back_on_garbage
      File.write(Width.state_file, "not-a-number")
      assert_equal Width::DEFAULT, Width.resolved, "garbage → the default, never a raise"
    end

    def test_resolved_falls_back_on_empty_file
      File.write(Width.state_file, "")
      assert_equal Width::DEFAULT, Width.resolved, "a torn/empty read → the default this cycle"
    end

    def test_resolved_reads_base_ten_not_octal
      File.write(Width.state_file, "040") # a hand-edited leading zero
      assert_equal 40, Width.resolved, "a leading zero is decimal 40, not octal 32"
    end

    # The cross-process guarantee: a width set by one "process" is visible to a
    # second read (every sidebar reads the same file).
    def test_a_set_width_is_visible_on_a_later_read
      Width.set(48)
      assert_equal 48, Width.resolved, "a second process sees the same width"
    end

    # Atomic temp+rename, so a peer's concurrent resolved never reads a half-written
    # value — no .tmp straggler is left behind.
    def test_set_leaves_no_tmp_straggler
      Width.set(50)
      strays = Dir.glob("#{Width.state_file}*").select { |f| f.end_with?(".tmp") }
      assert_empty strays, "the atomic write cleans up its temp file"
    end
  end
end
