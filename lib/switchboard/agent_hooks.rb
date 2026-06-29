# frozen_string_literal: true

require_relative "claude_hook"
require_relative "codex_hook"

module Switchboard
  # Registry for per-agent hook delivery. The state-file consumer is already
  # agent-neutral; adapters translate switchboard's intents into each agent's
  # local hook config format.
  module AgentHooks
    module_function

    ADAPTERS = [ClaudeHook, CodexHook].freeze

    def enable(worktree)
      ADAPTERS.each { |adapter| safely(adapter, :enable, worktree) }
    end

    def disable(worktree)
      ADAPTERS.each { |adapter| safely(adapter, :disable, worktree) }
    end

    def enabled?(worktree)
      ADAPTERS.any? { |adapter| adapter.enabled?(worktree) }
    end

    def enabled_adapters(worktree)
      ADAPTERS.select { |adapter| adapter.enabled?(worktree) }
    end

    # Fan out, isolating per adapter: one adapter raising a non-Corrupt error (an
    # EACCES/EISDIR/ENOSPC on its settings file — HookFile only rescues Corrupt)
    # must not abort the loop and leave the other adapter unwired, nor crash the
    # caller (enable-hooks has no outer rescue). Degrade with a warn, like every
    # other shell-out here. (`enabled?` already rescues to false internally.)
    def safely(adapter, action, worktree)
      adapter.public_send(action, worktree)
    rescue StandardError => e
      warn "switchboard: #{adapter.label} hook #{action} failed (#{e.message})"
      nil
    end
  end
end
