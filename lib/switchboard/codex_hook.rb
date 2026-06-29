# frozen_string_literal: true

require_relative "hook_file"

module Switchboard
  # The Codex adapter. Codex reads project-local hooks from
  # `<worktree>/.codex/hooks.json` once the project layer is trusted, in the SAME
  # JSON shape Claude uses — so the merge/strip/reporter/nudge machinery is shared
  # (HookFile); this module only declares Codex's delivery file and its event→state
  # map. Codex has no Notification event: PermissionRequest is the exact
  # "blocked on user approval" edge, and PostToolUse flips back to thinking after
  # the approved tool runs.
  #
  # NOTE (waiting parity, #110): PermissionRequest is Codex's ONLY user-blocked
  # signal — there is no idle/input-needed event analogous to Claude's
  # Notification (Codex 0.142.2 event surface: SessionStart, UserPromptSubmit,
  # PreToolUse, PostToolUse, PermissionRequest, Stop). So `waiting` is best-effort:
  # it fires whenever a tool escalates to approval, including a genuine hard gate
  # under auto-run — but a Codex session_command that bypasses ALL approvals would
  # suppress it. Recommend an auto mode that preserves gate escalation (docs).
  #
  # NOTE (rename nudge, #92/#110): the Stop backstop (`decision: block`) is the
  # VERIFIED Codex nudge path — its stop_hook_active flip is proven by the smoke.
  # The SessionStart soft plant (`additionalContext`) is best-effort: if a Codex
  # build doesn't honor SessionStart additionalContext it's simply inert, and the
  # Stop backstop still nudges. State reporting flows on every event regardless.
  module CodexHook
    module_function

    SETTINGS_REL = ".codex/hooks.json"

    EVENTS = [
      ["UserPromptSubmit",  "thinking", nil],
      ["PreToolUse",        "thinking", "*"],
      ["PostToolUse",       "thinking", "*"],
      ["PermissionRequest", "waiting",  "*"],
      ["SessionStart",      "done",     nil]
    ].freeze

    def label = "codex"
    def settings_path(worktree) = HookFile.settings_path(worktree, SETTINGS_REL)
    def enable(worktree) = HookFile.enable(worktree, SETTINGS_REL, EVENTS)
    def disable(worktree) = HookFile.disable(worktree, SETTINGS_REL)
    def enabled?(worktree) = HookFile.enabled?(worktree, SETTINGS_REL)
  end
end
