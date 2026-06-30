# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"

module Switchboard
  # The shared engine behind the hook adapters. What BOTH agents share lives here ONCE:
  # the command STRINGS (`command_entries` — the state reporter per event, the #92
  # SessionStart nudge, the unified Stop), the materialized sh reporter (`SCRIPT`), and the
  # nudge/Stop logic. Drift between two agents' Stop logic would be a silent bug, so it has
  # one home.
  #
  # The PER-WORKTREE machinery below — `enable`/`disable`/`enabled?`, the merge-safe JSON
  # strip, the `info/exclude` wiring — serves ONLY `ClaudeHook` (Claude's
  # `.claude/settings.local.json`, the JSON shape
  # `{"hooks": {<Event>: [{"matcher"?, "hooks": [{"type":"command","command"}]}]}}`).
  # `CodexHook` does NOT use it: codex can't discover project-local hooks in a linked
  # worktree, so it serializes `command_entries` to TOML and writes ONE global
  # `~/.codex/config.toml` block itself (see `CodexHook`). So the shared seam is
  # `command_entries`, not the file machinery.
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
      # sb-agent-hook v4 — switchboard agent-state reporter (managed file; edits
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
      # Write atomically (temp + mv, same dir => same fs => atomic rename). A plain
      # `> file` is non-atomic: a reader (the sidebar's warm-render fingerprint, or
      # AgentState.scan) could catch a half-written line, skip the malformed state,
      # and miss the report until the next event. With temp+rename, readers always
      # see the old file or the fully-written new one. $$ keeps concurrent reporters
      # from colliding on the temp; rm cleans up a temp the write/rename didn't consume.
      tmp="$dir/$key.$$"
      printf '%s\t%s\t%s\n' "$state" "$cwd" "$(date +%s)" >"$tmp" 2>/dev/null &&
        mv -f "$tmp" "$dir/$key" 2>/dev/null
      rm -f "$tmp" 2>/dev/null

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

    # The ordered hook commands switchboard wires for an agent: a state reporter per
    # `events` entry, the #92 SessionStart nudge, and the unified Stop. Returned as
    # `{event:, matcher:, command:}` so each delivery serializes it its own way —
    # HookFile to per-worktree JSON (Claude), CodexHook to the global `~/.codex/config.toml`
    # block (Codex). The command STRINGS are identical across agents, so they live here
    # ONCE (drift between two agents' Stop logic would be a silent bug), and stay
    # byte-stable so Codex's hash-keyed `/hooks` trust survives a re-ensure.
    #
    # `guard` is an optional sh test prepended to every command as `<guard>; <cmd>`.
    # Codex passes the nested-agent guard (so a `/codex` under Claude doesn't report);
    # Claude passes nothing — it legitimately runs with CLAUDECODE set (it IS Claude).
    def command_entries(events, script, bin, guard: "")
      esc = Shellwords.escape(script)  # XDG data path can contain a space
      binesc = Shellwords.escape(bin)  # bin path can contain a space
      pre = guard.empty? ? "" : "#{guard}; "
      entries = events.map do |event, state, matcher|
        { event: event, matcher: matcher, command: "#{pre}#{esc} #{state}" }
      end
      # SessionStart nudge: a soft additionalContext plant beside the reporter. `command -v`
      # guards a baked bin path that can go stale (repo move / reinstall) → clean no-op.
      entries << { event: "SessionStart", matcher: nil,
                   command: "#{pre}command -v #{binesc} >/dev/null 2>&1 && #{binesc} rename-nudge || true" }
      # Stop: ONE command owns the event. `rename-nudge --stop` reports the state itself
      # (`done`, or `thinking` when it blocks); a stale binary falls back to the sh reporter
      # so `done` still lands. `if/then/else` (not `&& ||`) so a Ruby non-zero can't also
      # fire the fallback. Agents run Stop hooks in PARALLEL, so a sibling sh reporter could
      # race the blocking nudge → false completion; hence one command, no sibling.
      entries << { event: "Stop", matcher: nil,
                   command: "#{pre}if command -v #{binesc} >/dev/null 2>&1; then #{binesc} rename-nudge --stop; " \
                            "else #{esc} done; fi" }
      entries
    end

    # Add our hooks to a worktree's local agent settings (merge-safe — leaves any
    # settings already there untouched) and keep the file out of git status.
    # `events` is the adapter's [event, state, matcher] map; `settings_rel` its file.
    def enable(worktree, settings_rel, events)
      script = ensure_script
      path = settings_path(worktree, settings_rel)
      data = load_settings(path)
      hooks = (data["hooks"] ||= {})

      # Idempotent RESET first: clear every switchboard-owned entry across ALL events so a
      # re-enable never duplicates a reporter/nudge/Stop, independent of which events this
      # adapter declares (appending without this would double SessionStart/Stop).
      hooks.each_key { |event| hooks[event] = strip_ours(hooks[event]) }

      command_entries(events, script, ENV["SWITCHBOARD_BIN"] || "switchboard").each do |e|
        group = { "hooks" => [{ "type" => "command", "command" => e[:command] }] }
        group["matcher"] = e[:matcher] if e[:matcher]
        (hooks[e[:event]] ||= []) << group
      end

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
