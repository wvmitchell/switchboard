# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # AgentHooks is the per-agent adapter registry: enable/disable/probe fan out over
  # ADAPTERS so the create / enable-hooks / disable-hooks / doctor call sites stay
  # agent-agnostic. The consumer side (AgentState) is already agent-blind.
  class AgentHooksTest < SandboxTest
    def worktree
      @worktree ||= begin
        wt = path("wt")
        FileUtils.mkdir_p(wt)
        wt
      end
    end

    def test_registers_claude_and_codex_adapters
      assert_equal [ClaudeHook, CodexHook], AgentHooks::ADAPTERS
    end

    def test_enable_wires_every_adapter
      AgentHooks.enable(worktree)
      assert ClaudeHook.enabled?(worktree), "claude adapter wired"
      assert CodexHook.enabled?(worktree), "codex adapter wired"
    end

    def test_disable_clears_every_adapter
      AgentHooks.enable(worktree)
      AgentHooks.disable(worktree)
      refute ClaudeHook.enabled?(worktree)
      refute CodexHook.enabled?(worktree)
      refute AgentHooks.enabled?(worktree)
    end

    def test_enabled_is_true_when_any_adapter_is_on
      ClaudeHook.enable(worktree) # claude only
      assert AgentHooks.enabled?(worktree), "any adapter on ⇒ enabled?"
    end

    # enabled_adapters returns only the live subset (this feeds doctor's per-adapter line).
    def test_enabled_adapters_returns_the_live_subset
      assert_empty AgentHooks.enabled_adapters(worktree), "none wired yet"
      CodexHook.enable(worktree) # codex only
      assert_equal [CodexHook], AgentHooks.enabled_adapters(worktree)
      ClaudeHook.enable(worktree)
      assert_equal [ClaudeHook, CodexHook], AgentHooks.enabled_adapters(worktree)
    end

    # One adapter raising a NON-Corrupt error (an IO failure HookFile doesn't rescue)
    # must not abort the fan-out and leave the other unwired, nor propagate to the
    # caller (enable-hooks has no outer rescue). It warns and carries on.
    def test_enable_isolates_a_failing_adapter
      err = capture_io do
        stub_method(ClaudeHook, :enable, ->(*) { raise "boom" }) do
          AgentHooks.enable(worktree)
        end
      end[1]
      assert CodexHook.enabled?(worktree), "codex still wired despite claude raising"
      assert_match(/claude hook enable failed/, err)
    end
  end
end
