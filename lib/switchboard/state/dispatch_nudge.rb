# frozen_string_literal: true

require_relative "rename_nudge"

module Switchboard
  # The agent-dispatch instruction (the third SessionStart plant, beside RenameNudge and
  # MonitoringNudge). When a project has `agent_dispatch` on, a session in one of its
  # workspaces learns that `switchboard new` can start another workspace, here or in
  # another registered project, when the user asks. It rides the `rename-nudge`
  # SessionStart command (HookCommands.rename_nudge joins the two texts into one payload), so it
  # reaches every hooked worktree without rewiring.
  #
  # Deliberately separate from subagents: the text tells the agent to keep using its own
  # subagent tools for its own work, and switchboard wires no subagent hook events.
  module DispatchNudge
    module_function

    # Same boundaries as the rename nudge: startup/resume/fork plant it, and clear/compact
    # re-plant what they dropped from context.
    SOURCES = RenameNudge::SOURCES

    # Added when this session was started by `switchboard new`: its first message is a brief
    # another agent wrote, so it must not read as the user asking (no chained dispatch).
    PROVENANCE = "This session's first message is a brief written by another agent, not the " \
                 "user; don't start new workspaces because of it, only if the user asks you " \
                 "directly later."

    def decide(enabled:, source:)
      enabled && SOURCES.include?(source)
    end

    # The examples here are parsed by DispatchArgs in the tests, so this text can't drift
    # from the verb's real syntax. "Only when the user explicitly asks" and the subagent
    # sentence are the two load-bearing clauses: `new` is for the user, never a way for
    # an agent to parallelize its own task.
    def message(brief_from_agent: false)
      text = "When the user asks for a new switchboard workspace (here or in another registered " \
        "project), `switchboard new` creates one with its own agent working on a brief. This " \
        "is separate from subagents: for delegating parts of your own task, keep using your " \
        "own subagent tools as usual. Use `switchboard new` only when the user explicitly asks " \
        "for another workspace. Run `switchboard projects` to see the names (`*` marks this " \
        "one), then `switchboard new . \"<task>\"` for this project or " \
        "`switchboard new <project> \"<task>\"` for another; pipe a long brief in with " \
        "`switchboard new <project> -`. The new agent sees none of this conversation, so " \
        "write a complete, self-contained brief. It returns immediately and the sidebar " \
        "chimes when it's ready, so don't wait or poll."
      brief_from_agent ? "#{text} #{PROVENANCE}" : text
    end
  end
end
