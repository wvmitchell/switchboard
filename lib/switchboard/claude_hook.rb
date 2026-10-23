# frozen_string_literal: true

require_relative "hook_file"

module Switchboard
  # The Claude adapter — the per-worktree one. Teaches Claude Code to report agent state
  # to the sidebar WITHOUT touching the user's global ~/.claude config: hooks are scoped
  # per worktree via `<worktree>/.claude/settings.local.json` (Claude merges it on top of
  # user settings). All the merge/strip/reporter machinery lives in `HookFile`; this module
  # declares only Claude's delivery file (`SETTINGS_REL`) and its event→state map. (Codex
  # diverges — it delivers a single global `~/.codex/config.toml` block; see `CodexHook`.)
  module ClaudeHook
    module_function

    SETTINGS_REL = ".claude/settings.local.json"

    # Each Claude hook event mapped to the state it records (+ a tool matcher
    # where the event is tool-scoped). PreToolUse, PostToolUse, and
    # PostToolUseFailure all assert "thinking": PreToolUse fires BEFORE a tool runs
    # — and the permission prompt comes after it, so it can't clear magenta once
    # you answer. PostToolUse (tool succeeded) / PostToolUseFailure (tool errored)
    # fire AFTER the granted tool FINISHES — the earliest hook past the prompt — so the
    # dot flips from magenta back to blue only then, whichever way the tool went (no hook
    # fires at the moment you answer a permission prompt).
    # PermissionRequest fires the moment Claude asks, so it turns the dot magenta (and
    # rings `waiting`) without Notification's ~6s permission_prompt delay. The reporter
    # prints nothing, and a hook with no output leaves the decision to the user, so it
    # observes the prompt without answering it. The accepted cost: after an instant
    # approval of a long tool (a build), the dot stays magenta until that tool finishes.
    # Auto mode never fires it for calls it approves itself (verified live, 2.1.303). A prompt
    # rejected with Esc interrupts the turn (no PostToolUse/Stop), so the dot also stays
    # magenta until the next prompt or the idle_prompt Notification (→ done). And if the user's
    # OWN PermissionRequest hook auto-approves, no dialog shows but the dot still reads waiting
    # (with its chime/bold) until the tool finishes — the hooks run in parallel, so ours can't
    # know the other one answered. The state file is last-writer-wins: a sibling tool call's
    # PreToolUse/PostToolUse landing while the dialog is open turns the dot blue until the ~6s
    # permission_prompt Notification turns it magenta again (a second waiting chime).
    # Notification uses the special "notify" mode: it reads the payload's
    # notification_type to tell a real "answer me" prompt — a permission request,
    # elicitation dialog, or background agent needing input (-> waiting/magenta) —
    # from the idle timer and everything else (-> done/green), which is NOT blocked.
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
      ["PermissionRequest",  "waiting",  "*"],
      ["Notification",       "notify",   nil],
      # gstack-shortcut(dec-549dc4af): matcher-less, so a SessionStart(compact) mid-turn (if auto-compaction
      # fires one) reads done until the next tool call; upgrade when a live /compact mid-turn shows it.
      ["SessionStart",       "done",     nil]
    ].freeze

    def label = "claude"
    def settings_path(worktree) = HookFile.settings_path(worktree, SETTINGS_REL)
    def enable(worktree) = HookFile.enable(worktree, SETTINGS_REL, EVENTS)
    def disable(worktree) = HookFile.disable(worktree, SETTINGS_REL)
    def enabled?(worktree) = HookFile.enabled?(worktree, SETTINGS_REL)
    def current?(worktree) = HookFile.current?(worktree, SETTINGS_REL, EVENTS)
    def refresh(worktree) = HookFile.refresh(worktree, SETTINGS_REL, EVENTS)
    def corrupt?(worktree) = HookFile.corrupt?(worktree, SETTINGS_REL)
    def unparseable?(worktree) = HookFile.unparseable?(worktree, SETTINGS_REL)
    def corrupt_reason(worktree) = HookFile.corrupt_reason(worktree, SETTINGS_REL)
    def unreadable?(worktree) = HookFile.unreadable?(worktree, SETTINGS_REL)
  end
end
