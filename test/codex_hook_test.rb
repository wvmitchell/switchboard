# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # CodexHook delivers Codex's agent-state hooks GLOBALLY — one marker-delimited
  # `[hooks]` block in `~/.codex/config.toml` (codex can't discover project-local hooks
  # in linked worktrees). These tests pin the safe-write guarantees: idempotent install,
  # abort on a foreign hooks config, preserve the rest of the file, clean removal, and a
  # backup. CODEX_HOME is pointed at a sandbox tmpdir so the real ~/.codex is never
  # touched; XDG_DATA_HOME (the reporter script) is already sandboxed by SandboxTest.
  class CodexHookTest < SandboxTest
    def setup
      super
      @home = path("codexhome")
      FileUtils.mkdir_p(@home)
      ENV["CODEX_HOME"] = @home
    end

    def config = File.join(@home, "config.toml")
    def body   = File.exist?(config) ? File.read(config) : ""

    def test_config_path_honors_codex_home
      assert_equal File.join(@home, "config.toml"), CodexHook.config_path
    end

    def test_install_writes_the_global_block_and_installed_is_true
      assert_equal config, CodexHook.install_global
      assert CodexHook.installed?
      assert_includes body, CodexHook::BEGIN_MARK
      assert_includes body, CodexHook::END_MARK
      assert_includes body, "[hooks]"
    end

    # The event→state contract + the #92 nudge + the #130 guard, all in one block.
    def test_block_content
      CodexHook.install_global
      %w[SessionStart UserPromptSubmit PreToolUse PostToolUse PermissionRequest Stop].each do |ev|
        assert_match(/^#{ev} = \[/, body, "#{ev} present")
      end
      assert_includes body, "waiting", "PermissionRequest → waiting"
      assert_includes body, "rename-nudge --stop", "unified Stop nudge"
      assert(body.include?("rename-nudge ") || body.include?("rename-nudge\\"), "SessionStart nudge present")
      # the CLAUDECODE guard prefixes EVERY command (one per `type = "command"`).
      commands = body.scan(/type = "command"/).size
      guards = body.scan("$CLAUDECODE").size
      assert_equal commands, guards, "every command carries the nested-agent guard"
      assert_includes body, "$CLAUDE_CODE_SESSION_ID", "guard checks the second marker too"
    end

    def test_install_is_idempotent
      CodexHook.install_global
      CodexHook.install_global
      assert_equal 1, body.scan(CodexHook::BEGIN_MARK).size, "no duplicate block"
      assert_equal 1, body.scan(/^\[hooks\]/).size, "no duplicate [hooks]"
    end

    # Aborts on ANY foreign hooks representation outside our markers (a duplicate [hooks]
    # = invalid TOML), leaving the user's config untouched.
    def test_install_aborts_on_a_foreign_hooks_table
      File.write(config, %([hooks.PreToolUse]\nfoo = 1\n))
      _out, err = capture_io { assert_equal :collision, CodexHook.install_global }
      assert_includes File.read(config), "[hooks.PreToolUse]", "left untouched"
      refute_includes File.read(config), CodexHook::BEGIN_MARK
      assert_match(/already has its own \[hooks\]/, err)
    end

    def test_install_aborts_on_a_foreign_hooks_dotted_key
      File.write(config, %(hooks.managed_dir = "/x"\n))
      capture_io { assert_equal :collision, CodexHook.install_global }
      refute_includes File.read(config), CodexHook::BEGIN_MARK
    end

    # The collision guard must catch EVERY TOML spelling of a `hooks` table — a
    # whitespace-padded, quoted, or array-of-tables form codex still reads as `hooks`.
    # Missing one → we'd append our own `[hooks]` → two tables → the user's config stops
    # parsing. (`[ hooks ]`, `["hooks"]`, `[[hooks]]` all slipped past the first regex.)
    def test_install_aborts_on_alternate_hooks_table_spellings
      ["[ hooks ]", %(["hooks"]), "[[hooks]]"].each do |header|
        File.write(config, "#{header}\nx = 1\n")
        capture_io { assert_equal :collision, CodexHook.install_global, "#{header} must collide" }
        refute_includes File.read(config), CodexHook::BEGIN_MARK, "#{header}: left untouched"
      end
    end

    # The headline bug class: a user with codex installed but never launched has no
    # ~/.codex dir. install_global must create it, not silently fail (ENOENT → nil).
    def test_install_creates_a_missing_codex_home
      missing = File.join(@home, "sub", "dir") # @home exists; these don't
      ENV["CODEX_HOME"] = missing
      assert_equal File.join(missing, "config.toml"), CodexHook.install_global
      assert CodexHook.installed?, "the block landed in a freshly-created CODEX_HOME"
    end

    # A torn post-write round-trip restores the EXACT pre-write content (the in-memory
    # body), not a stale .bak — and returns :corrupt so install reports it. The stub
    # corrupts only the FIRST write (the block) so the round-trip mismatches; the restore
    # write (call 2) lands the real content, proving recovery.
    def test_install_restores_pre_write_body_on_a_torn_write
      File.write(config, %(model = "gpt-5.5"\n))
      calls = 0
      torn = lambda do |p, c|
        calls += 1
        File.write(MarkerBlock.real_target(p), calls == 1 ? "TORN" : c)
      end
      stub_method(MarkerBlock, :atomic_write, torn) do
        assert_equal :corrupt, CodexHook.install_global
      end
      assert_equal %(model = "gpt-5.5"\n), File.read(config), "rolled back to the exact pre-write body"
      refute CodexHook.installed?
    end

    # A torn write on a FRESH (nonexistent) config removes the file (via File.delete, not a
    # restore-write) rather than leaving a half-written one where codex had nothing.
    def test_install_deletes_a_torn_fresh_config
      refute File.exist?(config)
      stub_method(MarkerBlock, :atomic_write, ->(p, _c) { File.write(MarkerBlock.real_target(p), "TORN") }) do
        assert_equal :corrupt, CodexHook.install_global
      end
      refute File.exist?(config), "no torn file left where there was none before"
    end

    # A command path with a control char must emit a VALID TOML basic string (escaped),
    # not a raw newline that would unterminate the string and break the whole config.
    def test_toml_str_escapes_control_chars
      assert_equal %("a\\nb\\tc"), CodexHook.toml_str("a\nb\tc")
      assert_equal %("x\\u0001y"), CodexHook.toml_str("xy")
    end

    def test_install_preserves_other_config
      File.write(config, %(model = "gpt-5.5"\n\n[tui]\ntheme = "dark"\n))
      CodexHook.install_global
      assert_includes body, %(model = "gpt-5.5"), "foreign top-level key kept"
      assert_includes body, "[tui]", "foreign table kept"
      assert CodexHook.installed?
    end

    def test_remove_global_strips_only_the_block
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      CodexHook.remove_global
      refute CodexHook.installed?
      assert_includes File.read(config), %(model = "x"), "foreign content preserved"
      refute_includes File.read(config), CodexHook::BEGIN_MARK
    end

    def test_remove_global_on_absent_config_is_a_noop
      assert_nil CodexHook.remove_global
    end

    def test_install_writes_a_first_write_backup
      File.write(config, %(original = true\n))
      CodexHook.install_global
      assert File.exist?("#{config}.bak")
      assert_includes File.read("#{config}.bak"), "original = true", "backup is the pristine pre-write file"
    end

    def test_installed_is_false_without_our_block
      refute CodexHook.installed?, "no config file"
      File.write(config, %(model = "x"\n))
      refute CodexHook.installed?, "config without our block"
    end

    # The #130 guard at RUNTIME, offline: a reporter command actually short-circuits
    # under a Claude-Code parent. Pins the sh precedence (`(A || B) && exit 0`,
    # equal-precedence/left-assoc) that the block content test can only see as text —
    # a refactor that broke it would still pass there but fail here.
    def state_files = Dir.glob(File.join(AgentState.state_dir, "*"))

    def run_guard(cmd, dir, env)
      system(env, "sh", "-c", cmd, chdir: dir, out: File::NULL, err: File::NULL)
    end

    def test_guard_suppresses_the_reporter_under_a_claude_parent
      script = HookFile.ensure_script
      cmd = HookFile.command_entries(CodexHook::EVENTS, script, "switchboard", guard: CodexHook::GUARD)
                    .find { |e| e[:event] == "PreToolUse" }[:command]
      dir = path("wt")
      FileUtils.mkdir_p(dir)

      # No Claude marker → the reporter fires and writes `thinking`.
      run_guard(cmd, dir, "CLAUDECODE" => nil, "CLAUDE_CODE_SESSION_ID" => nil)
      refute_empty state_files, "reporter fires with no Claude parent"
      assert_match(/\Athinking\t/, File.read(state_files.first))

      # CLAUDECODE set → suppressed (the first marker).
      File.delete(*state_files)
      run_guard(cmd, dir, "CLAUDECODE" => "1", "CLAUDE_CODE_SESSION_ID" => nil)
      assert_empty state_files, "guard suppresses under CLAUDECODE"

      # CLAUDE_CODE_SESSION_ID set → suppressed (the second marker).
      run_guard(cmd, dir, "CLAUDECODE" => nil, "CLAUDE_CODE_SESSION_ID" => "sess-1")
      assert_empty state_files, "the second marker also suppresses"
    end
  end
end
