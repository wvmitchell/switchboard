# frozen_string_literal: true

require_relative "claude_hook"
require_relative "codex_hook"

module Switchboard
  # Registry for agent hook delivery. The state-file consumer is already agent-neutral.
  #
  # Claude is delivered PER WORKTREE (`.claude/settings.local.json`) — it's the only
  # per-worktree adapter, so `ADAPTERS` is just `[ClaudeHook]` and the fan-out below wires
  # exactly it. Codex is delivered GLOBALLY: Codex can't discover project-local hooks in a
  # linked git worktree, so its hooks live in one consented `~/.codex/config.toml` block,
  # installed once by `Installer` (see `CodexHook`). It is NOT wired per worktree; the
  # registry only surfaces its global status (`installed?`) for `doctor` / `enabled?`.
  module AgentHooks
    module_function

    ADAPTERS = [ClaudeHook].freeze

    def enable(worktree)
      ADAPTERS.each { |adapter| safely(adapter, :enable, worktree) }
    end

    def disable(worktree)
      ADAPTERS.each { |adapter| safely(adapter, :disable, worktree) }
    end

    # Any presence wiring active for this worktree: a per-worktree adapter, or the global
    # codex block (which covers every worktree at once).
    def enabled?(worktree)
      ADAPTERS.any? { |adapter| adapter.enabled?(worktree) } || CodexHook.installed?
    end

    # Live adapters for doctor: the per-worktree ones wired here, plus codex when its
    # global block is installed (it covers this worktree like any other).
    def enabled_adapters(worktree)
      live = ADAPTERS.select { |adapter| adapter.enabled?(worktree) }
      live << CodexHook if CodexHook.installed?
      live
    end

    # Fan out, isolating per adapter: one adapter raising (an EACCES/EISDIR/ENOSPC on its
    # settings file — HookFile only rescues Corrupt) must not abort the loop nor crash the
    # caller (enable-hooks has no outer rescue). Degrade with a warn. (`enabled?` rescues
    # to false internally.)
    def safely(adapter, action, worktree)
      adapter.public_send(action, worktree)
    rescue StandardError => e
      warn "switchboard: #{adapter.label} hook #{action} failed (#{e.message})"
      nil
    end
  end
end
