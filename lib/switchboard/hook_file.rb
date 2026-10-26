# frozen_string_literal: true

require "json"
require "fileutils"
require "shellwords"
require_relative "marker_block"

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
    MONITOR_MARK = "monitoring-nudge" # identifies the background-presence SessionStart/SessionEnd entries

    # Claude caps SessionEnd hooks at 1.5s unless a hook sets its own `timeout` (seconds);
    # a cold Ruby start for `monitoring-nudge --end` can approach that on a busy machine and
    # be cut off, stranding the ∞ dot until its TTL. Claude-only: a key added to the codex
    # block would re-hash its commands and void their `/hooks` trust.
    SESSION_END_TIMEOUT = 10

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
      # sb-agent-hook v6 — switchboard agent-state reporter (managed file; edits
      # are overwritten). Usage: sb-agent-hook <thinking|done|waiting|notify>
      #
      # `notify` (Claude's Notification hook) reads the event JSON on stdin and
      # reports "waiting" (magenta — blocked on you) only when its notification_type
      # marks a prompt that needs an answer: a permission request, an elicitation
      # dialog (form or URL), or a background agent asking for input. Everything
      # else, the idle timer (idle_prompt) included, is just "done" (green) — not
      # blocked. Only the extracted notification_type VALUE is compared, exactly —
      # never the whole payload, so a cwd or message that merely contains a type
      # name can't false-alarm. An unrecognized or missing type defaults to the
      # calm state. Any other <state> is written verbatim (Codex feeds `waiting`
      # straight in via its PermissionRequest event).
      #
      # `thinking` from a SUBAGENT's tool call (Claude puts an agent_id in that
      # payload; its own internal agents too) is not the main agent working, so it
      # writes nothing — except the PostToolUse that follows a subagent's approved
      # permission prompt, which writes "done" so the prompt's magenta doesn't stick
      # (its PermissionRequest still reports "waiting": that one wants you).
      state="$1"
      [ -n "$state" ] || exit 0

      dir="${SWITCHBOARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/switchboard/agents}"
      cwd=$(pwd -P)
      key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)

      field() {
        printf '%s' "$payload" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
      }

      if [ "$state" = "notify" ]; then
        payload=$(cat)
        case "$(field notification_type)" in
          permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)
            state="waiting" ;;
          *) state="done" ;;
        esac
      elif [ "$state" = "thinking" ] && [ ! -t 0 ]; then
        payload=$(cat)
        if [ -n "$(field agent_id)" ]; then
          case "$(field hook_event_name)" in
            PostToolUse|PostToolUseFailure)
              [ "$(cut -f1 "$dir/$key" 2>/dev/null)" = "waiting" ] || exit 0
              state="done" ;;
            *) exit 0 ;;
          esac
        fi
      fi

      mkdir -p "$dir" 2>/dev/null || exit 0

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
      File.expand_path(File.join(Switchboard.env("XDG_DATA_HOME") || "~/.local/share", "switchboard", MARK))
          .dup.force_encoding(Encoding::UTF_8) # `~` expands from $HOME, BINARY under a C locale
    end

    MAX_SETTINGS = 1 << 22 # 4 MiB; a real settings file is a few KB

    # A settings path that is safe to read: a regular file of sane size. A FIFO would block
    # and /dev/zero would never end, and every configured worktree's file gets read.
    def readable_settings?(path) = File.file?(path) && File.size(path) <= MAX_SETTINGS

    # :current, :stale (another release's) or :missing — what upgrade and doctor both read.
    # Whether a missing one matters is the caller's call (Installer.reporter_needed?).
    def script_state
      return :missing unless File.exist?(script_path)

      script_current? ? :current : :stale
    end

    # This version's bytes AND runnable: hooks exec it directly, so a lost exec bit is as
    # broken as old contents.
    def script_current?
      File.binread(script_path) == SCRIPT.b && File.executable?(script_path)
    rescue StandardError
      false
    end

    # Write the script out if missing or stale, mark it executable. Idempotent;
    # cheap enough to call on every enable / worktree create. Atomic (temp + rename): sh reads a
    # script as it runs, so rewriting it in place under a running hook (one blocked on stdin)
    # would resume at a stale offset in the new text — a syntax error, exit 2 (a deny, to a
    # PermissionRequest).
    def ensure_script
      path = script_path
      if !File.exist?(path) || File.binread(path) != SCRIPT.b # bytes: SCRIPT isn't ASCII, the locale may be
        FileUtils.mkdir_p(File.dirname(path))
        MarkerBlock.atomic_write(path, SCRIPT, mode: 0o755) # hooks exec it directly
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
      # Background-presence (the Layer-2 monitoring nudge + per-session marker clears).
      # SessionStart: clear this worktree's monitoring marker (a resumed agent re-declares)
      # and plant the self-report nudge — both gated at runtime on `background_presence` and
      # the source (MonitoringNudge.clears_on? / nudges_on?). SessionEnd: the agent is gone, so it
      # can't still be monitoring — clear the marker (the instant twin of the liveness TTL).
      # Matcher-less like the SessionStart nudge, so SessionEnd fires on every end reason,
      # not just /clear. Same `command -v` bin guard so a stale path no-ops cleanly.
      entries << { event: "SessionStart", matcher: nil,
                   command: "#{pre}command -v #{binesc} >/dev/null 2>&1 && #{binesc} monitoring-nudge || true" }
      entries << { event: "SessionEnd", matcher: nil,
                   command: "#{pre}command -v #{binesc} >/dev/null 2>&1 && #{binesc} monitoring-nudge --end || true" }
      entries
    end

    # Add our hooks to a worktree's local agent settings (merge-safe — leaves any
    # settings already there untouched) and keep the file out of git status.
    # `events` is the adapter's [event, state, matcher] map; `settings_rel` its file.
    def enable(worktree, settings_rel, events)
      script = ensure_script
      path = settings_path(worktree, settings_rel)
      write_json(path, merged(load_settings(path), events, script, bin))
      ignore_local_settings(worktree, settings_rel)
      path
    rescue Corrupt => e
      warn "switchboard: #{e.message} — leaving it untouched"
      nil
    end

    # Bring an already-hooked worktree up to date, for an upgrade: a no-op when the file
    # already holds what `enable` would write, else the same rewrite — unless the file
    # changed while we merged. Claude writes this file too (a "don't ask again" grant), and
    # replacing it from our earlier read would silently drop that grant. Returns :current,
    # :rewired, :conflict (skipped; re-run) or :corrupt (left untouched).
    #
    # It only updates: a file without switchboard's hooks (disabled, or deleted since the
    # caller listed it) is left as it is, never re-hooked.
    def refresh(worktree, settings_rel, events)
      ensure_script # before the snapshot, so the changed-file check spans every step up to the write
      path = settings_path(worktree, settings_rel)
      return :corrupt if File.exist?(path) && !(readable_settings?(path) && File.readable?(path))

      before = File.exist?(path) ? File.binread(path) : nil
      data = load_settings(path)
      return :current unless ours_in?(data)

      want = merged(data, events, script_path, bin)
      return :current if same_hooks?(want, data)
      return :conflict unless (File.exist?(path) ? File.binread(path) : nil) == before

      write_json(path, want)
      ignore_local_settings(worktree, settings_rel)
      :rewired
    rescue Corrupt
      :corrupt
    end

    # Whether the file already holds exactly what `enable` would write. A missing or
    # unparseable file is not current.
    def current?(worktree, settings_rel, events)
      data = load_settings(settings_path(worktree, settings_rel))
      same_hooks?(merged(data, events, script_path, bin), data)
    rescue Corrupt, SystemCallError
      false
    end

    # Equal up to the order of groups within an event. `merged` re-appends switchboard's
    # groups at the end, so a hook added after them would otherwise read as stale forever;
    # Claude runs an event's hooks in parallel, so their order carries no meaning.
    def same_hooks?(a, b)
      normalize = lambda do |data|
        d = JSON.parse(JSON.generate(data))
        d["hooks"]&.each { |event, groups| d["hooks"][event] = Array(groups).sort_by { |g| JSON.generate(canonical(g)) } }
        d
      end
      normalize.call(a) == normalize.call(b)
    rescue StandardError
      false
    end

    # Hash keys sorted at every level, so a sort key built from it ignores key order (a file
    # Claude rewrote can hold the same group with its keys in another order).
    def canonical(value)
      case value
      when Hash  then value.keys.sort.to_h { |k| [k, canonical(value[k])] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    # A settings file holding switchboard's hooks that no longer parses: the caller reports
    # it. A broken file without our marks is the user's own and none of our business. One
    # we won't or can't read (a FIFO, /dev/zero, a huge file, no permission) can't be checked for marks, so it's
    # reported too rather than silently dropped from install's and upgrade's scan. A
    # directory there is plainly not a settings file: doctor's unreadable? row has it.
    def corrupt?(worktree, settings_rel)
      path = settings_path(worktree, settings_rel)
      load_settings(path)
      false
    rescue Corrupt
      return !File.directory?(path) unless readable_settings?(path)

      raw = File.binread(path)
      [MARK, NUDGE_MARK, MONITOR_MARK].any? { |m| raw.include?(m.b) }
    rescue SystemCallError
      File.exist?(path) && !File.directory?(path) # no permission: reported, like a FIFO
    end

    # Why a settings file won't parse (load_settings' message), or nil when it does — what
    # install and doctor print, since "invalid JSON" isn't the only way to fail.
    def corrupt_reason(worktree, settings_rel)
      load_settings(settings_path(worktree, settings_rel))
      nil
    rescue Corrupt => e
      e.message
    rescue SystemCallError
      "#{settings_path(worktree, settings_rel)} can't be read"
    end

    # Any settings file that won't parse, ours or not (doctor's row; Installer's hooked and
    # stale lists use corrupt?, which also needs our marks).
    def unparseable?(worktree, settings_rel)
      load_settings(settings_path(worktree, settings_rel))
      false
    rescue Corrupt
      true
    rescue SystemCallError
      false # unreadable: see unreadable?
    end

    # A settings path that exists but can't be read (a directory, no permission).
    def unreadable?(worktree, settings_rel)
      path = settings_path(worktree, settings_rel)
      return false unless File.exist?(path)
      return true unless readable_settings?(path)

      File.read(path)
      false
    rescue SystemCallError
      true
    end

    # Pure: `data` with switchboard's entries reset to this version's set — what `enable`
    # writes. Leaves `data` itself untouched, so `refresh` can compare the two.
    def merged(data, events, script, bin)
      data = JSON.parse(JSON.generate(data))
      hooks = (data["hooks"] ||= {})

      # Idempotent RESET first: clear every switchboard-owned entry across ALL events so a
      # re-enable never duplicates a reporter/nudge/Stop, independent of which events this
      # adapter declares (appending without this would double SessionStart/Stop).
      hooks.each_key { |event| hooks[event] = strip_ours(hooks[event]) }

      command_entries(events, script, bin).each do |e|
        hook = { "type" => "command", "command" => e[:command] }
        hook["timeout"] = SESSION_END_TIMEOUT if e[:event] == "SessionEnd"
        group = { "hooks" => [hook] }
        group["matcher"] = e[:matcher] if e[:matcher]
        (hooks[e[:event]] ||= []) << group
      end

      # Drop any event left empty by the reset (had only switchboard entries, not re-added).
      hooks.reject! { |_event, groups| groups.empty? }
      data
    end

    # The binary the hook commands call back into.
    def bin
      Switchboard.env("SWITCHBOARD_BIN") || "switchboard"
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
      ours_in?(read_json(settings_path(worktree, settings_rel)))
    end

    def ours_in?(data)
      (data["hooks"] || {}).values.flatten.any? do |group|
        Array(group["hooks"]).any? { |h| ours?(h["command"]) }
      end
    rescue StandardError
      false
    end

    # --- internals -----------------------------------------------------------

    # A hook command switchboard installed — the agent-state reporter, the #92 rename
    # nudge, OR the background-presence monitoring nudge/clears. Each must be recognized
    # so disable / idempotent-merge handle it (a missed mark would duplicate on re-enable
    # and survive disable).
    def ours?(command)
      s = command.to_s
      s.include?(MARK) || s.include?(NUDGE_MARK) || s.include?(MONITOR_MARK)
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
      raise Corrupt, "#{path} isn't a regular file under #{MAX_SETTINGS >> 20} MiB" unless readable_settings?(path)

      body = File.read(path, encoding: Encoding::UTF_8) # UTF-8 whatever the locale (a C-locale tmux pane)
      raise Corrupt, "#{path} isn't valid JSON" unless body.valid_encoding? # strip raises on bad bytes
      return {} if body.strip.empty?

      data = JSON.parse(body) || {}
      raise Corrupt, "#{path} isn't valid JSON" unless data.is_a?(Hash) # `[]` parses, but holds no settings
      raise Corrupt, "#{path} has a malformed hooks section" unless hooks_shape?(data["hooks"])

      data
    rescue JSON::ParserError, EncodingError
      raise Corrupt, "#{path} isn't valid JSON"
    end

    # The shape merged/strip_ours walk: { event => [ { "hooks" => [ {...} ] } ] }. Anything
    # else (an array, a null entry) is the user's to fix, never ours to rewrite or crash on.
    def hooks_shape?(hooks)
      return true if hooks.nil?

      hooks.is_a?(Hash) && hooks.values.all? do |groups|
        groups.is_a?(Array) && groups.all? do |g|
          g.is_a?(Hash) && (g["hooks"].nil? || (g["hooks"].is_a?(Array) && g["hooks"].all?(Hash)))
        end
      end
    end

    # Read-only/best-effort parse for the enabled? probe — corrupt reads as {}
    # (i.e. "not enabled"), which is harmless since nothing is written.
    def read_json(path)
      return {} unless File.exist?(path) && readable_settings?(path)

      JSON.parse(File.read(path, encoding: Encoding::UTF_8)) || {}
    rescue StandardError
      {}
    end

    # Atomic (temp + rename): Claude watches this file and reloads it live, so it must
    # never catch a half-written one.
    def write_json(path, data)
      MarkerBlock.atomic_write(path, "#{JSON.pretty_generate(data)}\n")
    end
  end
end
