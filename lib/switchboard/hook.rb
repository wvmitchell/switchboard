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

    MARK = "sb-agent-hook" # identifies our entries for idempotent merge/removal

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
    EVENTS = [
      ["UserPromptSubmit",   "thinking", nil],
      ["PreToolUse",         "thinking", "*"],
      ["PostToolUse",        "thinking", "*"],
      ["PostToolUseFailure", "thinking", "*"],
      ["Notification",       "notify",   nil],
      ["Stop",               "done",     nil],
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
        Array(group["hooks"]).any? { |h| h["command"].to_s.include?(MARK) }
      end
    rescue StandardError
      false
    end

    # --- internals -----------------------------------------------------------

    # Drop our entries from one event's groups, then any group left empty.
    def strip_ours(groups)
      Array(groups).map do |group|
        next group unless group.is_a?(Hash) && group["hooks"].is_a?(Array)

        group.merge("hooks" => group["hooks"].reject { |h| h["command"].to_s.include?(MARK) })
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
