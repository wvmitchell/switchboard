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
      # tmux lists punctuation keys escaped; a `$` or `#` toggle must still read as bound.
      escaped = %(bind-key -T prefix \\$ run-shell "'/bin/switchboard' toggle-sidebar"\n)
      assert Installer.toggle_key_live_from?(escaped, "$"), "an escaped `$` binding reads live"
      odd = "bind-key -T prefix x display caf\xC3\nbind-key -T prefix s run-shell \"'/x/switchboard' toggle-sidebar\"\n".dup.force_encoding(Encoding::UTF_8)
      assert Installer.toggle_key_live_from?(odd, "s"), "an invalid byte in another binding doesn't raise"

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

    # Value: protects=a tmux key ending in `;` (C-;) reaches tmux escaped, so it binds and
    # every @option records it verbatim; fails_when=run_tmux passes a trailing `;` raw (tmux
    # reads it as a command separator: binds "C-", stores "C-", and key_drift? then reads an
    # unapplied edit on every upgrade); why_new=ship 4 red team, confirmed on tmux 3.8;
    # seam=system; no_claim=tmux's own parsing (verified by hand on an isolated server)
    def test_run_tmux_escapes_a_trailing_semicolon
      seen = []
      stub_method(Installer, :system, ->(*argv, **) { seen << argv; true }) do
        Installer.run_tmux("bind-key", "C-;", "run-shell", "x")
        Installer.run_tmux("set-option", "-g", "@switchboard-toggle-rejected", ";")
        Installer.run_tmux("unbind-key", "\\;")
      end
      assert_equal ["tmux", "bind-key", "C-\\;", "run-shell", "x"], seen[0]
      assert_equal ["tmux", "set-option", "-g", "@switchboard-toggle-rejected", "\\;"], seen[1]
      assert_equal ["tmux", "unbind-key", "\\;"], seen[2], "already escaped: left alone"
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

    # Value: protects=a key tmux refused staying remembered, so its fallback doesn't read as
    # an unapplied edit, and a later good bind forgetting it; fails_when=the rejected option is
    # set before the recovery (which clears it) or never cleared; why_new=new (R4); seam=run_tmux
    def test_run_rebind_remembers_a_refused_key_and_forgets_it_on_a_good_bind
      cmds = []
      bad = ["bind-key", "Frobnicate", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; argv != bad }) do
        Installer.run_rebind("toggle", "Frobnicate", recorded: "g", legacy_toggle: false, clobbered: nil)
      end
      assert_equal ["set-option", "-g", "@switchboard-toggle-rejected", "Frobnicate"], cmds.last,
                   "recorded after the recovery bind, which clears it"
      cmds.clear
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
        Installer.run_rebind("toggle", "b", recorded: "s", legacy_toggle: false, clobbered: nil)
      end
      assert_includes cmds, ["set-option", "-gu", "@switchboard-toggle-rejected"]
      # Extended (audit): a role unbound in config forgets a refusal too, so a later hand edit
      # back to that key still reads as drift.
      cmds.clear
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
        Installer.run_rebind("home", nil, recorded: "H", legacy_toggle: false, clobbered: nil)
      end
      assert_includes cmds, ["set-option", "-gu", "@switchboard-home-rejected"]
    end

    # Value: protects=uninstall leaving no switchboard option in the live server for either role,
    # the new -rejected one included; fails_when=teardown_live drops a role's unbind or option
    # clear; why_new=teardown_live's commands were never asserted (only noted as manual); seam=run_tmux
    def test_teardown_live_unbinds_and_forgets_every_recorded_option
      cmds = []
      opts = { "@switchboard-toggle-key" => "t", "@switchboard-home-key" => "H" }
      stub_method(Installer, :tmux_option, ->(name) { opts[name] }) do
        stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) { Installer.teardown_live }
      end
      assert_includes cmds, ["unbind-key", "t"]
      assert_includes cmds, ["unbind-key", "H"]
      %w[toggle home].product(%w[key clobbered rejected]).each do |role, kind|
        assert_includes cmds, ["set-option", "-gu", "@switchboard-#{role}-#{kind}"]
      end
      Installer::HOOK_SLOTS.each { |slot| assert_includes cmds, ["set-hook", "-gu", slot] }
    end

    # Value: protects=the home role's -rejected record too (set after its nil recovery, cleared
    # on a later good bind); fails_when=the set is skipped or precedes the recovery for home;
    # why_new=ship review S3/S4: only toggle was asserted; seam=run_tmux
    def test_run_rebind_tracks_a_refused_home_key_like_toggle
      cmds = []
      bad = ["bind-key", "Bogus", "run-shell", "'#{Installer.bin_path}' home"]
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; argv != bad }) do
        Installer.run_rebind("home", "Bogus", recorded: "H", legacy_toggle: false, clobbered: nil)
      end
      assert_equal ["set-option", "-g", "@switchboard-home-rejected", "Bogus"], cmds.last
      cmds.clear
      stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
        Installer.run_rebind("home", "H", recorded: nil, legacy_toggle: false, clobbered: nil)
      end
      assert_includes cmds, ["set-option", "-gu", "@switchboard-home-rejected"]
    end

    # Value: protects=no false drift verdict from a config.yml that didn't parse (its keys read
    # as defaults); fails_when=key_drift? ignores load_error; why_new=ship review M1/S6; seam=tmux_server?
    def test_key_drift_has_no_verdict_on_a_config_that_did_not_parse
      File.write(Config.path, "--\ntmux_keys:\n  toggle: t\n")
      stub_method(Installer, :tmux_server?, -> { flunk "never asks tmux about a broken config" }) do
        assert_nil Installer.key_drift?("toggle", config: Config.new)
      end
    end

    # Value: protects=no drift verdict with no tmux server (upgrade from a plain shell must not
    # read every configured key as unapplied and "finish" on each run); fails_when=key_drift?
    # drops its tmux_server? gate (tmux_option reads nil, so any configured key looks drifted);
    # why_new=every drift test stubs tmux_server? true; seam=tmux_server?
    def test_key_drift_has_no_verdict_without_a_tmux_server
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "t" }))
      stub_method(Installer, :tmux_server?, -> { false }) do
        stub_method(Installer, :tmux_option, ->(*) { flunk "no server, nothing to read" }) do
          assert_nil Installer.key_drift?("toggle", config: Config.new)
        end
      end
    end

    # Value: protects=doctor/upgrade telling a hand-edited tmux_keys apart from a key tmux
    # refused; fails_when=key_drift_from? ignores the recorded or the rejected key; why_new=
    # new (R4: doctor and upgrade read only the bound key); seam=none
    def test_key_drift_is_an_unapplied_edit_never_a_refused_key
      {
        ["s", "s", nil] => false,   # applied
        ["F13", "s", "F13"] => false, # tmux refused F13, s is the deliberate fallback
        ["t", "s", nil] => true,    # edited by hand, never re-applied
        ["u", "s", "t"] => true,    # edited again after a refusal
        [nil, nil, nil] => false,   # home unbound on both sides
        [nil, "S", nil] => true,    # home removed from config, still bound
        ["H", nil, nil] => true     # home added to config, never bound
      }.each do |(configured, recorded, rejected), drift|
        assert_equal drift, Installer.key_drift_from?(configured, recorded, rejected), [configured, recorded, rejected].inspect
      end
    end

    # --- apply_keybindings: ties config + recorded options + the seam together --

    # Value: protects=swapping toggle and home keys leaves both bound (neither role unbinds a
    # key the other now wants); fails_when=rebind unbinds its recorded key unconditionally
    # (the toggle loses its new key); why_new=ship 2 Codex adversarial; seam=run_tmux
    def test_apply_keybindings_survives_a_toggle_home_swap
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "H", "home" => "s" }))
      recorded = { "@switchboard-toggle-key" => "s", "@switchboard-home-key" => "H" }
      cmds = []
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(name) { recorded[name] }) do
          stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
            Installer.apply_keybindings(config: Config.new)
          end
        end
      end
      assert_includes cmds, ["bind-key", "H", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      assert_includes cmds, ["bind-key", "s", "run-shell", "'#{Installer.bin_path}' home"]
      refute_includes cmds, ["unbind-key", "H"], "home must not unbind the toggle's new key"
      refute_includes cmds, ["unbind-key", "s"], "toggle must not unbind home's new key"
      assert_includes cmds, ["set-option", "-g", "@switchboard-config-path", File.expand_path(Config.path)],
                      "records which config these keys came from"
    end

    # Value: protects=moving the toggle onto home's old key while unsetting home leaves the toggle
    # bound, and a legacy `s` cleanup never unbinds the key home now wants; fails_when=the
    # desired-nil cleanup or the legacy-`s` unbind ignores `taken:`; why_new=the swap test only
    # reaches the bind branch (both roles desired), never the cleanup or legacy branches;
    # seam=none; no_claim=the live tmux server's key table
    def test_a_key_another_role_takes_is_never_unbound_by_cleanup
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "H" })) # home unset
      recorded = { "@switchboard-toggle-key" => "s", "@switchboard-home-key" => "H" }
      cmds = []
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(name) { recorded[name] }) do
          stub_method(Installer, :run_tmux, ->(*argv) { cmds << argv; true }) do
            Installer.apply_keybindings(config: Config.new)
          end
        end
      end
      assert_includes cmds, ["bind-key", "H", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      refute_includes cmds, ["unbind-key", "H"], "home's cleanup must not unbind the toggle's new key"
      assert_includes cmds, ["unbind-key", "s"], "the toggle's old key is still cleaned up"

      ops = Installer.rebind_ops("toggle", "b", recorded: nil, legacy_toggle: true, taken: ["s"])
      refute_includes ops, [:unbind, "s"], "legacy cleanup leaves `s` to the home role that wants it"
    end

    # Value: protects=drift is judged only against the config tmux actually bound from, so a
    # shell/server config mismatch (or a failed tmux read) can't make upgrade loop; fails_when=
    # key_drift? ignores @switchboard-config-path; why_new=ship 2 Claude adversarial; seam=tmux_option
    def test_key_drift_needs_the_config_tmux_bound_from
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "t" }))
      base = { "@switchboard-toggle-key" => "s" }
      stub_method(Installer, :tmux_server?, -> { true }) do
        { nil => nil, "/elsewhere/config.yml" => nil, File.expand_path(Config.path) => true }.each do |bound_from, verdict|
          opts = base.merge("@switchboard-config-path" => bound_from)
          got = stub_method(Installer, :tmux_option, ->(name) { opts[name] }) { Installer.key_drift?("toggle", config: Config.new) }
          verdict.nil? ? assert_nil(got, bound_from.inspect) : assert_equal(verdict, got, bound_from.inspect)
        end
      end
    end

    # Value: protects=a refused toggle key whose fallback `s` is home's key keeps the toggle on
    # `s` (home yields and is recorded as refused, so upgrade's drift check converges); fails_when=
    # home binds over the toggle's fallback; why_new=ship 3 red team + state machines, D3;
    # seam=run_tmux; no_claim=tmux's real key parser (the refusal is simulated)
    def test_a_refused_toggle_keeps_its_fallback_over_home
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "F13", "home" => "s" }))
      cmds = []
      tmux = lambda do |*argv|
        cmds << argv
        !(argv[0] == "bind-key" && argv[1] == "F13")
      end
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(_name) { nil }) do
          stub_method(Installer, :run_tmux, tmux) { Installer.apply_keybindings(config: Config.new) }
        end
      end
      assert_includes cmds, ["bind-key", "s", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      refute_includes cmds, ["bind-key", "s", "run-shell", "'#{Installer.bin_path}' home"], "home never steals the fallback"
      refute_includes cmds, ["unbind-key", "s"]
      assert_includes cmds, ["set-option", "-g", "@switchboard-home-rejected", "s"]
      assert_includes cmds, ["set-option", "-g", "@switchboard-toggle-rejected", "F13"]
      refute Installer.key_drift_from?("s", nil, "s"), "the yielded home key reads as applied"
    end

    # Value: protects=home's cleanup never unbinds the key the toggle just fell back onto
    # (home was recorded on `s`, the toggle's configured key is refused); fails_when=taken
    # omits keys earlier roles actually bound; why_new=ship 3 pass 2 testing; seam=run_tmux
    def test_a_yielding_home_never_unbinds_the_toggles_fallback
      File.write(Config.path, YAML.dump("tmux_keys" => { "toggle" => "F13", "home" => "s" }))
      recorded = { "@switchboard-home-key" => "s" }
      cmds = []
      tmux = ->(*argv) { cmds << argv; !(argv[0] == "bind-key" && argv[1] == "F13") }
      stub_method(Installer, :list_prefix_keys, -> { "" }) do
        stub_method(Installer, :tmux_option, ->(name) { recorded[name] }) do
          stub_method(Installer, :run_tmux, tmux) { Installer.apply_keybindings(config: Config.new) }
        end
      end
      assert_includes cmds, ["bind-key", "s", "run-shell", "'#{Installer.bin_path}' toggle-sidebar"]
      refute_includes cmds, ["unbind-key", "s"], "home's cleanup must not unbind the toggle's fallback"
    end

    # Value: protects=only our bin path followed by a role's exact subcommand counts as ours
    # (a Linux bin under /home/ must not make every binding of ours look like a role's);
    # fails_when=ours? matches subcommand substrings anywhere; why_new=ship 3 pass 2 red team;
    # seam=bin_path
    def test_ours_needs_a_roles_exact_subcommand
      bin = "/home/me/switchboard/bin/switchboard"
      stub_method(Installer, :bin_path, -> { bin }) do
        assert Installer.ours?(%(run-shell "'#{bin}' home"))
        assert Installer.ours?(%(run-shell "'#{bin}' toggle-sidebar"))
        refute Installer.ours?(%(run-shell "'#{bin}' quit")), "a path containing /home/ isn't the home role"
        refute Installer.ours?(%(run-shell "'#{bin}' rename home-page"))
        refute Installer.ours?(%(run-shell "'#{bin}' homework"))
      end
    end

    # Value: protects=a toggle/home swap records no clobber of switchboard's own binding (doctor
    # stays quiet); fails_when=foreign_binding treats the other role's binding as foreign;
    # why_new=ship 3 red team + state machines; seam=list_prefix_keys
    def test_a_key_swap_records_no_clobber_of_our_own_binding
      bin = Installer.bin_path
      raw = "bind-key -T prefix s run-shell \"'#{bin}' toggle-sidebar\"\n" \
            "bind-key -T prefix H run-shell \"'#{bin}' home\"\n"
      assert_nil Installer.foreign_binding(raw, "H"), "home's binding is ours"
      assert_nil Installer.foreign_binding(raw, "s"), "the toggle's binding is ours"
      assert_equal "send-keys x", Installer.foreign_binding("bind-key -T prefix q send-keys x\n", "q")
    end

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
      assert_equal "send-keys hello", Installer.foreign_binding(raw, "b")
    end

    def test_foreign_binding_ignores_our_own_binding
      raw = %(bind-key  -T prefix b  run-shell "'#{Installer.bin_path}' toggle-sidebar"\n)
      assert_nil Installer.foreign_binding(raw, "b"), "our own binding isn't a clobber"
    end

    def test_foreign_binding_nil_when_key_unbound
      assert_nil Installer.foreign_binding("", "b")
    end

    # Value: protects=doctor reading back exactly the fragment install wired; fails_when=
    # marker_line's format changes without wired_fragment (every healthy install reads ✗);
    # why_new=the doctor test writes its own copy of the line; seam=none
    def test_wired_fragment_round_trips_what_install_writes
      conf = path("tmux.conf")
      File.write(conf, Installer.with_block("set -g mouse on\n"))
      assert_equal Installer.fragment_path, Installer.wired_fragment(conf)
    end

    # Value: protects=wired_fragment degrading to nil (never raising into doctor) on a missing
    # conf, a hand-edited block, or an unbalanced quote; fails_when=the guards or rescue go;
    # why_new=only the well-formed block is exercised; seam=none
    def test_wired_fragment_is_nil_when_unreadable_or_unrecognized
      conf = path("tmux.conf")
      assert_nil Installer.wired_fragment(conf)
      File.write(conf, "#{Installer::BEGIN_MARK}\n# edited by hand\n#{Installer::END_MARK}\n")
      assert_nil Installer.wired_fragment(conf)
      File.write(conf, "#{Installer::BEGIN_MARK}\nrun-shell '/a/\"b'\n#{Installer::END_MARK}\n")
      assert_nil Installer.wired_fragment(conf)
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

    # Homebrew already put `switchboard` on PATH; install must not also plant
    # ~/.local/bin links (they'd point into a keg that upgrade deletes).
    def test_homebrew_install_skips_the_path_symlinks
      out = stub_method(Installer, :homebrew?, -> { true }) { silently { Installer.install(no_tmux: true) } }
      refute File.exist?(Installer.symlink_path)
      refute File.exist?(Installer.symlink_path("sb"))
      assert_includes out, "on PATH via Homebrew"
      refute_includes out, "isn't on your PATH"
    end

    # --- install: config -----------------------------------------------------

    def test_install_scaffolds_an_empty_config
      silently { Installer.install(no_tmux: true) }
      assert Config.exist?
      assert_effective_default_config(YAML.safe_load_file(Config.path))
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

    # PATH belongs to brew under Homebrew — uninstall leaves it to `brew uninstall`.
    def test_homebrew_uninstall_leaves_path_to_brew
      FileUtils.mkdir_p(File.dirname(Installer.symlink_path))
      File.symlink(Installer.bin_path, Installer.symlink_path)
      out = stub_method(Installer, :homebrew?, -> { true }) { silently { Installer.uninstall } }
      assert_includes out, "brew uninstall switchboard"
      assert File.symlink?(Installer.symlink_path), "brew mode never touches ~/.local/bin links"
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

    # Value: protects=install failing (CLI exit 1) only when the codex write was attempted and
    # refused, after every other step ran; fails_when=install's result ignores the codex step, or
    # a declined prompt/absent codex reads as a failure; why_new=only the printed ✗ was pinned;
    # seam=stub install_global; no_claim=the CLI's exit itself (CLI.run maps false → exit 1)
    def test_install_returns_false_only_for_a_refused_codex_write
      codex_home!
      run = ->(**kw) { got = nil; silently { got = Installer.install(no_tmux: true, **kw) }; got }
      with_codex do
        refusals = { :unsafe => false, :conflict => false, :collision => false, nil => false, CodexHook.config_path => true }
        refusals.each do |result, want|
          assert_equal want, stub_method(CodexHook, :install_global, -> { result }) { run.(codex_hooks: true) }, result.inspect
        end
        assert_equal true, run.(codex_hooks: false), "declined: not a failure"
        # The closing line agrees with the exit status: no plain "Done" after a refusal.
        { :unsafe => true, CodexHook.config_path => false }.each do |result, flagged|
          out = stub_method(CodexHook, :install_global, -> { result }) { silently { Installer.install(no_tmux: true, codex_hooks: true) } }
          assert_equal flagged, out.include?("Done, except the codex hooks"), result.inspect
        end

        CodexHook.install_global # already opted in: a plain `install` takes the re-ensure branch
        refusals.each do |result, want|
          assert_equal want, stub_method(CodexHook, :install_global, -> { result }) { run.(codex_hooks: nil) }, "re-ensure #{result.inspect}"
        end
        # --no-codex-hooks is hands off even with a block installed: no rewrite, so no refusal.
        stub_method(CodexHook, :install_global, -> { flunk "--no-codex-hooks must not rewrite the block" }) do
          assert_equal true, run.(codex_hooks: false)
        end
      end
      stub_method(Installer, :codex_present?, -> { false }) do
        assert_equal true, run.(codex_hooks: true), "no codex: not a failure"
      end
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

    def test_step_codex_unhooks_is_a_noop_without_a_block
      codex_home!
      stub_method(CodexHook, :remove_global, -> { flunk "no block, nothing to remove" }) do
        assert Installer.step_codex_unhooks, "nothing to do counts as done"
      end
    end

    # Value: protects=uninstall's report matching what happened to the codex config;
    # fails_when=step_codex_unhooks prints ✓ without checking remove_global (the false
    # "removed" a real uninstall printed); why_new=the test above only covers a removal
    # that works; seam=stub_method on CodexHook.remove_global (forces the failure branch)
    def test_uninstall_reports_a_codex_block_it_could_not_remove
      codex_home!
      with_codex { CodexHook.install_global }
      conf = path("tmux.conf")
      File.write(conf, "# mine\n")
      # A FAILED write (remove_global's rescue → false) would fail again on a re-run, so it
      # must not wedge uninstall: report it, don't claim removal, and finish the rest.
      ok = nil
      out = stub_method(CodexHook, :remove_global, -> { false }) { silently { ok = Installer.uninstall(conf: conf) } }
      refute ok, "uninstall exits 1 with the block still there, as install does"
      assert_includes out, "codex hooks block is still there"
      # Never "delete it by hand": codex keeps its own tables inside the block (plan R8).
      refute_match(/by hand|delete/i, out)
      assert_includes out, "#{File.dirname(CodexHook.config_path)} (and the file) writable"
      assert_includes out, "#{File.join(Installer.repo_root, 'bin', 'switchboard')} uninstall"
      refute_includes out, "removed global codex hooks"
      refute_includes out, "Stopped before removing anything else"
      assert_includes out, "Done, except the codex hooks"
    end

    # Value: protects=a codex removal that found nothing left (remove_global's plain false)
    # not failing uninstall; fails_when=step_codex_unhooks maps every false to :failed;
    # why_new=cycle-2 maintainability; seam=CodexHook.remove_global, CodexHook.installed?
    def test_uninstall_treats_nothing_left_to_remove_as_done
      codex_home!
      with_codex { CodexHook.install_global }
      conf = path("tmux.conf")
      File.write(conf, "# mine\n")
      ok = nil
      gone = [true, false] # installed? before the remove, then after it
      out = stub_method(CodexHook, :installed?, -> { gone.shift || false }) do
        stub_method(CodexHook, :remove_global, -> { false }) { silently { ok = Installer.uninstall(conf: conf) } }
      end
      assert ok, out
      refute_includes out, "Done, except the codex hooks"
      refute_includes out, "still there"
    end

    # Value: protects=uninstall never says "Done" when the codex config became unreadable (the
    # block may still be there); fails_when=step_codex_unhooks trusts installed? == false on an
    # unreadable file; why_new=ship 2 Claude adversarial; seam=CodexHook.remove_global/installed?
    def test_uninstall_fails_when_the_codex_config_turned_unreadable
      codex_home!
      with_codex { CodexHook.install_global }
      conf = path("tmux.conf")
      File.write(conf, "# mine\n")
      ok = nil
      gone = [true, false] # installed? true at entry, then "false" because the file can't be read
      out = stub_method(CodexHook, :installed?, -> { gone.shift || false }) do
        stub_method(CodexHook, :remove_global, -> { File.chmod(0o000, CodexHook.config_path); false }) do
          silently { ok = Installer.uninstall(conf: conf) }
        end
      end
      refute ok, out
      assert_includes out, "Done, except the codex hooks"
    ensure
      File.chmod(0o600, CodexHook.config_path) if CodexHook.config_path && File.exist?(CodexHook.config_path)
    end

    # Value: protects=install blaming the config, not the hooks, when config.yml won't parse;
    # fails_when=the summary always says "the agent-state hooks"; why_new=cycle-2 red team; seam=step_*
    def test_install_names_the_config_when_it_will_not_parse
      File.write(Config.path, "--\nprojects:\n")
      out = %i[step_symlink wire_tmux step_init step_codex_hooks warn_path warn_tmux_version].reduce(-> { silently { Installer.install(no_tmux: true) } }) do |inner, m|
        -> { stub_method(Installer, m, ->(*, **) { true }) { inner.call } }
      end.call
      assert_includes out, "Done, except the config (✗ above)"
    end

    # Value: protects=a refused or raced uninstall never reads as success and never advises
    # deleting the block by hand (codex keeps its own tables inside it); fails_when=a
    # truthy :unsafe/:conflict falls into the ✓ branch, or the old "delete it by hand"
    # advice returns; why_new=refusals didn't exist; seam=stub_method on remove_global
    def test_uninstall_reports_refusals_without_destructive_advice
      codex_home!
      with_codex { CodexHook.install_global }
      conf = path("tmux.conf")
      File.write(conf, "# mine\n")
      # Value: protects=a refusal the user can fix stops uninstall with "re-run" advice, never
      # the old "delete it by hand"; fails_when=the stop message is dropped or by-hand advice
      # returns; why_new=only the order was pinned; seam=stub remove_global. (A write error,
      # remove_global → false, continues instead — test_uninstall_reports_a_codex_block_…)
      { unsafe: "left the codex hooks block", conflict: "changed while uninstalling" }.each do |result, text|
        out = stub_method(CodexHook, :remove_global, -> { result }) { silently { Installer.uninstall(conf: conf) } }
        assert_includes out, text
        refute_includes out, "removed global codex hooks"
        refute_includes out, "by hand"
        assert_includes out, "Stopped before removing anything else", result.inspect
      end
    end

    # Value: protects=a codex refusal's "re-run uninstall" advice still works: on a refusal
    # uninstall stops before removing the PATH command (or anything else), with no false
    # "Done."; on success codex goes first; fails_when=uninstall carries on after a refusal or
    # unlinks first; why_new=no test pinned the order; seam=stub remove_global/unlink_symlink
    def test_uninstall_stops_on_a_codex_refusal_and_handles_codex_first
      codex_home!
      with_codex { CodexHook.install_global }
      conf = path("tmux.conf")
      File.write(conf, "# mine\n")
      { unsafe: %i[codex], true => %i[codex unlink] }.each do |result, want|
        order = []
        out = stub_method(CodexHook, :remove_global, -> { order << :codex; result }) do
          stub_method(Installer, :unlink_symlink, -> { order << :unlink }) { silently { @uninstalled = Installer.uninstall(conf: conf) } }
        end
        assert_equal want, order, result.inspect
        assert_equal result == true, out.include?("Done."), "no false Done. after a refusal (#{result.inspect})"
        # The CLI exits 1 on false (scripts must see the stop), 0 on true.
        assert_equal result == true, @uninstalled, "uninstall's result (#{result.inspect})"
      end
    end

    # Value: protects=install refusals show as failures, not "installed ✓"; fails_when=the
    # unknown-result `else` swallows :unsafe/:conflict again; why_new=report_codex_install
    # formerly knew only :collision/:corrupt/nil; seam=none (pure reporter)
    def test_install_reports_unsafe_and_conflict_as_failures
      { unsafe: "can't be rewritten safely", conflict: "changed while switchboard was writing it",
        collision: "already has its own [hooks]", nil => "couldn't write" }.each do |result, text|
        out = silently { Installer.report_codex_install(result, reensure: true) }
        assert_includes out, text
        refute_match(/re-ensured|installed:/, out)
        # Value: protects=every refusal renders as a failure (✗), never a success tick;
        # fails_when=a refusal arm is switched to `ok`; why_new=the text was pinned, the glyph
        # wasn't; seam=none; no_claim=exit status (report_codex_install only prints)
        assert_includes out, "\e[31m✗\e[0m", result.inspect
        refute_includes out, "\e[32m✓\e[0m", result.inspect
      end
      # enable-hooks shares this reporter: a refusal there tells you to re-run enable-hooks.
      %i[unsafe conflict].each do |result|
        out = silently { Installer.report_codex_install(result, reensure: true, verb: "enable-hooks") }
        assert_includes out, "`switchboard enable-hooks`", result.to_s
        refute_includes out, "`switchboard install`", result.to_s
      end
    end

    # The installer runs in a fresh ruby for `switchboard install`'s helpers and for standalone
    # requires; every constant it reaches must be required by the file itself, not only by
    # lib/switchboard.rb (StablePath once wasn't — caught by QA in the uninstall error path).
    def test_installer_loads_on_its_own
      lib = File.expand_path("../lib", __dir__)
      out = IO.popen([RbConfig.ruby, "-I#{lib}", "-e", 'require "switchboard/installer"; puts Switchboard::Installer.repo_root'],
                     err: %i[child out], &:read)
      assert $?.success?, out
      assert_equal File.expand_path("..", __dir__), File.realpath(out.strip)
    end


    # Value: protects=the no-arg live probe (upgrade's leftovers check) testing the key switchboard
    # actually bound, its fallback included; fails_when=the default arg reverts to the configured
    # key or "s"; why_new=coverage gap; seam=none; no_claim=tmux's list-keys output format
    def test_toggle_key_live_with_no_argument_probes_the_bound_key
      raw = %(bind-key -T prefix F13 run-shell "'/x/switchboard' toggle-sidebar"\n)
      cmds = []
      fake = ->(cmd) { cmds << cmd; Kernel.send(:`, "true"); raw }
      result = stub_method(Installer, :tmux_server?, -> { true }) do
        stub_method(Installer, :bound_toggle_key, -> { "F13" }) do
          stub_method(Installer, :`, fake) { Installer.toggle_key_live? }
        end
      end
      assert_equal true, result
      assert_includes cmds.first, "-- F13", "probed the bound key, not the configured one"
    end

    # Value: protects=doctor and upgrade reading "no tmux server" as unknown, not "key
    # unbound" (tmux 3.8's list-keys starts a server and lists tmux's defaults);
    # fails_when=toggle_key_live? drops its server check; why_new=cycle-2 probe; seam=none
    def test_toggle_key_live_is_unknown_without_a_server
      stub_method(Installer, :tmux_server?, -> { false }) { assert_nil Installer.toggle_key_live?("s") }
      # Extended: a list-keys that would succeed (starting a server, listing tmux's defaults)
      # must not be asked at all. Value: fails_when=the server check is dropped (the bare
      # assertion above passed then, since this sandbox's list-keys fails); seam=none
      defaults = ->(_cmd) { Kernel.send(:`, "true"); %(bind-key -T prefix s choose-tree -Zs\n) }
      got = stub_method(Installer, :tmux_server?, -> { false }) do
        stub_method(Installer, :`, defaults) { Installer.toggle_key_live?("s") }
      end
      assert_nil got, "no server: unknown, not unbound"
    end

    # Value: protects=a tmux too old to take a key in list-keys still reading a bound toggle
    # as bound (from the whole table), and a failed read saying nothing either way; fails_when=
    # the fallback is dropped or a failed read reads as "not bound"; why_new=cycle-3 testing +
    # Red Team; seam=none; no_claim=which tmux versions lack the key argument
    def test_toggle_key_live_falls_back_to_the_whole_table
      full = %(bind-key -T prefix F13 run-shell "'/x/switchboard' toggle-sidebar"\n)
      table_ok = true
      fake = lambda do |cmd|
        ok = cmd.include?(" -- ") ? false : table_ok # the keyed form is "unsupported"
        Kernel.send(:`, ok ? "true" : "false")
        ok ? full : ""
      end
      live = -> { stub_method(Installer, :tmux_server?, -> { true }) { stub_method(Installer, :`, fake) { Installer.toggle_key_live?("F13") } } }
      assert_equal true, live.call
      table_ok = false
      assert_nil live.call, "neither read worked: unknown, not unbound"
    end


    # Value: protects=install and upgrade finding a tmux.conf tmux loads from
    # $XDG_CONFIG_HOME/tmux (tmux 3.2+) when no server can be asked, after ~/.tmux.conf;
    # fails_when=the XDG path drops out of the fallback, or jumps ahead of ~/.tmux.conf;
    # why_new=Red Team run 4 (D3); seam=none; no_claim=a running server (smoke)
    def test_tmux_conf_falls_back_in_tmuxs_own_order
      xdg = File.join(ENV["XDG_CONFIG_HOME"], "tmux", "tmux.conf")
      FileUtils.mkdir_p(File.dirname(xdg))
      File.write(xdg, "# mine\n")
      assert_equal xdg, Installer.tmux_conf
      home = File.expand_path("~/.tmux.conf")
      File.write(home, "# mine\n")
      assert_equal home, Installer.tmux_conf, "~/.tmux.conf first, as tmux reads it"
    end


    # Value: protects=install/upgrade picking the conf tmux actually started from, not a theme
    # or plugin file it sourced, with a real $HOME boundary; fails_when=the first listed file
    # under $HOME wins again, or the prefix match lets /home/will match /home/william;
    # why_new=security run 4 (D8); seam=none
    def test_loaded_user_conf_prefers_the_standard_conf_the_server_loaded
      home = File.expand_path("~")
      theme = File.join(home, "themes", "dark.conf")
      FileUtils.mkdir_p(File.dirname(theme))
      main = File.join(home, ".tmux.conf")
      [theme, main].each { |f| File.write(f, "# x\n") }
      listed = ->(*files) { ->(_cmd) { Kernel.send(:`, "true"); files.join(",") } }
      got = stub_method(Installer, :`, listed.call("/opt/tmux/main.conf", theme, main)) { Installer.loaded_user_conf }
      assert_equal main, got, "the standard conf beats a sourced file listed earlier"
      sibling = "#{home}x/.tmux.conf" # shares the prefix, not the directory
      FileUtils.mkdir_p(File.dirname(sibling))
      File.write(sibling, "# x\n")
      got = stub_method(Installer, :`, listed.call(sibling)) { Installer.loaded_user_conf }
      assert_nil got, "a path merely sharing $HOME's prefix isn't under it"
    end

    # Value: protects=a HOME of "/" (a service account) not making every loaded file read as
    # the user's conf; fails_when=the root-home guard is dropped; why_new=coverage audit
    # (proposed test 5); seam=none; no_claim=other odd HOME values
    def test_loaded_user_conf_is_nil_when_home_is_the_root
      sourced = path("plugins", "theme.conf")
      FileUtils.mkdir_p(File.dirname(sourced))
      File.write(sourced, "# x\n")
      ENV["HOME"] = "/"
      got = stub_method(Installer, :`, ->(_cmd) { Kernel.send(:`, "true"); sourced }) { Installer.loaded_user_conf }
      assert_nil got
    ensure
      ENV["HOME"] = @dir
    end

    # Value: protects=a conf the server loaded but that was since deleted never being picked
    # (upgrade would source a missing file); fails_when=the File.exist? filter is dropped;
    # why_new=coverage audit (proposed test 6); seam=none; no_claim=a conf replaced by a dir
    def test_loaded_user_conf_skips_a_listed_conf_that_no_longer_exists
      gone = File.expand_path("~/.tmux.conf") # a standard location, so it would win if kept
      kept = File.expand_path("~/confs/tmux.conf")
      FileUtils.mkdir_p(File.dirname(kept))
      File.write(kept, "# x\n")
      got = stub_method(Installer, :`, ->(_cmd) { Kernel.send(:`, "true"); "#{gone},#{kept}" }) { Installer.loaded_user_conf }
      assert_equal kept, got
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
