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
      assert_includes ctx["additionalContext"], "each cycle",
                      "re-affirmation each cycle is the liveness signal (Monitoring) — the nudge must teach it"
      assert_includes ctx["additionalContext"], "silently",
                      "the presence is operator-facing UI plumbing: the agent flips it on/off with the work " \
                      "lifecycle, silently — it must NOT narrate the monitoring command to the user"
      assert_includes ctx["additionalContext"], "switchboard monitoring notify",
                      "routine ticks are silent, so the nudge must teach the notify verb for the cycle that " \
                      "surfaces something worth the operator's eyes"
      refute_includes ctx["additionalContext"], "∞",
                      "the agent declares monitoring but doesn't render the dot — the message must not " \
                      "expose the glyph (that's the sidebar's job, and it's handled)"
    end
  end
end
