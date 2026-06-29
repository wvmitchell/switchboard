# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "timeout"
require "etc"

module Switchboard
  # Real-Codex smoke (#110): the delivery path NO unit test can reach — does a
  # project-local `.codex/hooks.json` actually FIRE and write switchboard's
  # agent-state files when a real `codex` runs in the worktree? It boots a
  # throwaway git repo, enables the Codex adapter, drives `codex exec` headlessly
  # (bypassing the interactive hook-trust prompt), and asserts the dot-driving
  # event sequence + the resulting state — not just that `enable` wrote a file.
  # This is the layer that turns the three runtime assumptions the review flagged
  # (does it fire / event ordering / stop-chain) into a standing regression guard
  # against a future Codex version silently breaking parity.
  #
  # OPT-IN: it needs `codex` on PATH, auth, and network — and it spends tokens — so
  # it runs ONLY when SWITCHBOARD_CODEX_SMOKE=1 (mirrors bin/test-smoke's tmux
  # gate). It's already out of the offline bin/test entirely (test/smoke/ glob).
  # A SandboxTest (not SmokeCase) subclass: it needs a git repo + codex, not tmux,
  # and SandboxTest already walls off XDG_STATE_HOME so the reporter and
  # AgentState read the same sandboxed state dir.
  class CodexHookSmokeTest < SandboxTest
    def setup
      super
      skip "set SWITCHBOARD_CODEX_SMOKE=1 to run the real-codex smoke" unless ENV["SWITCHBOARD_CODEX_SMOKE"] == "1"
      skip "codex not on PATH" unless system("command -v codex >/dev/null 2>&1")
    end

    def test_codex_fires_project_hooks_and_reports_state
      repo = temp_git_repo
      system("git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "init")
      CodexHook.enable(repo)

      marker = "codex-smoke-#{rand(100_000)}"
      out, ok = run_codex(repo, "Run the shell command: echo #{marker}. Then stop.")
      skip "codex run failed (auth/network/sandbox?) — #{out[0, 200]}" unless ok

      assert_includes out, marker, "the tool actually ran (PreToolUse/PostToolUse fired)"

      # The crux: the project-local hook wrote state where AgentState reads it.
      assert_equal :done, AgentState.new.scan([repo])[repo],
                   "Stop reporter wrote a resting 'done' state to the sandboxed state dir"

      # The dot-driving sequence, read off codex's own hook log.
      events = out.scan(/^hook: ([A-Za-z]+)/).flatten
      assert_includes events, "SessionStart", "SessionStart fired"
      assert_includes events, "Stop", "Stop fired (the unified reporter/backstop)"
      assert_operator events.index("PreToolUse"), :<, events.index("PostToolUse"),
                      "PreToolUse precedes PostToolUse — 'thinking' holds across the tool"
      # Under --dangerously-bypass-hook-trust approvals are auto-granted, so
      # PermissionRequest never fires — confirming `waiting` is best-effort (a
      # non-bypass gate would fire it; see CodexHook's mapping note).
      refute_includes events, "PermissionRequest", "no waiting signal under full auto-approve (documented)"
    end

    private

    # Drive codex headlessly: bypass the interactive hook-trust prompt, allow tool
    # use (workspace-write), keep reasoning cheap. Returns [combined_output, ok?].
    # Bounded so "needs network" never becomes "hangs the smoke layer".
    #
    # SandboxTest walls off HOME, but codex resolves its auth from the REAL
    # ~/.codex — so the child gets the real HOME (from the passwd entry, not the
    # mutated ENV) while the sandboxed XDG_STATE_HOME/XDG_DATA_HOME stay inherited,
    # which is exactly what keeps the reporter writing into the sandbox state dir
    # AgentState reads. Restored immediately; the child keeps its spawned env.
    def run_codex(repo, prompt)
      cmd = ["codex", "exec", prompt, "-C", repo, "--dangerously-bypass-hook-trust",
             "-s", "workspace-write", "-c", 'model_reasoning_effort="low"']
      saved_home = ENV["HOME"]
      ENV["HOME"] = Etc.getpwuid(Process.uid).dir
      io = IO.popen(cmd, err: %i[child out])
      ENV["HOME"] = saved_home # child already spawned with real HOME; test stays sandboxed
      out = +""
      begin
        Timeout.timeout(240) { out << io.read }
      rescue Timeout::Error
        begin
          Process.kill("TERM", io.pid)
        rescue StandardError
          nil
        end
        return ["codex timed out after 240s", false]
      ensure
        io.close
      end
      [out, $?&.success?]
    rescue StandardError => e
      ENV["HOME"] = saved_home if saved_home
      ["#{e.class}: #{e.message}", false]
    end
  end
end
