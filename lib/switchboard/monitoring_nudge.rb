# frozen_string_literal: true

require "json"

module Switchboard
  # The agent background-presence nudge (the Layer-2 twin of RenameNudge). When a
  # project has `background_presence` on, the agent-state hooks plant a SessionStart
  # instruction telling a running agent to `switchboard monitoring on` if it starts a
  # background monitor / recurring loop — so the operator sees a ∞ in the sidebar
  # instead of the workspace reading as idle/done — and to `off` when it ends.
  #
  # The same SessionStart / SessionEnd hooks also CLEAR the marker, making "monitoring"
  # a per-session declaration: a resumed agent (a fresh process; its old loop is dead)
  # must re-declare, and a session that ends can't still be monitoring. The clear is
  # deliberately scoped to the boundaries where the agent PROCESS is new or gone —
  # startup / resume / any session end — NOT `compact` or `clear`, where the same
  # session continues and a live monitor's marker must survive (a false clear there
  # would just flicker off until the next re-affirm, but there's no reason to cause it).
  #
  # CLI#monitoring_nudge wires the config / cwd / event payload around these pure bits
  # and prints the SessionStart context payload.
  module MonitoringNudge
    module_function

    # Two DIFFERENT gates, because compaction splits them:
    #
    # CLEARS_ON — clear the marker only when the agent PROCESS is genuinely new or resumed
    # (its old loop is dead, so a stale marker must not be inherited). NOT `compact`: that
    # summarizes context IN the same running process, so a live monitor's marker must
    # survive. NOT `clear` (deliberately low-context).
    CLEARS_ON = %w[startup resume].freeze

    # NUDGES_ON — (re)plant the self-report instruction. INCLUDES `compact`: compaction can
    # summarize the original startup nudge out of context, and SessionStart re-fires on
    # `compact` precisely so hooks can re-inject what was dropped — so an agent that sets a
    # monitor AFTER a compaction still knows the `monitoring on` convention. Matches
    # RenameNudge's sources. `clear` stays out (like rename), an unknown source too.
    NUDGES_ON = %w[startup resume compact].freeze

    def clears_on?(source)
      CLEARS_ON.include?(source)
    end

    def nudges_on?(source)
      NUDGES_ON.include?(source)
    end

    # The standing instruction. Terse (it rides every acted-on SessionStart), and the
    # re-affirm clause is load-bearing: the sidebar dot is liveness-gated, so a monitor
    # must re-run `on` each cycle to stay lit — otherwise a stopped agent's dot correctly
    # ages out, which is also how "still monitoring" stays honest.
    def message
      "This switchboard workspace can show background work in the sidebar. If you start a " \
        "background monitor, watch loop, or recurring/scheduled task here, run `switchboard " \
        "monitoring on` — and re-run it at the start of each cycle to keep it marked live " \
        "(the mark goes stale after ~10 min; if your cycle is longer, pass the seconds, e.g. " \
        "`switchboard monitoring on 2400`) — so the operator sees a ∞ instead of the workspace " \
        "looking idle. Run `switchboard monitoring off` when the background work ends."
    end

    # The SessionStart stdout payload Claude merges into context (its `additionalContext`),
    # as a single JSON string — the same shape RenameNudge uses.
    def context_json
      JSON.generate(
        "hookSpecificOutput" => {
          "hookEventName" => "SessionStart",
          "additionalContext" => message
        }
      )
    end
  end
end
