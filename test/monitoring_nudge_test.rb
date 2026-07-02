# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # The pure gate + message behind the Layer-2 background-presence nudge. CLI#monitoring_nudge
  # wires config/cwd/payload around these; here we pin the decision and the payload shape.
  class MonitoringNudgeTest < SandboxTest
    # The clear fires only on a genuinely new/resumed PROCESS — never compact (same
    # process continues, a live monitor's marker must survive).
    def test_clears_on_new_or_resumed_process_only
      assert MonitoringNudge.clears_on?("startup"), "fresh process -> clear any stale marker"
      assert MonitoringNudge.clears_on?("resume"),  "resumed process (old loop dead) -> clear"
      refute MonitoringNudge.clears_on?("compact"), "compact continues the session -> DON'T clear a live monitor"
      refute MonitoringNudge.clears_on?("clear"),   "same process continues"
      refute MonitoringNudge.clears_on?(nil),       "unknown source -> don't clear"
    end

    # The nudge re-teaches on compact too — compaction can drop the original instruction,
    # so an agent that sets a monitor after a compaction still learns the convention.
    def test_nudges_on_startup_resume_and_compact
      assert MonitoringNudge.nudges_on?("startup"), "teach on a fresh start"
      assert MonitoringNudge.nudges_on?("resume"),  "re-teach on resume"
      assert MonitoringNudge.nudges_on?("compact"), "re-teach after compaction (the key case)"
      refute MonitoringNudge.nudges_on?("clear"),   "deliberately low-context -> no nudge (like rename)"
      refute MonitoringNudge.nudges_on?(nil),       "unknown source -> no nudge"
    end

    def test_context_json_is_a_sessionstart_additionalcontext_payload
      ctx = JSON.parse(MonitoringNudge.context_json)["hookSpecificOutput"]
      assert_equal "SessionStart", ctx["hookEventName"]
      assert_includes ctx["additionalContext"], "switchboard monitoring on"
      assert_includes ctx["additionalContext"], "∞", "the message names the dot the operator will see"
    end
  end
end
