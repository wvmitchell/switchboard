# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # AgentHooks wires the PER-WORKTREE adapters (just Claude) and surfaces the GLOBAL
  # codex block's status. Codex isn't wired per worktree — it can't discover project
  # hooks in linked worktrees, so it lives in one consented ~/.codex/config.toml block
  # (Installer-managed). CODEX_HOME is sandboxed so the real ~/.codex is untouched.
  class AgentHooksTest < SandboxTest
    def setup
      super
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
    end

    def worktree
      @worktree ||= begin
        wt = path("wt")
        FileUtils.mkdir_p(wt)
        wt
      end
    end

    def test_per_worktree_adapters_are_claude_only
      assert_equal [ClaudeHook], AgentHooks::ADAPTERS
    end

    def test_enable_wires_claude_per_worktree
      AgentHooks.enable(worktree)
      assert ClaudeHook.enabled?(worktree), "claude wired per worktree"
    end

    def test_disable_clears_claude_per_worktree
      AgentHooks.enable(worktree)
      AgentHooks.disable(worktree)
      refute ClaudeHook.enabled?(worktree)
    end

    def test_enabled_is_true_when_claude_is_on
      ClaudeHook.enable(worktree)
      assert AgentHooks.enabled?(worktree)
    end

    # The global codex block counts as enabled for EVERY worktree (it covers them all).
    def test_enabled_counts_the_global_codex_block
      refute AgentHooks.enabled?(worktree)
      CodexHook.install_global
      assert AgentHooks.enabled?(worktree), "global codex block ⇒ enabled? everywhere"
    end

    # Feeds doctor: per-worktree claude + global codex.
    def test_enabled_adapters_includes_claude_per_worktree_and_codex_global
      assert_empty AgentHooks.enabled_adapters(worktree), "nothing wired yet"
      CodexHook.install_global
      assert_equal [CodexHook], AgentHooks.enabled_adapters(worktree), "global codex shows even with no per-worktree claude"
      ClaudeHook.enable(worktree)
      assert_equal [ClaudeHook, CodexHook], AgentHooks.enabled_adapters(worktree)
    end

    # A per-worktree adapter raising (a non-Corrupt IO error HookFile doesn't rescue) must
    # not abort the fan-out nor crash the caller (enable-hooks has no outer rescue).
    def test_enable_isolates_a_failing_adapter
      err = capture_io do
        stub_method(ClaudeHook, :enable, ->(*) { raise "boom" }) do
          AgentHooks.enable(worktree) # warns, does not raise
        end
      end[1]
      assert_match(/claude hook enable failed/, err)
    end
  end
end
