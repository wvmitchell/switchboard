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
