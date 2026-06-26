# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"

module Switchboard
  # Teaches Claude Code to report agent state to the sidebar, WITHOUT touching
  # the user's global ~/.claude config. Hooks are scoped per worktree via
  # `<worktree>/.claude/settings.local.json` (Claude merges it on top of user
  # settings), and the hook command points at a copy of the reporter script that
  # switchboard materializes into its own data dir — a path that survives
  # reinstalls and `brew upgrade`, unlike the install directory.
  #
  # State flows out as files under the state dir (see AgentState); the sidebar
  # reads those. The script is embedded here so distribution carries no loose
  # files and an upgrade self-heals the next time a worktree is enabled.
  module Hook
    module_function

    MARK = "sb-agent-hook" # identifies the agent-state reporter entries (idempotent merge/removal)
    NUDGE_MARK = "rename-nudge" # identifies the #92 SessionStart self-naming nudge entry

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
    # in `enable` as ONE command that reports the state itself (`done`, or `thinking` when
    # it blocks) — no sibling to race.
    EVENTS = [
      ["UserPromptSubmit",   "thinking", nil],
      ["PreToolUse",         "thinking", "*"],
      ["PostToolUse",        "thinking", "*"],
      ["PostToolUseFailure", "thinking", "*"],
      ["Notification",       "notify",   nil],
      ["SessionStart",       "done",     nil]
    ].freeze

    # POSIX sh, kept tiny: PreToolUse fires before every tool call, so Ruby
    # startup latency here would be felt on every tool. Claude runs hooks in the
    # project dir, so `pwd -P` IS the worktree (physical path, to match tmux).
    SCRIPT = <<~'SH'
      #!/bin/sh
      # sb-agent-hook v3 — switchboard agent-state reporter (managed file; edits
      # are overwritten). Usage: sb-agent-hook <thinking|done|notify>
      #
      # `notify` (the Notification hook) reads the event JSON on stdin and reports
      # "waiting" (magenta — blocked on you) only when notification_type marks a
      # prompt that needs an answer: a permission request or an elicitation
      # dialog. Everything else, the idle timer (idle_prompt) included, is just
      # "done" (green) — not blocked. Keying on the structured notification_type
      # (not message text) holds up across releases, and defaulting to the calm
      # state means an unrecognized notification never false-alarms magenta.
      state="$1"
      [ -n "$state" ] || exit 0

      if [ "$state" = "notify" ]; then
        case "$(cat)" in
          *permission_prompt*|*elicitation_dialog*) state="waiting" ;;
          *)                                        state="done" ;;
        esac
      fi

      dir="${SWITCHBOARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/switchboard/agents}"
      mkdir -p "$dir" 2>/dev/null || exit 0

      cwd=$(pwd -P)
      key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
      printf '%s\t%s\t%s\n' "$state" "$cwd" "$(date +%s)" >"$dir/$key" 2>/dev/null

      exit 0
    SH

    # Stable, install-independent home for the reporter script. XDG data dir, not
    # the switchboard checkout/cellar (which moves on upgrade).
    def script_path
      File.expand_path(File.join(ENV["XDG_DATA_HOME"] || "~/.local/share", "switchboard", MARK))
    end

    # Write the script out if missing or stale, mark it executable. Idempotent;
    # cheap enough to call on every enable / worktree create.
    def ensure_script
      path = script_path
      if !File.exist?(path) || File.read(path) != SCRIPT
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, SCRIPT)
      end
      File.chmod(0o755, path)
      path
    rescue StandardError
      path
    end

    def settings_path(worktree)
      File.join(worktree, ".claude", "settings.local.json")
    end

    # Raised rather than clobbering a settings file we couldn't parse.
    Corrupt = Class.new(StandardError)

    # Add our hooks to a worktree's local settings (merge-safe — leaves any
    # settings already there untouched) and keep the file out of git status.
    def enable(worktree)
      script = ensure_script
      path = settings_path(worktree)
      data = load_settings(path)
      hooks = (data["hooks"] ||= {})

      EVENTS.each do |event, state, matcher|
        entry = { "hooks" => [{ "type" => "command", "command" => "#{script} #{state}" }] }
        entry["matcher"] = matcher if matcher
        hooks[event] = strip_ours(hooks[event]) + [entry]
      end

      # The #92 self-naming nudge. Both forms re-invoke switchboard (so they carry
      # NUDGE_MARK, recognized by ours? for idempotent merge / clean disable). Escape the
      # binary path (it can contain spaces). `command -v`-guard a baked bin path that can
      # go stale (a repo move/reinstall) so it's a clean no-op, never "command not found".
      bin = Shellwords.escape(ENV["SWITCHBOARD_BIN"] || "switchboard")
      escaped_script = Shellwords.escape(script)

      # SessionStart: a soft `additionalContext` plant, ALONGSIDE the sh reporter wired by
      # the EVENTS loop above (they don't conflict — one prints, the other writes state).
      hooks["SessionStart"] << { "hooks" => [{ "type" => "command",
                                               "command" => "command -v #{bin} >/dev/null 2>&1 && #{bin} rename-nudge || true" }] }

      # Stop: ONE command owns the event (the sh reporter is off EVENTS, see there) —
      # `rename-nudge --stop` reports the state itself (`done`, or `thinking` when it
      # blocks) so a forced continuation never reads as a finished turn. If the binary is
      # stale, fall back to the direct sh reporter so `done` is still recorded (the script
      # path doesn't depend on PATH). `if/then/else` not `&& ||` so a non-zero from the
      # Ruby side can't also trigger the fallback (double-write). strip_ours clears any
      # pre-unification sh Stop reporter (migration — the EVENTS loop no longer touches Stop).
      stop_cmd = "if command -v #{bin} >/dev/null 2>&1; then #{bin} rename-nudge --stop; " \
                 "else #{escaped_script} done; fi"
      hooks["Stop"] = strip_ours(hooks["Stop"])
      hooks["Stop"] << { "hooks" => [{ "type" => "command", "command" => stop_cmd }] }

      write_json(path, data)
      ignore_local_settings(worktree)
      path
    rescue Corrupt => e
      warn "switchboard: #{e.message} — leaving it untouched"
      nil
    end

    def disable(worktree)
      path = settings_path(worktree)
      return unless File.exist?(path)

      data = load_settings(path)
      (data["hooks"] || {}).each_key { |event| data["hooks"][event] = strip_ours(data["hooks"][event]) }
      data["hooks"]&.reject! { |_event, groups| groups.empty? }
      data.delete("hooks") if data["hooks"]&.empty?
      data.empty? ? File.delete(path) : write_json(path, data)
    rescue Corrupt => e
      warn "switchboard: #{e.message} — leaving it untouched"
      nil
    end

    def enabled?(worktree)
      data = read_json(settings_path(worktree))
      (data["hooks"] || {}).values.flatten.any? do |group|
        Array(group["hooks"]).any? { |h| ours?(h["command"]) }
      end
    rescue StandardError
      false
    end

    # --- internals -----------------------------------------------------------

    # A hook command switchboard installed — the agent-state reporter OR the #92
    # rename nudge. Both must be recognized so disable/idempotent-merge handle each.
    def ours?(command)
      s = command.to_s
      s.include?(MARK) || s.include?(NUDGE_MARK)
    end

    # Drop our entries from one event's groups, then any group left empty.
    def strip_ours(groups)
      Array(groups).map do |group|
        next group unless group.is_a?(Hash) && group["hooks"].is_a?(Array)

        group.merge("hooks" => group["hooks"].reject { |h| ours?(h["command"]) })
      end.reject { |group| group.is_a?(Hash) && Array(group["hooks"]).empty? }
    end

    # Keep .claude/settings.local.json out of `git status` via the worktree's
    # local excludes (uncommitted), regardless of the repo's own .gitignore.
    def ignore_local_settings(worktree)
      rel = ".claude/settings.local.json"
      return if system("git", "-C", worktree, "check-ignore", "-q", rel, out: File::NULL, err: File::NULL)

      exclude = `git -C #{Shellwords.escape(worktree)} rev-parse --git-path info/exclude 2>/dev/null`.strip
      return if exclude.empty?

      exclude = File.expand_path(exclude, worktree)
      FileUtils.mkdir_p(File.dirname(exclude))
      lines = File.exist?(exclude) ? File.readlines(exclude, chomp: true) : []
      File.open(exclude, "a") { |f| f.puts(rel) } unless lines.include?(rel)
    rescue StandardError
      nil
    end

    # For the WRITE paths (enable/disable): an absent file is {}, but a present
    # file that won't parse must NOT be treated as empty — that would overwrite
    # (or, in disable, delete) settings switchboard doesn't own. Raise instead.
    def load_settings(path)
      return {} unless File.exist?(path)

      body = File.read(path)
      return {} if body.strip.empty?

      JSON.parse(body) || {}
    rescue JSON::ParserError
      raise Corrupt, "#{path} isn't valid JSON"
    end

    # Read-only/best-effort parse for the enabled? probe — corrupt reads as {}
    # (i.e. "not enabled"), which is harmless since nothing is written.
    def read_json(path)
      File.exist?(path) ? (JSON.parse(File.read(path)) || {}) : {}
    rescue StandardError
      {}
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(data)}\n")
    end
  end
end
