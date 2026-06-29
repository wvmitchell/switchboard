# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Covers the deterministic logic where install bugs hide: marker-block
  # idempotency, symlink-collision/ours/dangling handling, conf selection,
  # backup policy, and version parsing. Live-tmux behaviour (binds firing,
  # source-file) is verified manually + deferred to the integration suite (#10).
  class InstallerTest < SandboxTest
    # --- marker line / block surgery ----------------------------------------

    def test_marker_line_is_single_quoted_shell_escaped_path
      assert_equal "run-shell '#{Shellwords.escape(Installer.fragment_path)}'", Installer.marker_line
    end

    # The inner command must de-escape (shell layer) back to the real path, so a
    # clone path with spaces survives tmux → /bin/sh. (tmux layer verified live.)
    def test_marker_line_inner_round_trips_through_shell
      inner = Installer.marker_line.sub(/\Arun-shell '/, "").sub(/'\z/, "")
      assert_equal Installer.fragment_path, Shellwords.split(inner).first
    end

    # The shipped fragment must wire the per-session sidebar sync: an indexed
    # after-new-window hook (so uninstall can clear exactly it) that hands the new
    # window's id to sidebar-sync. The matching `set-hook -gu after-new-window[99]`
    # in teardown_live is live-only (TMUX-gated), verified manually.
    def test_fragment_wires_the_indexed_after_new_window_sync_hook
      frag = File.read(Installer.fragment_path)
      assert_includes frag, "after-new-window[99]"
      assert_includes frag, "sidebar-sync"
      assert_includes frag, '#{window_id}' # literal; tmux expands it at fire time
    end

    # The same-session window-switch poke (PR2). Like teardown_live's matching
    # set-hook -gu, the live wiring is TMUX-gated and verified manually; the fragment
    # content + the slot list are what we pin here.
    def test_fragment_wires_the_session_window_changed_poke_hook
      frag = File.read(Installer.fragment_path)
      assert_includes frag, "session-window-changed[99]"
      assert_includes frag, "poke-window"
      assert_includes frag, '#{window_id}'
    end

    def test_hook_slots_lists_all_three_indexed_hooks
      assert_equal 3, Installer::HOOK_SLOTS.size
      assert_includes Installer::HOOK_SLOTS, "session-window-changed[99]"
    end

    # doctor reads this: which hooks are LIVE in the running server. After a `git
    # pull` upgrade the new slot is absent until tmux reloads — it must read not-live.
    def test_live_hooks_from_flags_present_and_missing_slots
      raw = "client-session-changed[99] -> run-shell ...\nafter-new-window[99] -> run-shell ...\n"
      live = Installer.live_hooks_from(raw)
      assert live["client-session-changed[99]"], "a present slot reads live"
      assert live["after-new-window[99]"]
      refute live["session-window-changed[99]"], "an absent slot (pre-reload upgrade) reads not-live"
    end

    # doctor reads this too: is prefix-s actually bound to toggle-sidebar in the
    # running server? A stale server (upgrade not re-sourced) leaves it unbound or on
    # an ancient binding (the retired fzf-popup on prefix-S) — the broken-prefix-s case.
    def test_toggle_key_live_from_detects_the_prefix_s_toggle_binding
      live = %(bind-key  -T prefix s  run-shell "'/x/switchboard' toggle-sidebar"\n)
      assert Installer.toggle_key_live_from?(live), "prefix-s -> toggle-sidebar reads live"

      popup = %(bind-key  -T prefix S  display-popup -E /x/switchboard\n)
      refute Installer.toggle_key_live_from?(popup), "the stale capital-S popup is not the toggle binding"

      other = %(bind-key  -T prefix s  send-keys hi\n)
      refute Installer.toggle_key_live_from?(other), "a foreign prefix-s binding isn't ours"

      refute Installer.toggle_key_live_from?(""), "no binding reads not-live"
    end

    # Configurable keys (issue #15): the check is parametrized by the chosen key, so
    # a remapped toggle reads live on ITS key, not the hardcoded `s`.
    def test_toggle_key_live_from_honors_a_configured_key
      live = %(bind-key  -T prefix b  run-shell "'/x/switchboard' toggle-sidebar"\n)
      assert Installer.toggle_key_live_from?(live, "b"), "prefix-b -> toggle-sidebar reads live for key b"
      refute Installer.toggle_key_live_from?(live, "s"), "the default s is not bound here"
      # whitespace boundary: a multi-char key never matches a single-char prefix of it
      live2 = %(bind-key  -T prefix BSpace  run-shell "'/x/switchboard' toggle-sidebar"\n)
      assert Installer.toggle_key_live_from?(live2, "BSpace")
    end

    # --- rebind_ops: the pure command sequence (issue #15) --------------------

    def test_rebind_ops_binds_first_then_cleans_recorded_then_records
      ops = Installer.rebind_ops("toggle", "b", recorded: "s")
      assert_equal :bind, ops[0][0], "bind comes FIRST so a failed bind never strands the user"
      assert_equal [:bind, "toggle", "b"], ops[0]
      assert_includes ops, [:unbind, "s"], "cleans the previously-recorded key"
      assert_includes ops, [:set_key, "toggle", "b"], "records what we bound"
      assert_operator ops.index([:bind, "toggle", "b"]), :<, ops.index([:unbind, "s"]), "bind precedes unbind"
    end

    def test_rebind_ops_no_unbind_when_key_unchanged
      ops = Installer.rebind_ops("toggle", "b", recorded: "b")
      refute(ops.any? { |o| o[0] == :unbind }, "nothing to clean when the recorded key already matches")
      assert_includes ops, [:bind, "toggle", "b"]
    end

    def test_rebind_ops_legacy_s_cleanup_only_when_unrecorded
      # Upgrade from the old hardcoded fragment: option unset, `s` live, new key b.
      ops = Installer.rebind_ops("toggle", "b", recorded: nil, legacy_toggle: true)
      assert_includes ops, [:unbind, "s"], "cleans the legacy hardcoded s"
      # Already recorded (post-@option): no legacy cleanup, no spurious unbind of s.
      ops2 = Installer.rebind_ops("toggle", "b", recorded: "g", legacy_toggle: false)
      refute_includes ops2, [:unbind, "s"]
      # Default-key install: don't unbind the very key we're (re)binding.
      ops3 = Installer.rebind_ops("toggle", "s", recorded: nil, legacy_toggle: true)
      refute_includes ops3, [:unbind, "s"]
    end

    def test_rebind_ops_home_unset_cleans_recorded_and_forgets
      ops = Installer.rebind_ops("home", nil, recorded: "H")
      assert_includes ops, [:unbind, "H"], "unbinds the home key we'd recorded"
      assert_includes ops, [:clear_key, "home"], "forgets the option"
      assert_includes ops, [:clear_clobber, "home"]
      refute(ops.any? { |o| o[0] == :bind }, "nothing to bind when home is unset")
    end

    def test_rebind_ops_clobber_capture_and_clear
      with = Installer.rebind_ops("toggle", "b", recorded: nil, clobbered: "send-keys hi")
      assert_includes with, [:set_clobber, "toggle", "send-keys hi"], "records the clobbered foreign binding"
      without = Installer.rebind_ops("toggle", "b", recorded: nil, clobbered: nil)
      assert_includes without, [:clear_clobber, "toggle"], "clears it when nothing was clobbered"
    end

    # --- tmux_argv: symbolic op -> tmux command -------------------------------

    def test_tmux_argv_translates_each_op
      assert_equal ["bind-key", "b", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"],
                   Installer.tmux_argv([:bind, "toggle", "b"])
      assert_equal ["bind-key", "H", "run-shell", "'#{Installer.bin_path}' home"],
                   Installer.tmux_argv([:bind, "home", "H"])
      assert_equal ["unbind-key", "s"], Installer.tmux_argv([:unbind, "s"])
      assert_equal ["set-option", "-g", "@switchboard-toggle-key", "b"], Installer.tmux_argv([:set_key, "toggle", "b"])
      assert_equal ["set-option", "-gu", "@switchboard-home-key"], Installer.tmux_argv([:clear_key, "home"])
      assert_equal ["set-option", "-g", "@switchboard-toggle-clobbered", "x"], Installer.tmux_argv([:set_clobber, "toggle", "x"])
    end

    # --- run_rebind: bind-first + bind-failure fallback (via the run_tmux seam) -

    def test_run_rebind_executes_full_sequence_on_success
      cmds = []
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
        result = Installer.run_rebind("toggle", "b", recorded: "s", legacy_toggle: false, clobbered: nil)
        assert_equal "b", result
      end
      assert_equal ["bind-key", "b", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"], cmds.first
      assert_includes cmds, ["unbind-key", "s"]
      assert_includes cmds, ["set-option", "-g", "@switchboard-toggle-key", "b"]
    end

    def test_run_rebind_falls_back_to_default_when_bind_rejected
      cmds = []
      bad = ["bind-key", "Frobnicate", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      # Only the bind of the bad key fails; the recovery bind of `s` succeeds.
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; argv != bad }) do
        result = Installer.run_rebind("toggle", "Frobnicate", recorded: "g", legacy_toggle: false, clobbered: nil)
        assert_equal "s", result, "recovers to the default toggle so a working key survives"
      end
      assert_equal bad, cmds[0], "tried the configured key first"
      assert_includes cmds, ["bind-key", "s", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"], "bound the default"
      assert_includes cmds, ["unbind-key", "g"], "cleaned the previously-recorded key (no stale binding lingers)"
      assert_includes cmds, ["set-option", "-g", "@switchboard-toggle-key", "s"], "recorded the fallback so future cleanup can find it"
    end

    def test_run_rebind_no_infinite_recurse_when_default_itself_fails
      cmds = []
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; false }) do # every bind fails
        assert_nil Installer.run_rebind("toggle", "s", recorded: nil, legacy_toggle: false, clobbered: nil)
      end
      assert_equal 1, cmds.size, "default == desired: don't recurse when the default can't bind either"
    end

    def test_run_rebind_home_failure_recovers_to_unbound_and_clears_option
      cmds = []
      home_bind = ["bind-key", "Bogus", "run-shell", "'#{Installer.bin_path}' home"]
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; argv != home_bind }) do # home bind fails; cleanup succeeds
        assert_nil Installer.run_rebind("home", "Bogus", recorded: "H", legacy_toggle: false, clobbered: nil)
      end
      assert_includes cmds, ["unbind-key", "H"], "a rejected home key still cleans the old home binding"
      assert_includes cmds, ["set-option", "-gu", "@switchboard-home-key"], "forgets the home option"
      refute(cmds.any? { |c| c == ["bind-key", "s", "run-shell", "'#{Installer.bin_path}' home"] }, "no default fallback for home")
    end

    # --- apply_keybindings: ties config + recorded options + the seam together --

    def test_apply_keybindings_binds_configured_toggle_and_home
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b", "home" => "H" }))
      cmds = []
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(_name) { nil }) do
          stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
            Installer.apply_keybindings(config: Config.new)
          end
        end
      end
      assert_includes cmds, ["bind-key", "b", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      assert_includes cmds, ["bind-key", "H", "run-shell", "'#{Installer.bin_path}' home"]
      assert_includes cmds, ["set-option", "-g", "@switchboard-toggle-key", "b"]
    end

    def test_apply_keybindings_announces_only_when_asked
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "b" }))
      # silent path (fragment)
      silent = []
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(_n) { nil }) do
          stub_method(Installer, :run_tmux, ->(*a) { silent << a if a.first == "display-message"; true }) do
            Installer.apply_keybindings(config: Config.new)
          end
        end
      end
      assert_empty silent, "the fragment path stays silent (no display-message)"
      # announce path (interactive reload)
      announced = []
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(_n) { nil }) do
          stub_method(Installer, :run_tmux, ->(*a) { announced << a if a.first == "display-message"; true }) do
            Installer.apply_keybindings(announce: true, config: Config.new)
          end
        end
      end
      assert_equal 1, announced.size, "announce: true flashes one confirmation"
      assert_match(/prefix-b toggles the sidebar/, announced.first.last)
    end

    # --- foreign_binding: clobber detection -----------------------------------

    def test_foreign_binding_flags_a_non_switchboard_binding
      raw = %(bind-key  -T prefix b  send-keys hello\n)
      assert_equal "send-keys hello", Installer.foreign_binding(raw, "b", "toggle-sidebar")
    end

    def test_foreign_binding_ignores_our_own_binding
      raw = %(bind-key  -T prefix b  run-shell "'#{Installer.bin_path}' toggle-sidebar"\n)
      assert_nil Installer.foreign_binding(raw, "b", "toggle-sidebar"), "our own binding isn't a clobber"
    end

    def test_foreign_binding_nil_when_key_unbound
      assert_nil Installer.foreign_binding("", "b", "toggle-sidebar")
    end

    def test_strip_block_is_inverse_of_with_block
      base = "# my conf\nbind-key x display-message hi\n"
      wired = Installer.with_block(base)
      assert_includes wired, Installer::BEGIN_MARK
      assert_includes wired, Installer.marker_line
      assert_equal base, Installer.strip_block(wired)
    end

    def test_with_block_preserves_trailing_newline_shape
      assert Installer.with_block("a\n").end_with?("#{Installer::END_MARK}\n")
      assert Installer.with_block("no-newline").include?("no-newline\n#{Installer::BEGIN_MARK}")
    end

    def test_with_block_on_empty_body_starts_with_the_marker
      assert Installer.with_block("").start_with?(Installer::BEGIN_MARK)
    end

    # --- install: tmux wiring ------------------------------------------------

    def test_install_wires_block_once_and_is_idempotent
      conf = path("tmux.conf")
      File.write(conf, "# base\nbind-key x display hi\n")
      silently { Installer.install(conf: conf) }
      silently { Installer.install(conf: conf) }
      body = File.read(conf)
      assert_equal 1, body.scan(Installer::BEGIN_MARK).size
      assert_includes body, "bind-key x display hi" # user content untouched
    end

    def test_backup_is_first_write_only
      conf = path("tmux.conf")
      File.write(conf, "ORIGINAL\n")
      silently { Installer.install(conf: conf) }
      File.write(conf, "CHANGED-SINCE\n#{Installer::BEGIN_MARK}\nx\n#{Installer::END_MARK}\n")
      silently { Installer.install(conf: conf) } # must NOT overwrite the good .bak
      assert_equal "ORIGINAL\n", File.read("#{conf}.bak")
    end

    def test_atomic_write_replaces_content_and_leaves_no_temp
      conf = path("tmux.conf")
      File.write(conf, "old\n")
      Installer.atomic_write(conf, "new\n")
      assert_equal "new\n", File.read(conf)
      assert_empty Dir[path("tmux.conf*.sb-tmp")], "atomic write left a temp file behind"
    end

    def test_install_leaves_no_temp_file_behind
      conf = path("tmux.conf")
      File.write(conf, "# base\n")
      silently { Installer.install(conf: conf) }
      assert_empty Dir[path("tmux.conf*.sb-tmp")]
    end

    # --- atomic write through a symlinked conf (the dotfiles footgun) ---------

    # A tmux.conf symlinked into a dotfiles repo must survive a write: renaming
    # onto the link would replace it with a detached regular-file copy, silently
    # decoupling ~/.tmux.conf from the repo it points at. atomic_write follows the
    # link and writes the real file, leaving the symlink intact.
    def test_atomic_write_preserves_a_symlinked_target
      real = path("dotfiles", "tmux.conf")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, "old\n")
      link = path("tmux.conf")
      File.symlink(real, link)

      Installer.atomic_write(link, "new\n")

      assert File.symlink?(link), "the symlink was replaced by a regular file"
      assert_equal "new\n", File.read(real), "content didn't reach the link's target"
    end

    # Same protection end-to-end through install: the marker lands in the repo
    # file (preserving its prior content), and ~/.tmux.conf stays a link into it.
    def test_install_writes_through_a_symlinked_conf
      real = path("dotfiles", "tmux.conf")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, "# base\n")
      link = path("tmux.conf")
      File.symlink(real, link)

      silently { Installer.install(conf: link) }

      assert File.symlink?(link), "install clobbered the symlink"
      body = File.read(real)
      assert_includes body, Installer::BEGIN_MARK
      assert_includes body, "# base"
    end

    # The temp file lands beside the resolved target (so the rename stays atomic
    # within one dir), and a multi-hop chain resolves to the real file.
    def test_atomic_write_follows_a_symlink_chain_and_leaves_no_temp
      real = path("dotfiles", "tmux.conf")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, "old\n")
      mid = path("mid.conf");  File.symlink(real, mid)
      link = path("tmux.conf"); File.symlink(mid, link)

      Installer.atomic_write(link, "new\n")

      assert_equal "new\n", File.read(real)
      assert File.symlink?(link) && File.symlink?(mid), "a hop in the chain was clobbered"
      assert_empty Dir[path("**", "*.sb-tmp")], "atomic write left a temp file behind"
    end

    # real_target passes a plain path through untouched and resolves a link even
    # when its target doesn't exist yet (so the write can create it) — no raise.
    def test_real_target_resolves_symlinks_and_passes_plain_paths
      plain = path("plain.conf")
      assert_equal plain, Installer.real_target(plain)

      dangling = path("dangling")
      File.symlink(path("dotfiles", "nope.conf"), dangling)
      assert_equal path("dotfiles", "nope.conf"), Installer.real_target(dangling)
    end

    # --- install: symlink ----------------------------------------------------

    def test_install_creates_symlink_into_repo
      silently { Installer.install(no_tmux: true) }
      assert File.symlink?(Installer.symlink_path)
      assert File.identical?(Installer.symlink_path, Installer.bin_path)
    end

    # The short `sb` alias is symlinked beside the full command, so you can start
    # switchboard from any shell with two keystrokes.
    def test_install_creates_the_sb_shorthand_symlink
      silently { Installer.install(no_tmux: true) }
      sb = Installer.symlink_path("sb")
      assert File.symlink?(sb)
      assert File.identical?(sb, Installer.bin_path)
    end

    def test_uninstall_removes_both_the_command_and_the_shorthand
      silently { Installer.install(no_tmux: true) }
      silently { Installer.uninstall }
      refute File.symlink?(Installer.symlink_path)
      refute File.symlink?(Installer.symlink_path("sb"))
    end

    # A taken name only blocks that one name: a foreign `sb` is left untouched,
    # but the real `switchboard` command still links (the alias is optional).
    def test_foreign_sb_is_left_alone_and_does_not_block_the_command
      FileUtils.mkdir_p(Installer.bin_dir)
      sb = Installer.symlink_path("sb")
      File.write(sb, "not ours")
      silently { Installer.install(no_tmux: true) }
      refute File.symlink?(sb)
      assert_equal "not ours", File.read(sb)
      assert File.identical?(Installer.symlink_path, Installer.bin_path)
    end

    def test_refuses_to_clobber_a_foreign_file
      FileUtils.mkdir_p(File.dirname(Installer.symlink_path))
      File.write(Installer.symlink_path, "not ours")
      silently { Installer.install(no_tmux: true) }
      refute File.symlink?(Installer.symlink_path)
      assert_equal "not ours", File.read(Installer.symlink_path)
    end

    def test_repoints_a_dangling_symlink_repo_moved
      FileUtils.mkdir_p(File.dirname(Installer.symlink_path))
      File.symlink("/no/such/old-repo/bin/switchboard", Installer.symlink_path)
      silently { Installer.install(no_tmux: true) }
      assert File.identical?(Installer.symlink_path, Installer.bin_path)
    end

    def test_leaves_a_foreign_live_symlink_alone
      other = path("other"); FileUtils.mkdir_p(other)
      File.write(File.join(other, "thing"), "x")
      FileUtils.mkdir_p(File.dirname(Installer.symlink_path))
      File.symlink(File.join(other, "thing"), Installer.symlink_path)
      silently { Installer.install(no_tmux: true) }
      assert_equal File.join(other, "thing"), File.readlink(Installer.symlink_path)
    end

    # --- install: config -----------------------------------------------------

    def test_install_scaffolds_an_empty_config
      silently { Installer.install(no_tmux: true) }
      assert Config.exist?
      assert_equal Config.default_data, YAML.safe_load_file(Config.path)
    end

    def test_install_leaves_an_existing_config_untouched
      File.write(Config.path, "worktree_root: /mine\nprojects:\n  - name: a\n    path: /p\n")
      before = File.read(Config.path)
      silently { Installer.install(no_tmux: true) }
      assert_equal before, File.read(Config.path)
    end

    # --- print / skip modes --------------------------------------------------

    def test_print_tmux_writes_nothing_to_conf
      conf = path("tmux.conf")
      File.write(conf, "# base\n")
      out = silently { Installer.install(print_tmux: true, conf: conf) }
      assert_equal "# base\n", File.read(conf)
      assert_includes out, Installer.marker_line
    end

    # --- uninstall -----------------------------------------------------------

    def test_uninstall_removes_block_and_symlink_keeps_user_lines
      conf = path("tmux.conf")
      File.write(conf, "# mine\nbind-key x display hi\n")
      silently { Installer.install(conf: conf) }
      silently { Installer.uninstall(conf: conf) }
      assert_equal "# mine\nbind-key x display hi\n", File.read(conf)
      refute File.symlink?(Installer.symlink_path)
    end

    def test_uninstall_leaves_foreign_symlink
      FileUtils.mkdir_p(File.dirname(Installer.symlink_path))
      File.write(Installer.symlink_path, "not ours")
      silently { Installer.uninstall }
      assert_equal "not ours", File.read(Installer.symlink_path)
    end

    # A foreign *symlink* (vs. the foreign regular file above) at our path is also
    # left alone — the "left foreign symlink" branch of unlink_one.
    def test_uninstall_leaves_a_foreign_symlink_alone
      other = path("other"); FileUtils.mkdir_p(other)
      File.write(File.join(other, "thing"), "x")
      FileUtils.mkdir_p(File.dirname(Installer.symlink_path))
      File.symlink(File.join(other, "thing"), Installer.symlink_path)
      silently { Installer.uninstall }
      assert File.symlink?(Installer.symlink_path)
      assert_equal File.join(other, "thing"), File.readlink(Installer.symlink_path)
    end

    # --- conf selection ------------------------------------------------------

    def test_tmux_conf_honors_explicit_override
      assert_equal File.expand_path("/x/y.conf"), Installer.tmux_conf("/x/y.conf")
    end

    def test_tmux_conf_falls_back_to_existing_home_conf
      ENV["HOME"] = @dir # not in tmux → fallback chain; HOME redirected to sandbox
      xdg = path(".config", "tmux", "tmux.conf")
      FileUtils.mkdir_p(File.dirname(xdg))
      File.write(xdg, "# xdg\n")
      assert_equal xdg, Installer.tmux_conf
    end

    def test_tmux_conf_defaults_to_dot_tmux_conf_when_none_exist
      ENV["HOME"] = @dir
      assert_equal File.join(@dir, ".tmux.conf"), Installer.tmux_conf
    end

    # An empty --tmux-conf value must fall through to the chain, NOT expand to cwd.
    def test_tmux_conf_empty_override_falls_through_to_default
      ENV["HOME"] = @dir
      assert_equal File.join(@dir, ".tmux.conf"), Installer.tmux_conf("")
    end

    # A single quote in the repo path can't be safely nested in tmux's run-shell
    # single quotes; the real repo path is clean, so the guard reads true here.
    def test_tmux_safe_path_true_for_a_quote_free_repo
      assert Installer.tmux_safe_path?
    end

    # --- version parse -------------------------------------------------------

    def test_parse_version
      assert_in_delta 3.6, Installer.parse_version("tmux 3.6a"), 0.001
      assert_in_delta 3.2, Installer.parse_version("tmux next-3.2"), 0.001
      assert_nil Installer.parse_version("")
      assert_nil Installer.parse_version(nil)
    end

    # --- codex hooks (the consented global block; CODEX_HOME sandboxed) -------
    # codex_present? is stubbed so the suite is deterministic on a machine without codex.

    def codex_home!
      ENV["CODEX_HOME"] = path("codexhome")
      FileUtils.mkdir_p(ENV["CODEX_HOME"])
    end

    def with_codex(&blk) = stub_method(Installer, :codex_present?, -> { true }, &blk)

    def test_step_codex_hooks_skips_when_codex_absent
      codex_home!
      stub_method(Installer, :codex_present?, -> { false }) do
        silently { Installer.step_codex_hooks(true) } # even explicit yes is a no-op
      end
      refute CodexHook.installed?, "no codex on the box ⇒ nothing written"
    end

    def test_step_codex_hooks_writes_with_explicit_consent
      codex_home!
      with_codex { silently { Installer.step_codex_hooks(true) } }
      assert CodexHook.installed?, "--codex-hooks writes the global block"
    end

    def test_step_codex_hooks_skips_on_explicit_decline
      codex_home!
      with_codex { silently { Installer.step_codex_hooks(false) } }
      refute CodexHook.installed?, "--no-codex-hooks never writes"
    end

    # The CI-safety guarantee: consent nil + non-tty ⇒ default NO (prints "skipped"),
    # never silently writes global config.
    def test_step_codex_hooks_defaults_no_on_non_tty
      codex_home!
      out = with_codex do
        stub_method(Installer, :prompt_yes?, ->(_q) { false }) do
          silently { Installer.step_codex_hooks(nil) }
        end
      end
      refute CodexHook.installed?, "a non-tty prompt defaults to no"
      assert_match(/skipped/, out)
    end

    # install doubles as a repair path: an already-installed block is re-ensured (no
    # re-prompt), so a stale block / missing reporter self-heals.
    def test_step_codex_hooks_reensures_an_installed_block
      codex_home!
      CodexHook.install_global
      reensured = false
      with_codex do
        stub_method(CodexHook, :install_global, lambda {
          reensured = true
          CodexHook.config_path
        }) do
          out = silently { Installer.step_codex_hooks(nil) } # nil consent, but installed ⇒ re-ensure
          assert_match(/re-ensured/, out)
        end
      end
      assert reensured, "install re-ensures an already-installed block"
    end

    def test_prompt_yes_defaults_false_without_a_tty
      # The test runner's stdin isn't a tty, which is exactly the scripted/CI case.
      refute Installer.prompt_yes?("write global config?")
    end

    # uninstall strips the global codex block (the one place codex delivery is global),
    # while leaving any foreign config content intact.
    def test_uninstall_removes_the_global_codex_block
      codex_home!
      File.write(CodexHook.config_path, %(model = "gpt-5.5"\n))
      with_codex { CodexHook.install_global }
      assert CodexHook.installed?
      conf = path("tmux.conf")
      File.write(conf, "# mine\n")
      silently { Installer.uninstall(conf: conf) }
      refute CodexHook.installed?, "uninstall removed the codex block"
      assert_includes File.read(CodexHook.config_path), %(model = "gpt-5.5"), "foreign config kept"
    end

    private

    # Swallow the install/uninstall progress output and return it as a string.
    def silently
      out = StringIO.new
      orig = $stdout
      $stdout = out
      yield
      out.string
    ensure
      $stdout = orig
    end
  end
end
