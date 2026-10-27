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
      # Reported once, by the caller (Installer.report_codex_install — installer_test pins its
      # text), not a second, differently-worded line from here.
      assert_empty err
    end

    def test_install_aborts_on_a_foreign_hooks_dotted_key
      [%(hooks.managed_dir = "/x"\n), %('hooks' = {}\n)].each do |seed|
        File.write(config, seed)
        capture_io { assert_equal :collision, CodexHook.install_global, seed }
        refute_includes File.read(config), CodexHook::BEGIN_MARK
      end
    end

    # Value: protects=install never appends a second hooks table behind a root `hooks` key
    # that follows a multi-line array; fails_when=the root-key scan stops at an array element
    # that looks like a header (red-team inv2 pass 2, reproduced invalid TOML);
    # why_new=collision tests had no array before the key; seam=none
    def test_root_hooks_key_after_a_multiline_array_still_collides
      [%(x = [\n  ["a"]\n]\nhooks.PreToolUse = []\n), %(x = [\n["a"]\n]\nhooks = {}\n),
       %(x = [\n  [1]\n]\n"hooks" = {}\n),
       # A `[` inside multi-line prose doesn't hide a root key after it.
       %(s = """\n[\n"""\nhooks = {}\n),
       # An escaped quote before two more (`\"""`) doesn't end the string early, so a later
       # `"""` comment can't resync the scanner past a root hooks key (pass-3 red team).
       %(d = """\nQuote it like \\""" this.\n"""\nhooks.PreToolUse = []\n# end """\n[tui]\nx = 1\n),
       # Fail-closed rails: a bracket left open at EOF, and an unindented [hooks] while nested.
       %(x = [\n  1,\nhooks = {}\n), %(x = [\n[hooks]\n]\n),
       # A literal ''' string closes too, so a root key after it is still seen; and an open
       # bracket at EOF collides even when no `hooks` key appears at all.
       %(t = '''\n[\n'''\nhooks = {}\n), %(x = [\n  [tui]\n)].each do |seed|
        File.write(config, seed)
        capture_io { assert_equal :collision, CodexHook.install_global, seed }
        assert_equal seed, body, "left untouched"
      end
    end

    # The last element of a multi-line array (no trailing comma) is a value, not a table: it
    # must neither collide outside the block nor split a chunk inside it.
    def test_last_array_element_without_comma_is_not_a_header
      File.write(config, %([profiles]\nm = [\n  [1, 2],\n  ["hooks"]\n]\n))
      assert_equal config, CodexHook.install_global, "no false collision"
      File.write(config, %(model = "x"\n))
      block_with(%([profiles]\nm = [\n  [1, 2],\n  ["hooks"]\n]\n))
      assert_equal config, CodexHook.install_global
      assert_includes body.split(CodexHook::BEGIN_MARK).first, %(m = [\n  [1, 2],\n  ["hooks"]\n]\n), "array moved whole"
      block_with(%([profiles]\nm = [\n  [3]\n]\n))
      assert_equal true, CodexHook.remove_global
      assert_includes body, %([profiles]\nm = [\n  [3]\n]\n), "uninstall keeps the array whole too"
    end

    # Value: protects=install on a config whose multi-line prose holds an unbalanced bracket
    # (codex's developer_instructions); fails_when=brackets inside """ strings count toward
    # depth (pass-3 state-matrix: a permanent false :collision); why_new=no prior row had
    # brackets inside a multi-line string; seam=none
    def test_brackets_inside_multiline_prose_dont_block_install
      File.write(config, %{developer_instructions = """\nUse half-open [a, b) intervals.\n[hooks] is not a table here.\n"""\nnotes = '''\n[ [ ]\n'''\nmodel = "x"\n})
      before = body
      assert_equal config, CodexHook.install_global
      assert body.start_with?(before), "prose kept verbatim above the block"
      assert_equal true, CodexHook.remove_global
      assert_equal before, body
    end

    # Value: protects=install/uninstall on a config whose one-line strings or comments hold an
    # unbalanced bracket; fails_when=bare_code stops skipping "…"/'…' strings or # comments, so
    # the bracket counts toward depth and reads as open at EOF (a permanent false :collision);
    # why_new=only multi-line prose was tried, no row had a bracket in a one-line string or
    # comment; seam=none; no_claim=TOML validity of the user's file
    def test_brackets_inside_one_line_strings_and_comments_dont_block_install
      File.write(config, %([tui]\nprompt = "pick [one"\nlabel = 'x ['\n# a [ comment\n[profiles.work]\nmodel = "y"\n))
      before = body
      assert_equal config, CodexHook.install_global
      assert body.start_with?(before), "strings and comment kept verbatim above the block"
      assert_equal true, CodexHook.remove_global
      assert_equal before, body
    end

    # A stray end marker with no begin marker (hand-edited): refuse rather than misread it.
    def test_refuses_an_orphan_end_marker
      File.write(config, %([a]\nx = 1\n#{CodexHook::END_MARK}\n))
      before = body
      capture_io { assert_equal :unsafe, CodexHook.install_global }
      assert_equal false, CodexHook.remove_global
      assert_equal before, body
    end

    # A `hooks` key under some OTHER table is that table's key, not a hooks config — a false
    # :collision here never clears (red-team pass 2).
    def test_a_hooks_key_inside_another_table_does_not_collide
      File.write(config, %([profiles.work]\nhooks = "x"\n))
      assert_equal config, CodexHook.install_global
    end

    # Inside the block, a single-quoted `['hooks']` is still OUR table name — classifying it
    # foreign would move it above and leave two [hooks] tables (invalid TOML).
    def test_single_quoted_hooks_table_inside_the_block_is_not_moved_out
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      File.write(config, body.sub("\n[hooks]\n", "\n['hooks']\n"))
      assert_equal config, CodexHook.install_global
      assert_equal 1, body.scan(/^\[\s*(?:hooks|"hooks"|'hooks')\s*\]/).size, "exactly one hooks table"
    end

    # The collision guard must catch EVERY TOML spelling of a `hooks` table — a
    # whitespace-padded, quoted, or array-of-tables form codex still reads as `hooks`.
    # Missing one → we'd append our own `[hooks]` → two tables → the user's config stops
    # parsing. (`[ hooks ]`, `["hooks"]`, `[[hooks]]` all slipped past the first regex.)
    def test_install_aborts_on_alternate_hooks_table_spellings
      ["[ hooks ]", %(["hooks"]), "['hooks']", "['hooks'.PreToolUse]", "[[hooks]]", "[[hooks.state]]",
       "[hooks.state_x]", %([hooks."state_x"])].each do |header|
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

    # Value: protects=a codex write landing right after ours survives; fails_when=install
    # goes back to restoring its snapshot on a read-back mismatch (erasing codex's newer
    # save); why_new=the old test pinned that restore as torn-write recovery, but
    # temp+rename can't tear, so a mismatch means someone else wrote; seam=none
    def test_install_never_restores_over_a_write_that_lands_after_ours
      File.write(config, %(model = "gpt-5.5"\n))
      codex_wins = ->(p, c) { File.write(MarkerBlock.real_target(p), "#{c}[desktop]\nx = 1\n") }
      stub_method(MarkerBlock, :atomic_write, codex_wins) do
        assert_equal :conflict, CodexHook.install_global
      end
      assert_includes body, "[desktop]", "codex's newer write is left in place"
      # Uninstall's read-back must flag the same race, never report a clean removal.
      stub_method(MarkerBlock, :atomic_write, codex_wins) do
        assert_equal :conflict, CodexHook.remove_global
      end
      assert_includes body, "[desktop]"
    end

    # Value: protects=a codex save between our read and our write isn't overwritten;
    # fails_when=install writes without re-checking the file; why_new=nothing re-read the
    # file before writing; seam=none
    def test_install_aborts_when_the_config_changes_before_the_write
      File.write(config, %(model = "gpt-5.5"\n))
      real = CodexHook.method(:toml_hooks)
      cfg = config # the stub runs with CodexHook as self
      sneaky = lambda do |*args|
        File.write(cfg, %(model = "gpt-5.5"\n[plugins."new@x"]\nenabled = true\n)) # codex saves mid-install
        real.call(*args)
      end
      stub_method(CodexHook, :toml_hooks, sneaky) do
        assert_equal :conflict, CodexHook.install_global
      end
      assert_equal %(model = "gpt-5.5"\n[plugins."new@x"]\nenabled = true\n), body, "codex's save untouched"
      refute CodexHook.installed?
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
      refute CodexHook.remove_global
      File.write(config, %(model = "x"\n))
      refute CodexHook.remove_global, "no block ⇒ nothing removed"
      assert_equal %(model = "x"\n), body
    end

    # What codex appends after our [hooks] table once the user runs `/hooks` (trimmed). Its
    # keys name THIS config file, as real codex approvals of our block do.
    def trust
      <<~TOML
        [hooks.state]

        [hooks.state."#{config}:pre_tool_use:0:0"]
        trusted_hash = "sha256:aaaa"

        [hooks.state."#{config}:session_start:0:0"]
        trusted_hash = "sha256:bbbb"
      TOML
    end

    # A block as older releases wrote it: note on the begin line, single-quoted
    # commands, and codex's trust tables inside the markers.
    def legacy_block
      "#{CodexHook::BEGIN_MARK} (managed by switchboard; remove this block to disable)\n" \
        "[hooks]\nStop = [{ hooks = [{ type = \"command\", command = '/old/sb-agent-hook done' }] }]\n" \
        "#{trust}#{CodexHook::END_MARK}\n"
    end

    # Value: protects=uninstall actually removing a block an older release wrote;
    # fails_when=strip needs the bare begin mark again (the block survives while uninstall
    # says ✓) or remove_global reports success without a change; why_new=the strip test
    # above uses a block the current release wrote; seam=none
    def test_remove_global_strips_a_legacy_block
      File.write(config, %(model = "x"\n#{legacy_block}[tui]\ntheme = "dark"\n))
      assert CodexHook.remove_global
      refute CodexHook.installed?
      assert_equal %(model = "x"\n[tui]\ntheme = "dark"\n), body, "the whole block goes, foreign config stays"
    end

    # Value: protects=re-installing over an older block (the brew-upgrade path) without a
    # false collision, while keeping the user's codex trust; fails_when=the stale block's
    # [hooks] reads as foreign (install refuses, codex dots go dark) or codex's trust tables
    # are dropped; why_new=no test installs over a block in the old format; seam=none
    def test_install_replaces_a_legacy_block_and_keeps_codex_trust
      File.write(config, %(model = "x"\n#{legacy_block}))
      assert_equal :stale, CodexHook.block_state, "doctor reads the older marker form, and its old commands"
      assert_equal config, CodexHook.install_global
      assert_equal 1, body.scan(/^\[hooks\]/).size
      assert_match(/^#{Regexp.escape(CodexHook::BEGIN_MARK)}\n/, body, "rewritten with the current marker")
      refute_includes body, "/old/sb-agent-hook", "the stale commands are gone"
      assert_includes body[MarkerBlock.region(CodexHook::BEGIN_MARK, CodexHook::END_MARK), 1], trust.strip
    end

    # Value: protects=codex's /hooks approval surviving `switchboard install` (re-run after
    # every upgrade); fails_when=install_global stops carrying the [hooks.state…] tables
    # codex wrote inside our markers, forcing a re-approval every upgrade; why_new=the
    # idempotency test re-installs a block codex never touched; seam=none
    def test_install_carries_codex_trust_across_reinstall_and_uninstall_drops_it
      CodexHook.install_global
      File.write(config, body.sub(CodexHook::END_MARK, "\n#{trust}#{CodexHook::END_MARK}")) # codex trusts the hooks
      CodexHook.install_global
      CodexHook.install_global
      assert_equal 1, body.scan(%(:pre_tool_use:0:0"])).size, "trust kept once, not stacked"
      assert_includes body[MarkerBlock.region(CodexHook::BEGIN_MARK, CodexHook::END_MARK), 1], trust.strip
      CodexHook.remove_global
      refute_includes body, "hooks.state", "uninstall removes the trust for hooks it removed"
    end

    def test_install_writes_a_first_write_backup
      File.write(config, %(original = true\n))
      CodexHook.install_global
      assert File.exist?("#{config}.bak")
      assert_includes File.read("#{config}.bak"), "original = true", "backup is the pristine pre-write file"
    end

    # What codex (toml_edit) appends after the last table, i.e. inside an EOF block:
    # trimmed from a real ~/.codex/config.toml.
    FOREIGN = <<~TOML
      [desktop]
      theme = "system"

      [plugins."sites@openai-bundled"]
      enabled = true
    TOML

    def block_with(extra)
      CodexHook.install_global
      File.write(config, body.sub(CodexHook::END_MARK, "\n#{extra}#{CodexHook::END_MARK}"))
    end

    def region = body[MarkerBlock.region(CodexHook::BEGIN_MARK, CodexHook::END_MARK), 1]

    # Value: protects=the user's codex plugin/desktop config surviving `switchboard install`;
    # fails_when=install drops non-trust tables inside the block again (the v0.50.1 bug);
    # why_new=the trust-carry test only has [hooks.state] tables inside; seam=none
    def test_install_moves_codex_tables_above_the_block_and_keeps_trust_inside
      File.write(config, %(model = "x"\n))
      block_with("#{trust}\n#{FOREIGN}")
      assert_equal config, CodexHook.install_global
      above = body.split(CodexHook::BEGIN_MARK).first
      assert_includes above, FOREIGN, "codex's tables moved above the block, byte-for-byte"
      refute_includes region, "[desktop]"
      assert_includes region, trust.strip, "trust stays inside"
      assert body.rstrip.end_with?(CodexHook::END_MARK), "the block stays last"
      once = body
      CodexHook.install_global
      assert_equal once, body, "re-install is idempotent"
    end

    # A config codex never wrote into must rewrite exactly as before, or every user's
    # /hooks approval (hash-keyed on our commands) would need redoing.
    def test_install_without_foreign_tables_writes_the_same_bytes_as_before
      File.write(config, %(model = "x"\n))
      block_with(trust)
      before = body
      script = HookFile.ensure_script
      inner = "#{CodexHook::NOTE_MARK}\n[hooks]\n#{CodexHook.toml_hooks(script, ENV['SWITCHBOARD_BIN'] || 'switchboard')}\n\n#{trust.strip}"
      CodexHook.install_global
      assert_equal MarkerBlock.build(MarkerBlock.strip(before, CodexHook::BEGIN_MARK, CodexHook::END_MARK),
                                     CodexHook::BEGIN_MARK, CodexHook::END_MARK, inner), body
    end

    # After the move, a later /hooks approval (codex writes [hooks.state…] right after
    # [hooks]) still lands inside the block, so the next install carries it.
    def test_trust_written_after_a_move_is_carried
      File.write(config, %(model = "x"\n))
      block_with(FOREIGN)
      CodexHook.install_global
      File.write(config, body.sub(CodexHook::END_MARK, "\n#{trust}#{CodexHook::END_MARK}"))
      assert_equal config, CodexHook.install_global, "no false collision"
      assert_includes region, trust.strip
    end

    # Value: protects=install over a config whose text outside the block ends without a
    # newline (a trailing comment after `# <<<`); fails_when=the conservation check joins
    # the kept pieces without with_foreign's separator, fusing the comment and the next
    # header into one line and falsely refusing (:unsafe) a layout main installs fine;
    # why_new=every fixture ended in a newline; seam=none.
    # Regression proof — fails at HEAD: yes (:unsafe) · passes at base: yes · passes after fix: yes
    def test_install_moves_tables_when_a_trailing_comment_lacks_a_newline
      File.write(config, %(model = "x"\n))
      block_with("#{trust}\n#{FOREIGN}")
      File.write(config, "#{body}# my trailing note") # no final newline
      assert_equal config, CodexHook.install_global
      above = body.split(CodexHook::BEGIN_MARK).first
      assert_includes above, "# my trailing note\n[desktop]\n", "comment kept, codex tables moved after it"
      assert_includes body[MarkerBlock.region(CodexHook::BEGIN_MARK, CodexHook::END_MARK), 1], trust.strip
      # Uninstall rides the same separator: the comment stays, codex's table on its own line.
      block_with(FOREIGN)
      File.write(config, "#{body}# my trailing note")
      assert_equal true, CodexHook.remove_global
      assert_includes body, "# my trailing note\n[desktop]\n"
      refute_includes body, CodexHook::BEGIN_MARK
    end

    # Value: protects=the upgrade every existing user runs — the exact block v0.50.1 wrote (its
    # note on its own line inside the markers) plus trust and a codex table codex appended;
    # fails_when=a tightened preamble/OUR_LINE rule starts refusing it as :unsafe; why_new=every
    # other fixture is written by the current code; seam=none; no_claim=real /hooks hashes
    def test_install_upgrades_the_block_v0_50_1_wrote
      old_note = "# managed by switchboard — edits between the markers are overwritten; delete the block to disable"
      File.write(config, %(model = "x"\n#{CodexHook::BEGIN_MARK}\n#{old_note}\n[hooks]\n) +
                         %(Stop = [{ hooks = [{ type = "command", command = "/old done" }] }]\n\n#{trust}\n#{FOREIGN}#{CodexHook::END_MARK}\n))
      assert_equal config, CodexHook.install_global
      refute_includes body, old_note
      assert_includes region, CodexHook::NOTE_MARK
      assert_includes region, trust.strip
      assert_includes body.split(CodexHook::BEGIN_MARK).first, FOREIGN
      assert_equal true, CodexHook.remove_global
      assert_includes body, FOREIGN
    end

    # Value: protects=a codex table whose header carries a trailing comment (`[desktop] # mine`)
    # surviving install + uninstall; fails_when=HEADER stops accepting a trailing comment, so
    # the table folds into the trust chunk above it and uninstall deletes it with our trust
    # (conserved? can't see it: the line is dropped from both sides); why_new=every fixture
    # header was bare; seam=none; no_claim=codex itself writing such a header (hand edit)
    def test_a_commented_table_header_inside_the_block_is_moved_not_dropped
      commented = %([desktop] # mine\ntheme = "system"\n)
      File.write(config, %(model = "x"\n))
      block_with("#{trust}\n#{commented}")
      assert_equal config, CodexHook.install_global
      assert_includes body.split(CodexHook::BEGIN_MARK).first, commented, "moved above the block"
      refute_includes region, "[desktop]"
      block_with("#{trust}\n#{commented}") # codex appends it inside again; uninstall must keep it
      assert_equal true, CodexHook.remove_global
      assert_includes body, commented, "uninstall keeps it"
      refute_includes body, "hooks.state"
    end

    def test_uninstall_keeps_codex_tables_found_inside_the_block
      File.write(config, %(model = "x"\n))
      block_with("#{trust}\n#{FOREIGN}")
      assert_equal true, CodexHook.remove_global
      assert_equal %(model = "x"\n#{FOREIGN}), body, "ours + trust gone, codex's tables kept"
    end

    # Value: protects=install never writes TOML whose meaning it changed or broke;
    # fails_when=a refusal rail is dropped; why_new=no splitter existed; seam=none
    def test_install_and_uninstall_refuse_unsafe_layouts
      unsafe = {
        "multi-line basic string" => %([notes]\ntext = """\n[not.a.header]\n"""\n),
        "multi-line literal string" => %([notes]\ntext = '''\nx\n'''\n),
        "array of tables" => %([[profiles]]\nname = "a"\n)
      }
      unsafe.each do |label, extra|
        File.write(config, %(model = "x"\n))
        block_with(extra)
        before = body
        capture_io do
          assert_equal :unsafe, CodexHook.install_global, label
          assert_equal :unsafe, CodexHook.remove_global, label
        end
        assert_equal before, body, "#{label}: untouched"
      end
    end

    def test_refuses_keys_right_after_the_end_marker
      File.write(config, %(model = "x"\n))
      block_with(FOREIGN)
      File.write(config, "#{body}stray = 1\n") # belongs to [plugins."sites…"] inside the block
      before = body
      capture_io do
        assert_equal :unsafe, CodexHook.install_global
        assert_equal :unsafe, CodexHook.remove_global
      end
      assert_equal before, body
    end

    def test_refuses_keys_before_the_first_table_in_the_block
      File.write(config, %(model = "x"\n[tui]\n))
      CodexHook.install_global
      File.write(config, body.sub("#{CodexHook::NOTE_MARK}\n", "#{CodexHook::NOTE_MARK}\ntheme = \"dark\"\n"))
      before = body
      capture_io do # theme belongs to [tui] above
        assert_equal :unsafe, CodexHook.install_global
        assert_equal :unsafe, CodexHook.remove_global
      end
      assert_equal before, body
    end

    # The conservation belt: if the splitter ever drops a line, the write aborts.
    def test_install_aborts_if_a_kept_line_would_be_lost
      File.write(config, %(model = "x"\n))
      block_with(FOREIGN)
      before = body
      lossy = ->(outside, _foreign) { outside } # a splitter bug that forgets codex's tables
      stub_method(CodexHook, :with_foreign, lossy) do
        capture_io { assert_equal :unsafe, CodexHook.install_global }
        # Doctor runs install's plan, belt included: it must not call this block current.
        assert_equal :unsafe, CodexHook.block_state
        # Uninstall has its own belt: a lossy split there must refuse too, file untouched.
        capture_io { assert_equal :unsafe, CodexHook.remove_global }
      end
      assert_equal before, body
    end

    # --- trust_status -----------------------------------------------------------

    def trust_tables(keys, path: config)
      keys.map { |k| %([hooks.state."#{path}:#{k}"]\ntrusted_hash = "sha256:x"\n) }.join("\n")
    end

    def test_trust_status_counts_our_approved_hooks
      CodexHook.install_global
      all = CodexHook.expected_trust_keys
      assert_equal [0, all.size], CodexHook.trust_status, "nothing approved"
      block_with(trust_tables(all.first(2)))
      assert_equal [2, all.size], CodexHook.trust_status, "partial"
      CodexHook.install_global
      block_with(trust_tables(all))
      assert_equal [all.size, all.size], CodexHook.trust_status, "all approved"
    end

    # Value: protects=a reinstall from another checkout (a changed bin path) keeping every approval,
    # its `enabled = false` included, so switching back needs no new /hooks review and a disabled hook
    # stays off; fails_when=install drops the approvals of changed commands again (they were lost for
    # good across a round trip, and a disable vanished); why_new=the drop was removed (inv7 D1, user);
    # seam=none; no_claim=codex re-asking for the changed commands (its hash check)
    def test_reinstall_from_another_checkout_keeps_every_approval_and_disable
      CodexHook.install_global
      stop = CodexHook.expected_trust_keys.find { |k| k.start_with?("stop") }
      block_with(trust_tables(CodexHook.expected_trust_keys - [stop]) +
                 %(\n[hooks.state."#{config}:#{stop}"]\nenabled = false\ntrusted_hash = "sha256:x"\n))
      approvals = body[MarkerBlock.region(CodexHook::BEGIN_MARK, CodexHook::END_MARK), 1][/\[hooks\.state.*/m]
      ENV["SWITCHBOARD_BIN"], was = "/elsewhere/bin/switchboard", ENV["SWITCHBOARD_BIN"]
      assert_equal config, CodexHook.install_global
      assert_includes region, approvals.strip, "every approval carried, the disable too"
      ENV["SWITCHBOARD_BIN"] = was
      assert_equal config, CodexHook.install_global
      assert_includes region, approvals.strip, "back on the original checkout: nothing to re-approve"
    ensure
      ENV["SWITCHBOARD_BIN"] = was if defined?(was)
    end
    
    # Value: protects=our approvals codex filed OUTSIDE the block (after a table hand-added below
    # it): kept on reinstall, all ours dropped on uninstall (a comment above the next table stays),
    # other files' and the user's table kept; fails_when=uninstall filters only the block's own trust
    # chunks (dead approvals left behind) or eats the next table's comment; why_new=every
    # trust fixture sat inside the block (red-team inv5 pass 3); seam=none; no_claim=toml_edit's placement
    def test_approvals_filed_below_the_block_are_kept_then_removed_with_ours
      CodexHook.install_global
      mine = %([profiles.fast]\nmodel = "o4"\n)
      other = %([hooks.state."/p/.codex/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:cccc"\n)
      note = "# ---- work profile: keep in sync with the wiki ----\n"
      work = %([profiles.work]\nmodel = "o5"\n)
      File.write(config, "#{body}#{mine}\n#{trust_tables(CodexHook.expected_trust_keys)}\n#{note}#{work}\n#{other}")
      assert_equal CodexHook.expected_trust_keys.size, CodexHook.trust_status.first, "approvals below the block count"
      ENV["SWITCHBOARD_BIN"], was = "/elsewhere/bin/switchboard", ENV["SWITCHBOARD_BIN"]
      assert_equal config, CodexHook.install_global
      assert_equal :current, CodexHook.block_state
      assert_includes body, "#{note}#{work}"
      assert_equal CodexHook.expected_trust_keys.size, CodexHook.trust_status.first, "a reinstall leaves them where codex put them"
      assert_includes body, mine
      assert_equal true, CodexHook.remove_global
      refute_includes body, %(#{config}:), "uninstall drops our approvals wherever they sit"
      assert_includes body, "#{note}#{work}"
      assert_includes body, other.strip
      assert_includes body, mine
    ensure
      ENV["SWITCHBOARD_BIN"] = was if defined?(was)
    end

    # Value: protects=a bare [hooks.state] header holding keys of its own surviving a reinstall,
    # not just uninstall; fails_when=install's trust filter starts dropping bare parents the way
    # our_trust? drops key-less ones; why_new=only the uninstall side was pinned; seam=none
    def test_reinstall_keeps_keys_under_a_bare_hooks_state_header
      block_with(%([hooks.state]\nversion = 2\n))
      assert_equal config, CodexHook.install_global
      assert_includes region, %([hooks.state]\nversion = 2\n)
    end

    def test_trust_status_ignores_other_files_disabled_and_unknown_keys
      CodexHook.install_global
      key = CodexHook.expected_trust_keys.first
      block_with(trust_tables([key], path: "/elsewhere/config.toml") +
                 %(\n[hooks.state."#{config}:#{key}"]\nenabled = false\ntrusted_hash = "sha256:x"\n) +
                 %(\n[hooks.state."#{config}:#{CodexHook.expected_trust_keys[1]}"]\nenabled = true\n) + # no hash: never approved
                 trust_tables(["session_start:99:0"]))
      assert_equal 0, CodexHook.trust_status.first
    end

    # Codex may spell the key's path through a symlinked CODEX_HOME.
    def test_trust_status_matches_the_config_by_realpath
      link = path("codexlink")
      File.symlink(@home, link)
      ENV["CODEX_HOME"] = link
      CodexHook.install_global
      key = CodexHook.expected_trust_keys.first
      block_with(trust_tables([key], path: File.join(File.realpath(@home), "config.toml")))
      assert_equal 1, CodexHook.trust_status.first
    end

    # Value: protects=doctor's N/M counting the groups the block ACTUALLY emits;
    # fails_when=toml_hooks folds an event's entries into one group (keys become :0:1) or
    # the event snake-casing drifts, so doctor warns "untrusted" forever after /hooks;
    # why_new=the trust_status tests build their tables FROM expected_trust_keys, so they
    # can't see it disagree with the block; seam=none; no_claim=that real codex numbers
    # groups this way (headless codex can't approve hooks — the trust fixture is the evidence)
    def test_expected_trust_keys_match_the_emitted_groups
      emitted = CodexHook.toml_hooks(HookFile.ensure_script, "switchboard").lines.flat_map do |line|
        event, groups = line.split(" = ", 2)
        snake = { "UserPromptSubmit" => "user_prompt_submit", "PreToolUse" => "pre_tool_use",
                  "PostToolUse" => "post_tool_use", "PermissionRequest" => "permission_request",
                  "SessionStart" => "session_start", "Stop" => "stop", "SessionEnd" => "session_end" }.fetch(event)
        groups.scan(/hooks = \[(.*?)\] \}/).each_with_index.flat_map do |(handlers), g|
          handlers.scan(/\{ type = "command"/).each_index.map { |h| "#{snake}:#{g}:#{h}" }
        end
      end
      assert_equal emitted.sort, CodexHook.expected_trust_keys.sort
    end

    # Value: protects=a codex save racing `switchboard uninstall` survives; fails_when=
    # remove_global goes back to a blind atomic_write (or reports true on a conflict);
    # why_new=the conflict tests cover install only, and the installer test stubs
    # remove_global; seam=none; no_claim=a write in the last instant before rename
    def test_uninstall_aborts_when_the_config_changes_before_the_write
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      raced = "#{body}[plugins.\"new@x\"]\nenabled = true\n"
      real = CodexHook.method(:with_foreign)
      cfg = config
      sneaky = lambda do |*args|
        File.write(cfg, raced) # codex saves mid-uninstall
        real.call(*args)
      end
      stub_method(CodexHook, :with_foreign, sneaky) do
        assert_equal :conflict, CodexHook.remove_global
      end
      assert_equal raced, body, "codex's save untouched, block left for a re-run"
    end

    # Value: protects=install never clobbers a config codex creates while we work;
    # fails_when=the fresh-file case compares against "" instead of "no file" (or skips the
    # re-check), writing over codex's first save; why_new=the conflict test above starts
    # from an existing config; seam=none; no_claim=same last-instant window
    def test_install_aborts_when_codex_creates_the_config_mid_install
      refute File.exist?(config)
      real = CodexHook.method(:toml_hooks)
      cfg = config
      sneaky = lambda do |*args|
        File.write(cfg, "") # codex materializes an empty config.toml
        real.call(*args)
      end
      stub_method(CodexHook, :toml_hooks, sneaky) do
        assert_equal :conflict, CodexHook.install_global
      end
      assert_equal "", body
      refute CodexHook.installed?
    end

    # Value: protects=codex's tables surviving when our block is the WHOLE file (codex
    # wrote nothing else, then appended inside it); fails_when=the empty-`outside` join
    # drops or mangles them, or re-install / uninstall aren't stable on that layout;
    # why_new=every move test seeds a key above the block; seam=none; no_claim=TOML validity
    # beyond line conservation
    def test_install_and_uninstall_move_tables_when_the_block_is_the_whole_file
      block_with(FOREIGN)
      assert_equal config, CodexHook.install_global
      assert body.start_with?(FOREIGN), "codex's tables now open the file"
      assert body.rstrip.end_with?(CodexHook::END_MARK)
      once = body
      CodexHook.install_global
      assert_equal once, body, "idempotent"
      assert_equal true, CodexHook.remove_global
      assert_equal FOREIGN, body
    end

    # Value: protects=every user's codex /hooks approval across upgrades (codex hashes the
    # command BYTES); fails_when=GUARD, command_entries order, event spelling or escaping
    # drifts; why_new=the byte-identical test compares to live toml_hooks, so it can't see
    # the commands themselves change; seam=none; no_claim=codex's hash function itself.
    # Update this golden ONLY on purpose, with a CHANGELOG note that users must re-approve.
    GOLDEN_TOML_HOOKS = <<~'TOML'
      UserPromptSubmit = [{ hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; /s/sb-agent-hook thinking" }] }]
      PreToolUse = [{ matcher = "*", hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; /s/sb-agent-hook thinking" }] }]
      PostToolUse = [{ matcher = "*", hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; /s/sb-agent-hook thinking" }] }]
      PermissionRequest = [{ matcher = "*", hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; /s/sb-agent-hook waiting" }] }]
      SessionStart = [{ hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; /s/sb-agent-hook done" }] }, { hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; command -v /b/switchboard >/dev/null 2>&1 && /b/switchboard rename-nudge || true" }] }, { hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; command -v /b/switchboard >/dev/null 2>&1 && /b/switchboard monitoring-nudge || true" }] }]
      Stop = [{ hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; if command -v /b/switchboard >/dev/null 2>&1; then /b/switchboard rename-nudge --stop; else /s/sb-agent-hook done; fi" }] }]
      SessionEnd = [{ hooks = [{ type = "command", command = "[ -n \"$CLAUDECODE\" ] || [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && exit 0; command -v /b/switchboard >/dev/null 2>&1 && /b/switchboard monitoring-nudge --end || true" }] }]
      TOML

    def test_codex_command_bytes_are_frozen_for_trust_stability
      assert_equal GOLDEN_TOML_HOOKS, "#{CodexHook.toml_hooks("/s/sb-agent-hook", "/b/switchboard")}\n",
                   "codex command bytes changed: every user's /hooks approval is voided"
    end

    # The Claude-only SessionEnd timeout must never leak into the codex block (it would
    # re-hash that command and void its approval).
    def test_codex_block_carries_no_timeout_key
      CodexHook.install_global
      refute_match(/\btimeout\s*=/, region)
    end

    def test_install_returns_nil_and_leaves_the_file_when_the_write_raises
      File.write(config, %(model = "x"\n))
      stub_method(MarkerBlock, :atomic_write, ->(*) { raise IOError, "disk full" }) do
        assert_nil CodexHook.install_global
      end
      assert_equal %(model = "x"\n), body
    end

    # Value: protects=a key codex (or the user) put inside our [hooks] table, or a
    # [hooks.<x>] table, survives install/uninstall; fails_when=our chunk is regenerated
    # without checking it holds only our lines (red-team RT1); why_new=conservation only
    # compared the splitter's own output; seam=none
    def test_refuses_lines_in_our_chunk_that_we_did_not_write
      ["managed_dir = \"/x\"\n", "[hooks.PreToolUse]\ncommand = \"x\"\n"].each do |extra|
        File.write(config, %(model = "x"\n))
        CodexHook.install_global
        File.write(config, body.sub("\n[hooks]\n", "\n[hooks]\n#{extra}"))
        before = body
        capture_io do
          assert_equal :unsafe, CodexHook.install_global, extra
          assert_equal :unsafe, CodexHook.remove_global, extra
        end
        assert_equal before, body, extra
      end
    end

    # A `[`-led line inside a multi-line array is not a table header (red-team RT1).
    def test_array_continuation_lines_are_not_split_as_headers
      File.write(config, %(model = "x"\n))
      block_with(%([profiles]\nmatrix = [\n  [1, 2],\n  ["hooks"],\n]\n))
      assert_equal config, CodexHook.install_global
      above = body.split(CodexHook::BEGIN_MARK).first
      assert_includes above, %(matrix = [\n  [1, 2],\n  ["hooks"],\n]\n), "the array moved whole"
    end

    # Two switchboard blocks: strip drops both, so splitting only the first would lose
    # the second one's codex tables (red-team RT2).
    def test_refuses_a_file_with_two_switchboard_blocks
      File.write(config, %(model = "x"\n))
      block_with(FOREIGN)
      File.write(config, "#{body}#{CodexHook::BEGIN_MARK}\n[desktop]\nkeep = 1\n#{CodexHook::END_MARK}\n")
      before = body
      capture_io do
        assert_equal :unsafe, CodexHook.install_global
        assert_equal :unsafe, CodexHook.remove_global
      end
      assert_equal before, body
    end

    # Value: protects=uninstall leaves codex's approvals for OTHER hook files (a project
    # .codex/hooks.json, plugins) that codex filed inside our block; fails_when=remove_global
    # drops every [hooks.state] chunk again (red-team RT3); why_new=fixtures only had ours;
    # seam=none
    def test_uninstall_keeps_trust_for_other_hook_files
      other = %([hooks.state."/p/.codex/hooks.json:pre_tool_use:0:0"]\ntrusted_hash = "sha256:cccc"\n)
      File.write(config, %(model = "x"\n))
      block_with("#{trust}\n#{other}")
      assert_equal config, CodexHook.install_global
      assert_includes body[MarkerBlock.region(CodexHook::BEGIN_MARK, CodexHook::END_MARK), 1], other.strip,
                      "install carries another file's approval like ours"
      assert_equal true, CodexHook.remove_global
      assert_includes body, other, "another file's approval kept"
      refute_includes body, "#{config}:pre_tool_use", "our approvals went with our hooks"
    end

    def test_remove_global_returns_false_and_leaves_the_file_when_the_write_raises
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      before = body
      stub_method(MarkerBlock, :atomic_write, ->(*) { raise IOError, "read-only" }) do
        assert_equal false, CodexHook.remove_global
      end
      assert_equal before, body
    end

    def test_uninstall_removes_a_single_quoted_hooks_table_with_the_block
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      File.write(config, body.sub("\n[hooks]\n", "\n['hooks']\n"))
      assert_equal true, CodexHook.remove_global
      assert_equal %(model = "x"\n), body
    end

    # Approvals for another hook file OUTSIDE our block are codex's, not a competing hooks
    # config (red-team RT4): install proceeds, and there's still exactly one [hooks] table.
    def test_install_is_not_blocked_by_codex_trust_outside_the_block
      [%([hooks.state."/p/.codex/hooks.json:stop:0:0"]), %([hooks."state"."/p:stop:0:0"]),
       %([hooks.'state'."/p:stop:0:0"]), "[hooks.state]"].each do |header|
        File.write(config, %(model = "x"\n#{header}\ntrusted_hash = "sha256:dddd"\n))
        assert_equal config, CodexHook.install_global, header
        assert_equal 1, body.scan(/^\[hooks\]/).size, header
        assert_equal true, CodexHook.remove_global, header
        assert_includes body, header, "uninstall keeps another file's approvals"
        refute_includes body, CodexHook::BEGIN_MARK
      end
    end

    # A stray lone marker beside a valid block (a hand edit, or a half-pasted old block):
    # movable_parts counts marker lines, so pin that it refuses on both verbs.
    def test_refuses_a_stray_marker_beside_a_valid_block
      [CodexHook::BEGIN_MARK, CodexHook::END_MARK].each do |stray|
        File.write(config, %(model = "x"\n))
        CodexHook.install_global
        File.write(config, stray == CodexHook::BEGIN_MARK ? "#{stray}\n#{body}" : "#{body}#{stray}\n")
        before = body
        capture_io { assert_equal :unsafe, CodexHook.install_global, stray }
        capture_io { assert_equal :unsafe, CodexHook.remove_global, stray }
        assert_equal before, body
      end
      # A lone BEGIN after the block (only a comment follows it, so nothing else trips) is
      # refused by the marker count alone — pin it so that rule can't quietly regress.
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      File.write(config, "#{body}#{CodexHook::BEGIN_MARK}\n")
      before = body
      assert_equal :unsafe, CodexHook.install_global
      assert_equal :unsafe, CodexHook.remove_global
      assert_equal before, body
    end

    # Value: protects=doctor's codex advice matching reality — trust advice only for a block
    # install would write as-is; fails_when=a stale (older release / other checkout) or
    # unrewritable block still gets "run /hooks" (red-team inv3 pass 2); why_new=doctor only
    # counted trust keys; seam=none; no_claim=codex's own hash check
    def test_block_state_tells_current_from_stale_and_unsafe
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      assert_equal :current, CodexHook.block_state
      # Value: protects=doctor staying quiet after codex files approvals / its own tables inside
      # our block (it does on every /hooks approval and app save); fails_when=block_state compares
      # the whole region instead of just our [hooks] chunk, telling every trusted user to
      # reinstall; why_new=the rows here only had our own lines inside; seam=none;
      # no_claim=codex's real table layout (hand-written fixture). The `Args = [...]` key has
      # our `<Event> = [...]` shape, so only the chunk split (not the line filter) skips it.
      before = body
      block_with("#{trust}\n#{FOREIGN}\n[mcp_servers.x]\nArgs = [\"a\"]\n")
      assert_equal :current, CodexHook.block_state, "codex's trust + tables inside the block aren't drift"
      File.write(config, body.sub(/^#{Regexp.escape(CodexHook::END_MARK)}\n/, ""))
      assert_equal :unsafe, CodexHook.block_state, "a begin marker without its end: install would refuse"
      File.write(config, before)
      File.write(config, body.sub(/^Stop = .*$/,%(Stop = [{ hooks = [{ type = "command", command = "/old done" }] }])))
      assert_equal :stale, CodexHook.block_state
      File.write(config, body.sub("[hooks]\n", "[hooks]\nmine = 1\n"))
      assert_equal :unsafe, CodexHook.block_state, "a user key inside our [hooks]: install would refuse"
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      File.write(config, %([hooks]\nStop = []\n) + body)
      capture_io { assert_equal :collision, CodexHook.install_global }
      assert_equal :collision, CodexHook.block_state, "doctor must match install's diagnosis"
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      ENV["SWITCHBOARD_BIN"], was = "/elsewhere/bin/switchboard", ENV["SWITCHBOARD_BIN"]
      assert_equal :stale, CodexHook.block_state, "another checkout's bin path"
    ensure
      ENV["SWITCHBOARD_BIN"] = was if defined?(was)
    end

    # Value: protects=doctor never calling a block current that install refuses, for every
    # refusal install has; fails_when=block_state re-implements install's checks and one drifts
    # (it once skipped the conservation belt — state-machines inv4); why_new=the refusal tests
    # pin install/remove only; seam=none; no_claim=codex's own layouts (hand-written fixtures)
    def test_block_state_agrees_with_install_on_every_refusal
      layouts = {
        "multi-line string" => -> { block_with(%([notes]\ntext = """\nx\n"""\n)) },
        "array of tables" => -> { block_with(%([[profiles]]\nname = "a"\n)) },
        "keys after the end marker" => -> { block_with(FOREIGN); File.write(config, "#{body}stray = 1\n") },
        "keys before the first table" => -> {
          CodexHook.install_global
          File.write(config, body.sub("#{CodexHook::NOTE_MARK}\n", "#{CodexHook::NOTE_MARK}\ntheme = \"dark\"\n"))
        },
        "duplicated block" => -> { CodexHook.install_global; File.write(config, body + body) },
        "stray end marker" => -> { CodexHook.install_global; File.write(config, "#{body}#{CodexHook::END_MARK}\n") }
      }
      layouts.each do |label, setup|
        File.write(config, %(model = "x"\n))
        setup.call
        capture_io { assert_equal :unsafe, CodexHook.install_global, label }
        assert_equal :unsafe, CodexHook.block_state, label
      end
    end

    # Value: protects=a kept line that equals one of ours (the note line pasted elsewhere)
    # surviving install, with doctor agreeing; fails_when=conserved? discounts every copy of a
    # generated line (Array#-), so install refuses a harmless file while doctor says current;
    # why_new=QA inv4 probe 002; seam=none; no_claim=none beyond protects
    def test_a_copy_of_our_note_line_outside_the_block_is_kept
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      File.write(config, "[tui]\n#{CodexHook::NOTE_MARK}\n#{body}")
      assert_equal config, CodexHook.install_global
      assert_equal 2, body.scan(CodexHook::NOTE_MARK).size, "the pasted copy stays"
      assert_equal :current, CodexHook.block_state
      assert_equal true, CodexHook.remove_global
      assert_equal 1, body.scan(CodexHook::NOTE_MARK).size, "uninstall keeps the pasted copy too"
      refute CodexHook.installed?
    end

    # Value: protects=the collision guard seeing a user's `[hooks]` on line 1 behind a UTF-8 BOM;
    # fails_when=read_config keeps the U+FEFF, the `\A\s*` anchors miss the header, and install
    # appends a second [hooks] (invalid TOML) while doctor says current; why_new=red-team inv4
    # pass 2; seam=none; no_claim=which editors write a BOM
    def test_a_bom_before_the_users_hooks_still_collides
      File.binwrite(config, "\xEF\xBB\xBF[hooks]\nPreToolUse = []\n")
      capture_io { assert_equal :collision, CodexHook.install_global }
      assert_equal 1, File.binread(config).scan("[hooks]").size, "left untouched"
      # Doctor's path too: a BOM file holding our block (and nothing of the user's) reads current
      # and round-trips — the strip mustn't turn the block into a conflict or a collision.
      File.binwrite(config, "\xEF\xBB\xBFmodel = \"x\"\n")
      assert_equal config, CodexHook.install_global
      assert_equal :current, CodexHook.block_state
      assert_equal true, CodexHook.remove_global
      refute_includes File.read(config, encoding: "UTF-8"), CodexHook::BEGIN_MARK
    end

    # Value: protects=the :unsafe advice for a block missing its end line telling the user to
    # restore it, not delete our begin line; fails_when=the advice says "delete a stray marker
    # line" — following it orphans our [hooks] (uninstall sees nothing, install says collision);
    # why_new=red-team inv4 pass 3; seam=none; no_claim=none beyond protects
    def test_a_missing_end_marker_gets_restore_advice_and_restoring_it_recovers
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      File.write(config, body.sub("#{CodexHook::END_MARK}\n", ""))
      capture_io { assert_equal :unsafe, CodexHook.install_global }
      assert_includes CodexHook::UNSAFE_ADVICE, "put it back after the block's last line"
      assert_includes CodexHook::UNSAFE_ADVICE, "don't delete the `# >>>` line"
      assert_includes CodexHook::UNSAFE_ADVICE, "Codex itself may have written a `[[…]]` table", "the refusal doesn't blame the user for codex's write"
      File.write(config, "#{body}#{CodexHook::END_MARK}\n") # following the advice
      assert_equal config, CodexHook.install_global
      assert_equal true, CodexHook.remove_global
      refute_match(/^\[hooks\]/, body, "nothing of ours is left behind")
    end

    # Value: protects=install / doctor / uninstall under LC_ALL=C (launchd, cron, ssh without
    # LANG); fails_when=config.toml is read in the locale's encoding, so the em dash in our note
    # makes install report a false :conflict and uninstall think nothing is installed;
    # why_new=red-team inv4; seam=none; no_claim=a real C-locale process (default_external set
    # in-process, which is what the locale decides)
    def test_c_locale_reads_the_config_as_utf8
      was = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      File.write(config, %(model = "x"\n))
      assert_equal config, CodexHook.install_global
      assert CodexHook.installed?
      assert_equal :current, CodexHook.block_state
      assert_equal true, CodexHook.remove_global
      refute_includes File.read(config, encoding: "UTF-8"), CodexHook::BEGIN_MARK
    ensure
      Encoding.default_external = was
    end

    # Value: protects=a re-ensure with nothing to change leaving config.toml alone (no rename for
    # codex's watcher, no window for a racing codex save to read as :conflict); fails_when=the
    # early return goes and every install/enable-hooks rewrites; why_new=red-team inv4;
    # seam=none; no_claim=none beyond protects
    def test_an_unchanged_reinstall_does_not_rewrite
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      inode = File.stat(config).ino
      assert_equal config, CodexHook.install_global
      assert_equal inode, File.stat(config).ino
    end

    # The user's own [hooks] config above our block (theirs added after ours) survives
    # uninstall verbatim; only our block goes.
    # Value: protects=keys a bare [hooks.state] header holds surviving uninstall; fails_when=
    # our_trust? drops every bare header as ours (silent loss — conserved? never sees a chunk
    # marked ours); why_new=red-team inv3 pass 3; seam=none; no_claim=codex writing keys there
    def test_uninstall_keeps_keys_under_a_bare_hooks_state_header
      block_with(%([hooks.state]\nversion = 2\n))
      assert_equal true, CodexHook.remove_global
      assert_includes body, "[hooks.state]\nversion = 2\n"
      refute_includes body, CodexHook::BEGIN_MARK
    end

    def test_uninstall_keeps_a_users_own_hooks_table_outside_the_block
      File.write(config, %(model = "x"\n))
      CodexHook.install_global
      mine = %([hooks]\nStop = [{ hooks = [{ type = "command", command = "echo mine" }] }]\n)
      File.write(config, body.sub(CodexHook::BEGIN_MARK, "#{mine}#{CodexHook::BEGIN_MARK}"))
      assert_equal true, CodexHook.remove_global
      assert_equal %(model = "x"\n#{mine}), body
    end

    # A begin marker whose end line is gone: nothing matches as a region, so a rewrite would
    # append a second block and uninstall could never remove it (red-team pass 3).
    def test_refuses_a_begin_marker_without_its_end_marker
      File.write(config, %(model = "x"\n#{CodexHook::BEGIN_MARK}\n[hooks]\n))
      before = body
      capture_io do
        assert_equal :unsafe, CodexHook.install_global
        assert_equal :unsafe, CodexHook.remove_global
      end
      assert_equal before, body
    end

    # A repeated approval table must count once, or trusted > total reads as "untrusted".
    def test_trust_status_counts_a_duplicated_approval_once
      CodexHook.install_global
      all = CodexHook.expected_trust_keys
      block_with(trust_tables(all) + trust_tables(all.first(1)))
      assert_equal [all.size, all.size], CodexHook.trust_status
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
      # in: — the `thinking` reporter reads stdin; an inherited open pipe would hang it.
      system(env, "sh", "-c", cmd, chdir: dir, in: File::NULL, out: File::NULL, err: File::NULL)
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
