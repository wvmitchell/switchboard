# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "timeout"
require "etc"

module Switchboard
  # Real-Codex smoke (#110 + the linked-worktree fix): the delivery path NO unit test
  # can reach — does the GLOBAL `[hooks]` block in `~/.codex/config.toml` actually FIRE
  # and write switchboard's agent-state files when a real `codex` runs in a LINKED git
  # worktree? That last word is the whole point: codex 0.142.x silently does NOT discover
  # a project-local `<worktree>/.codex/hooks.json` in a linked worktree (its project-hook
  # discovery doesn't follow the `.git`-file → common-dir indirection), and switchboard is
  # nothing but linked worktrees — so the v0.39.0 per-worktree delivery was dead on arrival.
  # The fix moves codex hooks to a CONFIG-level block, which is not project-discovered and
  # so fires everywhere. This smoke is the standing regression guard for that: it builds a
  # primary repo, adds a LINKED worktree, installs the global block into a SANDBOX
  # CODEX_HOME (a copy of the real one, so the run is authed but the user's real config is
  # never touched), drives `codex exec` headlessly in the linked worktree, and asserts the
  # resting state lands where AgentState reads it.
  #
  # The #130 nesting guard (suppress under a Claude-Code parent) is covered offline by
  # codex_hook_test's runtime guard test — no second (token-spending) codex run here.
  #
  # OPT-IN: it needs `codex` on PATH, auth, and network — and it spends tokens — so it runs
  # ONLY when SWITCHBOARD_CODEX_SMOKE=1 (mirrors bin/test-smoke's tmux gate). It's already
  # out of the offline bin/test entirely (test/smoke/ glob). A SandboxTest (not SmokeCase)
  # subclass: it needs a git repo + codex, not tmux, and SandboxTest already walls off
  # XDG_STATE_HOME/SWITCHBOARD_STATE_DIR so the reporter and AgentState share one state dir.
  class CodexHookSmokeTest < SandboxTest
    def setup
      super
      skip "set SWITCHBOARD_CODEX_SMOKE=1 to run the real-codex smoke" unless ENV["SWITCHBOARD_CODEX_SMOKE"] == "1"
      skip "codex not on PATH" unless system("command -v codex >/dev/null 2>&1")
    end

    def test_global_hooks_fire_in_a_linked_worktree
      # Sandbox CODEX_HOME = ONLY the real auth.json (so the run is authed against borrowed
      # credentials), then OUR block written fresh into it. Deliberately not the whole real
      # ~/.codex: copying the user's config.toml would carry their own [hooks] (the install
      # collision-guards on it), and we want to exercise our block in isolation. The real
      # ~/.codex is never touched.
      real_auth = File.join(Etc.getpwuid(Process.uid).dir, ".codex", "auth.json")
      skip "no real ~/.codex/auth.json to borrow for the run" unless File.exist?(real_auth)
      sandbox_home = path("codexhome")
      FileUtils.mkdir_p(sandbox_home)
      FileUtils.cp(real_auth, File.join(sandbox_home, "auth.json"))
      ENV["CODEX_HOME"] = sandbox_home

      installed = CodexHook.install_global
      assert_equal CodexHook.config_path, installed, "global block written into the sandbox config"

      # Primary repo + a LINKED worktree — the exact case project-local hooks can't reach.
      primary = temp_git_repo
      system("git", "-C", primary, "commit", "-q", "--allow-empty", "-m", "init")
      linked = path("linked")
      ok = system("git", "-C", primary, "worktree", "add", "-q", "-b", "smoke-linked", linked,
                  out: File::NULL, err: File::NULL)
      assert ok, "git worktree add created the linked worktree"

      marker = "codex-smoke-#{rand(100_000)}"
      out, ran = run_codex(linked, "Run the shell command: echo #{marker}. Then stop.")
      skip "codex run failed (auth/network/sandbox?) — #{out[0, 200]}" unless ran

      assert_includes out, marker, "the tool actually ran in the linked worktree (PreToolUse/PostToolUse fired)"

      # The crux: the GLOBAL hook fired inside a LINKED worktree (the v0.39.0 per-worktree
      # path could not) and wrote a resting state where AgentState reads it.
      state = AgentState.new.scan([linked])[linked]
      assert_equal :done, state,
                   "global Stop reporter wrote 'done' for the LINKED worktree into the sandboxed state dir. " \
                   "state dir: #{Dir.glob(File.join(AgentState.state_dir, '*')).map { |f| File.read(f).chomp }.inspect}"

      # Best-effort: if codex logs its hook invocations, confirm the dot-driving order.
      # Guarded on presence so an opaque codex log format never fails the bug-fix guard.
      events = out.scan(/^hook: ([A-Za-z]+)/).flatten
      if events.any?
        assert_includes events, "SessionStart", "SessionStart fired"
        assert_includes events, "Stop", "Stop fired (the unified reporter/backstop)"
        if events.include?("PreToolUse") && events.include?("PostToolUse")
          assert_operator events.index("PreToolUse"), :<, events.index("PostToolUse"),
                          "PreToolUse precedes PostToolUse — 'thinking' holds across the tool"
        end
      end
    end

    private

    # Drive codex headlessly in `repo`: bypass the interactive hook-trust prompt, allow
    # tool use (workspace-write), keep reasoning cheap. Returns [combined_output, ok?].
    # Bounded so "needs network" never becomes "hangs the smoke layer".
    #
    # CODEX_HOME (the sandbox copy, set by the test) is inherited by the child, so codex
    # reads BOTH its borrowed auth and our global block from there — the real ~/.codex is
    # never consulted. HOME is briefly restored to the real one only as a belt-and-braces
    # for any HOME-relative path codex might still touch; the sandboxed
    # XDG_STATE_HOME/XDG_DATA_HOME stay inherited, which is what keeps the reporter writing
    # into the sandbox state dir AgentState reads.
    #
    # The child is spawned WITH cwd = repo (`chdir:`), NOT `codex -C repo`: switchboard
    # always launches the agent FROM the worktree root, and the reporter keys state by the
    # hook's `pwd -P` — so the cwd must be the worktree for the dot to land on it.
    #
    # CLAUDECODE / CLAUDE_CODE_SESSION_ID are UNSET for the child (env-hash-as-first-
    # array-element). This smoke simulates a TOP-LEVEL codex (the one switchboard launches
    # into a plain tmux shell, which carries neither marker); the #130 guard would otherwise
    # correctly suppress every reporter when this suite is itself run from inside a Claude
    # Code session. (That suppression is exactly what codex_hook_test's guard test asserts.)
    def run_codex(repo, prompt)
      cmd = [{ "CLAUDECODE" => nil, "CLAUDE_CODE_SESSION_ID" => nil },
             "codex", "exec", prompt, "--dangerously-bypass-hook-trust",
             "-s", "workspace-write", "-c", 'model_reasoning_effort="low"']
      saved_home = ENV["HOME"]
      ENV["HOME"] = Etc.getpwuid(Process.uid).dir
      io = IO.popen(cmd, err: %i[child out], chdir: repo)
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
