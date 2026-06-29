# frozen_string_literal: true

require_relative "hook_file"

module Switchboard
  # The Claude adapter. Teaches Claude Code to report agent state to the sidebar
  # WITHOUT touching the user's global ~/.claude config: hooks are scoped per
  # worktree via `<worktree>/.claude/settings.local.json` (Claude merges it on top
  # of user settings). All the merge/strip/reporter machinery lives in `HookFile`;
  # this module declares only Claude's delivery file and its event→state map
  # (mirror of `CodexHook`).
  module ClaudeHook
    module_function

    SETTINGS_REL = ".claude/settings.local.json"

    # Each Claude hook event mapped to the state it records (+ a tool matcher
    # where the event is tool-scoped). PreToolUse, PostToolUse, and
    # PostToolUseFailure all assert "thinking": PreToolUse fires BEFORE a tool runs
    # — and the permission prompt comes after it, so it can't clear magenta once
    # you answer. PostToolUse (tool succeeded) / PostToolUseFailure (tool errored)
    # fire AFTER the granted tool runs — the earliest hook past the prompt — so the
    # dot flips from magenta back to blue once work resumes, whichever way the tool
    # went (no hook fires at the moment you answer a permission prompt).
    # Notification uses the special "notify" mode: it reads the payload's
    # notification_type to tell a real "answer me" prompt — a permission request or
    # elicitation dialog (-> waiting/magenta) — from the idle timer and everything
    # else (-> done/green), which is NOT blocked.
    #
    # Stop is deliberately ABSENT here. Stop hooks run in PARALLEL with no ordering, so a
    # plain sh `done` reporter racing the #92 blocking nudge could record a blocked
    # (still-working) agent as `done` and ring a false completion. Instead Stop is wired
    # by HookFile.enable as ONE command that reports the state itself (`done`, or
    # `thinking` when it blocks) — no sibling to race.
    EVENTS = [
      ["UserPromptSubmit",   "thinking", nil],
      ["PreToolUse",         "thinking", "*"],
      ["PostToolUse",        "thinking", "*"],
      ["PostToolUseFailure", "thinking", "*"],
      ["Notification",       "notify",   nil],
      ["SessionStart",       "done",     nil]
    ].freeze

    def label = "claude"
    def settings_path(worktree) = HookFile.settings_path(worktree, SETTINGS_REL)
    def enable(worktree) = HookFile.enable(worktree, SETTINGS_REL, EVENTS)
    def disable(worktree) = HookFile.disable(worktree, SETTINGS_REL)
    def enabled?(worktree) = HookFile.enabled?(worktree, SETTINGS_REL)
  end
end
