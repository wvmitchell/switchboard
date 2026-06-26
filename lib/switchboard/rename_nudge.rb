# frozen_string_literal: true

require "json"

module Switchboard
  # The agent self-naming nudge (#92). When a workspace still carries a generated
  # placeholder name (Placeholder.generated?) and the project has `auto_rename` on,
  # switchboard nudges the running agent to `switchboard rename <name>` — naming the dir
  # AND its branch (#94). The agent has the live conversation context, so it names from
  # what the work actually is, not a stale artifact.
  #
  # TWO triggers, because a single SessionStart plant is structurally easy to defer past
  # (it fires before the agent knows anything, then never again — the moment of maximum
  # understanding has no reminder):
  #   1. SessionStart (decide/context_json) — the soft plant: an `additionalContext`
  #      instruction, deferred ("once you understand…") so it can't name off a vague
  #      opening message.
  #   2. Stop (decide_stop/stop_json) — the backstop: when the agent tries to END a turn
  #      still on a placeholder (the point of max context, about to walk away), block the
  #      stop once and feed back an imperative reminder. This is what makes "you can't
  #      miss it" true. Both self-clear the instant the workspace is renamed (placeholder
  #      ⇒ false).
  #
  # The decisions are pure functions over a seam; CLI#rename_nudge wires the config / cwd
  # / event payload around them and prints the payload.
  module RenameNudge
    module_function

    # SessionStart sources worth nudging on. `clear` (deliberately low-context) and any
    # unknown/missing source are excluded — which also rejects a malformed/empty stdin
    # payload (source ⇒ nil). `startup` is in: the instruction self-gates ("once you
    # understand…"), so planting it early is harmless and covers a session that never
    # resumes.
    SOURCES = %w[startup resume compact].freeze

    # Pure gate: nudge only when auto_rename is on, the workspace is still a
    # placeholder, and the session boundary is one we act on.
    def decide(auto_rename:, placeholder:, source:)
      auto_rename && placeholder && SOURCES.include?(source)
    end

    # Stop-hook gate (the backstop). Same auto_rename + placeholder gate, but keyed on
    # `stop_hook_active` — Claude's own loop guard, true when this Stop already resumed
    # from our block. We require it EXPLICITLY false (fail-closed): block the real first
    # stop, but a missing/garbled flag (malformed stdin, or a runner that doesn't send
    # it) reads as "don't block" — the safe direction, since blocking on an absent flag
    # would never see a `true` to release it and could trap the agent unable to stop. So
    # we block at most ONCE per stop-chain (nudge, don't nag): the agent renames
    # (placeholder ⇒ false, never fires again) or, if it genuinely can't yet, stops
    # cleanly on the second pass (stop_hook_active ⇒ true).
    def decide_stop(auto_rename:, placeholder:, stop_hook_active:)
      auto_rename && placeholder && stop_hook_active == false
    end

    # The standing instruction. "Once you understand what this work is" stops a
    # premature name off the opening message; "don't end the session on a placeholder
    # name" sets the deadline the Stop backstop then enforces; the collision aside
    # covers the :branch_exists path. No `cd` reminder — `switchboard rename` already
    # prints that hint on success.
    def message(leaf)
      "#{leaf} is a placeholder name. Once you understand what this work is, run " \
        "`switchboard rename <name>` to name the workspace and its branch (pick " \
        "another if that name's taken). Don't end the session on a placeholder name " \
        "— if you don't know the right name yet, rename the moment you do."
    end

    # The Stop-hook block reason. Imperative, because it fires exactly when the agent is
    # walking away: Claude keeps the turn alive and feeds this back to the model. The
    # "say why" escape keeps a genuinely-can't-name-yet turn from being stuck (the loop
    # guard lets that second stop through regardless).
    def stop_message(leaf)
      "This workspace and its branch are still on the placeholder name `#{leaf}`. " \
        "Before you finish, name them: run `switchboard rename <name>` (pick another " \
        "if that name's taken). If you truly can't name it yet, say why — otherwise " \
        "rename now."
    end

    # The SessionStart stdout payload Claude reads (its `additionalContext` is merged
    # into the model's context), as a single JSON string.
    def context_json(leaf)
      JSON.generate(
        "hookSpecificOutput" => {
          "hookEventName" => "SessionStart",
          "additionalContext" => message(leaf)
        }
      )
    end

    # The Stop stdout payload: `decision: block` keeps the turn alive and feeds `reason`
    # to the model. Same stdout-only / exit-0 contract as context_json.
    def stop_json(leaf)
      JSON.generate("decision" => "block", "reason" => stop_message(leaf))
    end
  end
end
