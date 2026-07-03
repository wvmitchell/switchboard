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

    # The standing instruction. Terse (it rides every acted-on SessionStart) and scoped to the
    # ACTION, not the mechanism: it names neither the glyph nor the staleness internals — the
    # agent DECLARES monitoring, it doesn't render the dot (that's the sidebar's job). Two
    # load-bearing parts:
    #   (1) `on <seconds>` re-affirmed at the top of each cycle — liveness is re-affirmation-
    #       gated (see Monitoring), so a live loop keeps its presence up by re-declaring with a
    #       ttl sized to its OWN cadence (#146 made the ttl agent-declared); a stopped agent
    #       stops re-declaring and ages out. Sizing the ttl per-cycle replaces the old "~10 min
    #       default, pass seconds only if longer" framing — always pass one, always sized.
    #   (2) the SILENT framing — the presence is operator-facing UI plumbing, so the agent flips
    #       it on/off with the work's lifecycle without narrating it or waiting to be told to
    #       stop. An earlier wording left this implicit and agents dutifully announced "I'm
    #       turning the monitor on" and asked the user when to turn it off — noise the user
    #       never needed.
    def message
      "This switchboard workspace can show background work in the sidebar. If you start a " \
        "background monitor, watch loop, or recurring/scheduled task here, silently run " \
        "`switchboard monitoring on <seconds>` at the top of each cycle — set <seconds> a bit " \
        "longer than that cycle so the workspace keeps reading as actively monitoring between " \
        "ticks — and `switchboard monitoring off` the moment that work ends. It's UI plumbing " \
        "you manage as part of the work's lifecycle: don't announce it, explain it, or wait for " \
        "the user to ask you to turn it off."
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
