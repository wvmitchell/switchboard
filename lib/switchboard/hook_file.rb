# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"

module Switchboard
  # The shared engine behind every per-agent hook adapter (`ClaudeHook` for Claude,
  # `CodexHook` for Codex). Claude and Codex happen to read the SAME hook-config
  # shape — `{"hooks": {<Event>: [{"matcher"?, "hooks": [{"type":"command","command"}]}]}}`
  # — into different files (`.claude/settings.local.json` vs `.codex/hooks.json`),
  # so the merge-safe enable/disable/strip, the materialized sh reporter, and the
  # #92 rename-nudge/Stop wiring all live here ONCE. An adapter supplies only its
  # delivery file (a worktree-relative path) and its event→state map; everything
  # else is identical. (Same delegation shape as `KeyedMarkerStore`: callers pass
  # their domain, the base owns the machinery.)
  #
  # State flows out as files under the state dir (see AgentState); the sidebar
  # reads those. The reporter script is embedded here so distribution carries no
  # loose files and an upgrade self-heals the next time a worktree is enabled.
  module HookFile
    module_function

    MARK = "sb-agent-hook" # identifies the agent-state reporter entries (idempotent merge/removal)
    NUDGE_MARK = "rename-nudge" # identifies the #92 SessionStart self-naming nudge entry

    # Raised rather than clobbering a settings file we couldn't parse.
    Corrupt = Class.new(StandardError)

    # POSIX sh, kept tiny: PreToolUse fires before every tool call, so Ruby
    # startup latency here would be felt on every tool. The agent runs hooks in
    # the session cwd, so `pwd -P` IS the worktree (physical path, to match tmux)
    # — switchboard always launches an agent from the worktree root. (Caveat: a
    # Codex started by hand from a *subdir* keys state to that subdir, so the dot
    # won't match the worktree root; not a path switchboard drives.)
    # Agent-neutral: it writes whatever literal <state> it's handed (Claude's
    # `notify` mode is the one branch; Codex hands it `waiting`/`thinking`/`done`
    # directly), so both adapters share it unchanged.
    SCRIPT = <<~'SH'
      #!/bin/sh
      # sb-agent-hook v3 — switchboard agent-state reporter (managed file; edits
      # are overwritten). Usage: sb-agent-hook <thinking|done|waiting|notify>
      #
      # `notify` (Claude's Notification hook) reads the event JSON on stdin and
      # reports "waiting" (magenta — blocked on you) only when notification_type
      # marks a prompt that needs an answer: a permission request or an
      # elicitation dialog. Everything else, the idle timer (idle_prompt) included,
      # is just "done" (green) — not blocked. Keying on the structured
      # notification_type (not message text) holds up across releases, and
      # defaulting to the calm state means an unrecognized notification never
      # false-alarms magenta. Any other <state> is written verbatim (Codex feeds
      # `waiting` straight in via its PermissionRequest event).
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
    # the switchboard checkout/cellar (which moves on upgrade). One reporter is
    # shared by every adapter — the state-file format is agent-neutral.
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

    # The adapter's delivery file for a worktree (e.g. ".claude/settings.local.json").
    def settings_path(worktree, settings_rel)
      File.join(worktree, settings_rel)
    end

    # Add our hooks to a worktree's local agent settings (merge-safe — leaves any
    # settings already there untouched) and keep the file out of git status.
    # `events` is the adapter's [event, state, matcher] map; `settings_rel` its file.
    def enable(worktree, settings_rel, events)
      script = ensure_script
      path = settings_path(worktree, settings_rel)
      data = load_settings(path)
      hooks = (data["hooks"] ||= {})

      # Idempotent RESET first: clear every switchboard-owned entry across ALL events
      # (not just the ones this adapter re-adds), so a re-enable never duplicates a
      # reporter, nudge, or Stop — independent of which events the adapter declares.
      # (Appending below without this would double the SessionStart nudge / Stop for an
      # adapter whose EVENTS omit those events.)
      hooks.each_key { |event| hooks[event] = strip_ours(hooks[event]) }

      # Escape the reporter path (it lives under XDG data home, which can contain a
      # space) — symmetric with the binary/Stop-fallback escaping below; an
      # unescaped path would split and the dot would silently never update.
      escaped_script = Shellwords.escape(script)
      events.each do |event, state, matcher|
        entry = { "hooks" => [{ "type" => "command", "command" => "#{escaped_script} #{state}" }] }
        entry["matcher"] = matcher if matcher
        (hooks[event] ||= []) << entry
      end

      # The #92 self-naming nudge. Both forms re-invoke switchboard (so they carry
      # NUDGE_MARK, recognized by ours? for idempotent merge / clean disable). Escape the
      # binary path (it can contain spaces). `command -v`-guard a baked bin path that can
      # go stale (a repo move/reinstall) so it's a clean no-op, never "command not found".
      bin = Shellwords.escape(ENV["SWITCHBOARD_BIN"] || "switchboard")

      # SessionStart: a soft `additionalContext` plant, ALONGSIDE the sh reporter wired by
      # the events loop above (they don't conflict — one prints, the other writes state).
      (hooks["SessionStart"] ||= []) << { "hooks" => [{ "type" => "command",
                                                        "command" => "command -v #{bin} >/dev/null 2>&1 && #{bin} rename-nudge || true" }] }

      # Stop: ONE command owns the event (the sh reporter is off `events`, see the adapter) —
      # `rename-nudge --stop` reports the state itself (`done`, or `thinking` when it
      # blocks) so a forced continuation never reads as a finished turn. If the binary is
      # stale, fall back to the direct sh reporter so `done` is still recorded (the script
      # path doesn't depend on PATH). `if/then/else` not `&& ||` so a non-zero from the
      # Ruby side can't also trigger the fallback (double-write). Agents run Stop hooks in
      # PARALLEL with no ordering, so a sibling sh `done` reporter could race a blocking
      # nudge and ring a false completion — hence one command, no sibling.
      stop_cmd = "if command -v #{bin} >/dev/null 2>&1; then #{bin} rename-nudge --stop; " \
                 "else #{escaped_script} done; fi"
      (hooks["Stop"] ||= []) << { "hooks" => [{ "type" => "command", "command" => stop_cmd }] }

      # Drop any event left empty by the reset (had only switchboard entries, not re-added).
      hooks.reject! { |_event, groups| groups.empty? }

      write_json(path, data)
      ignore_local_settings(worktree, settings_rel)
      path
    rescue Corrupt => e
      warn "switchboard: #{e.message} — leaving it untouched"
      nil
    end

    def disable(worktree, settings_rel)
      path = settings_path(worktree, settings_rel)
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

    def enabled?(worktree, settings_rel)
      data = read_json(settings_path(worktree, settings_rel))
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

    # Keep the delivery file out of `git status` via the worktree's local excludes
    # (uncommitted), regardless of the repo's own .gitignore.
    def ignore_local_settings(worktree, rel)
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
