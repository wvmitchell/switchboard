# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The shared "full header on every session" toggle (the `H` key). Like Collapse's
  # folds and Attention's markers, it's a tiny file on disk so every sidebar process
  # reads the same flag — we flip it in the sandbox and assert on enabled?, so the
  # real create/delete runs.
  class FullHeaderTest < SandboxTest
    def test_off_by_default
      refute FullHeader.enabled?, "no marker yet → the full header stays home-only"
    end

    def test_enable_then_enabled
      FullHeader.enable
      assert FullHeader.enabled?
    end

    def test_disable_turns_it_off
      FullHeader.enable
      FullHeader.disable
      refute FullHeader.enabled?
    end

    def test_enable_is_idempotent
      FullHeader.enable
      FullHeader.enable
      assert FullHeader.enabled?, "re-enabling an already-on flag stays on"
    end

    def test_disable_is_idempotent_when_already_off
      assert_nil FullHeader.disable, "turning off a missing flag is a quiet no-op"
      refute FullHeader.enabled?
    end

    # The cross-process guarantee: a flag set by one "process" is visible to a
    # second read (every sidebar reads the same file).
    def test_a_set_flag_is_visible_on_a_later_read
      FullHeader.enable
      assert FullHeader.enabled?, "a second process sees the same marker"
    end

    def test_enabled_is_false_with_no_state_dir
      refute FullHeader.enabled?, "no dir yet → off, no raise"
    end
  end
end
