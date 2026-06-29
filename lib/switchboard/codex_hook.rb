# frozen_string_literal: true

require_relative "hook_file"
require_relative "marker_block"

module Switchboard
  # The Codex adapter — GLOBAL delivery.
  #
  # Codex 0.142.x does NOT discover project-local `<worktree>/.codex/hooks.json` in a
  # linked git worktree (its project-hook discovery doesn't follow the `.git`-file →
  # common-dir indirection). Switchboard is nothing but linked worktrees, so the
  # per-worktree file is dead on arrival. A CONFIG-level hook is not project-discovered,
  # so it fires everywhere — including linked worktrees. So Codex hooks ship as ONE
  # marker-delimited `[hooks]` block in the user's `~/.codex/config.toml` (via the shared
  # `MarkerBlock`), installed once with the user's consent (`Installer`), keyed off cwd by
  # the same agent-neutral reporter Claude uses. `AgentState` only renders tracked
  # worktrees, so the block firing for non-switchboard codex sessions is inert there.
  #
  # Trust: Codex won't run any hook until it's `/hooks`-approved (or bypassed). The
  # approval is keyed by the command HASH and persisted in Codex's state sqlite — NOT in
  # this block — so a re-`install_global` preserves the approval AS LONG AS the emitted
  # commands stay byte-stable (deterministic paths + fixed event order; see
  # HookFile.command_entries). Changing a command re-triggers a one-time `/hooks` review.
  #
  # Nesting: a global hook fires for EVERY codex, including a nested `codex exec` (a
  # `/codex` under Claude). The GUARD suppresses it when a Claude-Code parent is detected
  # (CLAUDECODE / CLAUDE_CODE_SESSION_ID propagate into the hook env). A top-level codex
  # launched by switchboard into a tmux shell has neither, so it fires. (Codex-under-codex
  # carries no Claude marker and is not caught — documented residual.)
  #
  # No Notification event: PermissionRequest is Codex's only user-blocked signal, so
  # `waiting` is best-effort (a session command that bypasses ALL approvals suppresses it).
  module CodexHook
    module_function

    BEGIN_MARK = "# >>> switchboard codex hooks >>>"
    NOTE_MARK  = "# managed by switchboard — edits between the markers are overwritten; delete the block to disable"
    END_MARK   = "# <<< switchboard codex hooks <<<"

    # Skip the codex reporter/nudge when running under another agent. Equal-precedence,
    # left-associative sh: `(A || B) && exit 0` — exit 0 (suppress) if EITHER marker is
    # set, else fall through to the command.
    GUARD = '[ -n "$CLAUDECODE" ] || [ -n "$CLAUDE_CODE_SESSION_ID" ] && exit 0'

    EVENTS = [
      ["UserPromptSubmit",  "thinking", nil],
      ["PreToolUse",        "thinking", "*"],
      ["PostToolUse",       "thinking", "*"],
      ["PermissionRequest", "waiting",  "*"],
      ["SessionStart",      "done",     nil]
    ].freeze

    # A foreign hooks config we'd collide with (any TOML `hooks` representation Codex
    # accepts) means we must NOT write — two `[hooks]` tables = invalid TOML.
    Collision = Class.new(StandardError)

    def label = "codex"

    # ~/.codex/config.toml, honoring $CODEX_HOME (and sandboxed in tests).
    def config_path
      File.expand_path(File.join(ENV["CODEX_HOME"] || "~/.codex", "config.toml"))
    end

    # Idempotently write the global [hooks] block. Returns the path, or :collision if the
    # user has their own hooks config, or :corrupt if the post-write round-trip fails
    # (restored from backup). Best-effort: any other error degrades to nil (never crashes
    # install).
    def install_global
      script = HookFile.ensure_script
      bin = ENV["SWITCHBOARD_BIN"] || "switchboard"
      existed = File.exist?(config_path)
      body = existed ? File.read(config_path) : ""

      # Collision guard: refuse if a hooks representation lives OUTSIDE our markers.
      raise Collision if foreign_hooks?(MarkerBlock.strip(body, BEGIN_MARK, END_MARK))

      inner = "#{NOTE_MARK}\n[hooks]\n#{toml_hooks(script, bin)}"
      new_body = MarkerBlock.replace(body, BEGIN_MARK, END_MARK, inner)

      MarkerBlock.backup(config_path) # first-write-only .bak (a pristine on-disk copy)
      MarkerBlock.atomic_write(config_path, new_body)

      # Parser-free round-trip: the on-disk file must be exactly what we wrote, else the
      # write was torn. Roll back to the EXACT pre-write state — rewrite the in-memory
      # `body` if the config already existed, or delete the file if we'd just created it —
      # rather than the (possibly stale, multi-install-old) first-write .bak.
      unless File.read(config_path) == new_body
        existed ? MarkerBlock.atomic_write(config_path, body) : File.delete(config_path)
        return :corrupt
      end
      config_path
    rescue Collision
      warn "switchboard: #{config_path} already has its own [hooks] config — leaving it; codex dots off"
      :collision
    rescue StandardError
      nil
    end

    def remove_global
      return unless File.exist?(config_path)

      body = File.read(config_path)
      return unless MarkerBlock.present?(body, BEGIN_MARK)

      MarkerBlock.atomic_write(config_path, MarkerBlock.strip(body, BEGIN_MARK, END_MARK))
    rescue StandardError
      nil
    end

    def installed?
      File.exist?(config_path) && MarkerBlock.present?(File.read(config_path), BEGIN_MARK)
    rescue StandardError
      false
    end

    # --- internals -----------------------------------------------------------

    # Any TOML `hooks` representation Codex accepts, outside our markers — in ANY spelling:
    # a table header `[hooks]` / `[ hooks ]` / `["hooks"]` / `[[hooks]]` / `[hooks.PreToolUse]`,
    # or a `hooks =` / `hooks.managed_dir =` / `"hooks" =` dotted key. Writing our own
    # `[hooks]` alongside any of these makes two hooks tables — invalid TOML that breaks the
    # user's whole codex config — so we must detect every form codex would parse as `hooks`.
    def foreign_hooks?(stripped_body)
      stripped_body.match?(/^\s*\[\[?\s*"?hooks"?\s*[.\]]/) ||
        stripped_body.match?(/^\s*"?hooks"?\s*[.=]/)
    end

    # Serialize the shared command list into TOML `<Event> = [<groups>]` lines. Reuses
    # HookFile.command_entries (the same reporter/nudge/Stop strings as Claude) with the
    # codex guard. TOML BASIC strings (not literal) so a path with a single quote can't
    # break the string and the guard's double quotes escape cleanly.
    def toml_hooks(script, bin)
      by_event = Hash.new { |h, k| h[k] = [] }
      HookFile.command_entries(EVENTS, script, bin, guard: GUARD).each do |e|
        hook = %({ type = "command", command = #{toml_str(e[:command])} })
        group = e[:matcher] ? %({ matcher = #{toml_str(e[:matcher])}, hooks = [#{hook}] }) : "{ hooks = [#{hook}] }"
        by_event[e[:event]] << group
      end
      by_event.map { |event, groups| "#{event} = [#{groups.join(", ")}]" }.join("\n")
    end

    # A TOML basic string: wrap in double quotes and escape backslash, double quote, AND
    # the control chars TOML basic strings forbid raw (U+0000–U+001F) — a path with a
    # literal newline/tab would otherwise emit an unterminated/multi-line string and break
    # the whole config. Predefined escapes where TOML has them, `\uXXXX` for the rest.
    # Block form avoids Ruby's gsub backslash-replacement footgun.
    TOML_ESCAPES = { "\\" => "\\\\", '"' => '\\"', "\b" => "\\b", "\t" => "\\t",
                     "\n" => "\\n", "\f" => "\\f", "\r" => "\\r" }.freeze
    def toml_str(str)
      escaped = str.gsub(/[\\"\x00-\x1f]/) { |c| TOML_ESCAPES[c] || format("\\u%04X", c.ord) }
      %("#{escaped}")
    end
  end
end
