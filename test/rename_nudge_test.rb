# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # RenameNudge.decide — the pure gate for the #92 SessionStart self-naming nudge —
  # plus the message/JSON payload shape.
  class RenameNudgeTest < SandboxTest
    def test_decide_fires_on_active_sources_when_placeholder_and_on
      %w[startup resume compact].each do |src|
        assert RenameNudge.decide(auto_rename: true, placeholder: true, source: src), "source #{src}"
      end
    end

    def test_decide_off_when_auto_rename_off
      refute RenameNudge.decide(auto_rename: false, placeholder: true, source: "resume")
    end

    def test_decide_off_when_not_a_placeholder
      refute RenameNudge.decide(auto_rename: true, placeholder: false, source: "resume")
    end

    def test_decide_off_on_clear_unknown_or_missing_source
      ["clear", "weird", nil, ""].each do |src|
        refute RenameNudge.decide(auto_rename: true, placeholder: true, source: src), "source #{src.inspect}"
      end
    end

    def test_message_names_the_leaf_and_the_rename_verb
      m = RenameNudge.message("wandering-finch")
      assert_includes m, "wandering-finch"
      assert_includes m, "switchboard rename"
    end

    def test_context_json_is_the_sessionstart_additional_context_shape
      out = JSON.parse(RenameNudge.context_json("calm-otter"))["hookSpecificOutput"]
      assert_equal "SessionStart", out["hookEventName"]
      assert_includes out["additionalContext"], "calm-otter"
    end

    # decide_stop — the Stop-hook backstop. Fires on the real first stop (the flag
    # explicitly false) while still a placeholder.
    def test_decide_stop_fires_on_the_first_stop_when_placeholder_and_on
      assert RenameNudge.decide_stop(auto_rename: true, placeholder: true, stop_hook_active: false)
    end

    # Fail-closed: a missing/garbled flag does NOT block — the safe direction, since a
    # block on an absent flag would never see a `true` to release it and could trap the
    # agent unable to stop.
    def test_decide_stop_fails_closed_on_a_missing_flag
      refute RenameNudge.decide_stop(auto_rename: true, placeholder: true, stop_hook_active: nil)
    end

    # The loop guard: once Claude has already resumed from our block, we let the stop
    # through (block once per chain, never nag).
    def test_decide_stop_suppressed_when_already_active
      refute RenameNudge.decide_stop(auto_rename: true, placeholder: true, stop_hook_active: true)
    end

    def test_decide_stop_off_when_auto_rename_off_or_already_named
      refute RenameNudge.decide_stop(auto_rename: false, placeholder: true, stop_hook_active: false)
      refute RenameNudge.decide_stop(auto_rename: true, placeholder: false, stop_hook_active: false)
    end

    def test_stop_json_is_a_block_decision_naming_the_leaf
      out = JSON.parse(RenameNudge.stop_json("calm-otter"))
      assert_equal "block", out["decision"]
      assert_includes out["reason"], "calm-otter"
      assert_includes out["reason"], "switchboard rename"
    end
  end
end
