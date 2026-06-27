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

    # #101: the message must reassure that renaming a live workspace is safe — the
    # bridge re-links the old path — or a careful agent defers the rename to avoid
    # stranding its own shell.
    def test_message_reassures_renaming_in_place_is_safe
      m = RenameNudge.message("wandering-finch")
      assert_includes m, "safe"
      assert_includes m, "strand"
    end

    # The opt-in framing: auto_rename is ON, so the agent must NAME the workspace
    # itself, not ask the user (asking ends the turn on a placeholder and exposes the
    # Stop backstop the user shouldn't normally see).
    def test_message_tells_the_agent_to_pick_the_name_not_ask
      m = RenameNudge.message("wandering-finch")
      assert_includes m, "don't ask the user"
      assert_includes m, "your job"
    end

    # The descriptiveness clause: without explicit length guidance the agent over-compresses
    # (git-branch instinct + mimicry of the two-token placeholder), so the message must steer
    # toward a fuller, hyphenated name.
    def test_message_steers_toward_a_descriptive_name
      m = RenameNudge.message("wandering-finch")
      assert_includes m, "descriptive"
      assert_includes m, "over-compress"
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

    # #101: the Stop backstop reassures too — otherwise the agent talks around the
    # block via the "say why" escape, deferring instead of renaming.
    def test_stop_message_reassures_renaming_in_place_is_safe
      m = RenameNudge.stop_message("calm-otter")
      assert_includes m, "safe"
      assert_includes m, "strand"
    end

    # The backstop steers toward a fuller name too, for the agent that only reaches Stop.
    def test_stop_message_steers_toward_a_descriptive_name
      assert_includes RenameNudge.stop_message("calm-otter"), "descriptive"
    end
  end
end
