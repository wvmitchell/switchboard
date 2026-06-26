# frozen_string_literal: true

require "json"

module Switchboard
  # The agent self-naming nudge (#92). At a Claude Code SessionStart, when a workspace
  # still carries a generated placeholder name (Placeholder.generated?) and the project
  # has `auto_rename` on, switchboard injects a standing instruction telling the running
  # agent to `switchboard rename <name>` once it understands the work — naming the dir
  # AND its branch (#94). The agent has the live conversation context, so it names from
  # what the work actually is, not a stale artifact.
  #
  # The decision is a pure function (decide) over a seam; CLI#rename_nudge wires the
  # config / cwd / SessionStart source around it and prints the payload.
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

    # The standing instruction. "Once you understand what this work is" stops a
    # premature name off the opening message; "rename as soon as you do" keeps the
    # agent on the hook to name it (a deferred commitment, not an opt-out); the
    # collision aside covers the :branch_exists path. No `cd` reminder — `switchboard
    # rename` already prints that hint on success.
    def message(leaf)
      "#{leaf} is a placeholder name. Once you understand what this work is, run " \
        "`switchboard rename <name>` to name the workspace and its branch (pick " \
        "another if that name's taken). If you don't know the right name yet, " \
        "rename as soon as you do."
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
  end
end
