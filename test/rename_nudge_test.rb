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
  end
end
