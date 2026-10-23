# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # Real-tmux proof that `upgrade --finish`, run from a shell with no $TMUX (as after
  # `brew upgrade` in a plain terminal), makes switchboard's bindings and hooks live again
  # in the running server — what the unit tests can only show as a stubbed `run-shell`.
  # The server here starts with the fragment applied (SmokeCase), and the test strips it
  # back to the "server still has the old wiring" state an upgrade leaves behind.
  class UpgradeReloadSmokeTest < SmokeCase
    def strip_live_wiring
      Installer::HOOK_SLOTS.each { |slot| tmux!("set-hook", "-gu", slot) }
      tmux!("unbind-key", "-T", "prefix", "s")
      wait_until("the wiring is gone") { !live_hooks_on? && !toggle_bound? }
    end

    def live_hooks_on?
      hooks = tmux("show-hooks", "-g")
      Installer::HOOK_SLOTS.all? { |slot| hooks.include?(slot) }
    end

    def toggle_bound?
      tmux("list-keys", "-T", "prefix").lines.any? { |l| l =~ /\s+s\s+.*toggle-sidebar/ }
    end

    def wire_tmux_conf(body)
      File.write(File.join(ENV["HOME"], ".tmux.conf"), body)
    end

    # Value: protects=a plain-shell upgrade leaving new keys/hooks live; fails_when=the
    # reload is gated on $TMUX, or run-shell's argument is mis-quoted; why_new=unit tests
    # stub run_tmux; seam=none; no_claim=a server on a custom -L socket
    def test_finish_from_a_plain_shell_brings_bindings_and_hooks_back
      wire_tmux_conf(Installer.with_block(""))
      strip_live_wiring
      refute ENV["TMUX"], "the binary runs as from a plain shell"

      assert run_bin("upgrade", "--finish", "0.0.1"), "finish succeeds"
      assert live_hooks_on?, "all three hook slots live again"
      assert toggle_bound?, "prefix-s bound to toggle-sidebar again"
    end

    # Value: protects=--no-tmux installs; fails_when=the wired-here gate is dropped;
    # why_new=new; seam=none
    def test_finish_leaves_an_unwired_tmux_alone
      wire_tmux_conf("set -g mouse on\n")
      strip_live_wiring
      assert run_bin("upgrade", "--finish", "0.0.1")
      refute live_hooks_on?, "no switchboard hooks forced onto a tmux that never sourced them"
    end

    # Value: protects=a toggle key written the way tmux accepts but lists differently (`^B`
    # is listed `C-b`, `M-#` quoted, `C-\` doubled) reading as bound, not a forever-stale
    # upgrade; fails_when=toggle_key_live? goes back to matching the listing literally;
    # why_new=cycle-2 Red Team (my cycle-1 normalizer missed these); seam=none
    def test_tmux_resolves_the_configured_key_spelling
      keys = ["^B", "M-#", "C-\\", "f5", "M-C-x", "$"]
      keys.each { |k| tmux!("bind-key", "-T", "prefix", k, "run-shell", "true toggle-sidebar") }
      keys.each { |k| assert_equal true, Installer.toggle_key_live?(k), k }
      assert_equal false, Installer.toggle_key_live?("F12"), "an unbound key"
      tmux!("bind-key", "-T", "prefix", "F11", "display-message", "hi")
      assert_equal false, Installer.toggle_key_live?("F11"), "a foreign binding isn't ours"
    end

    # Value: protects=a `;` toggle key not reading as bound just because SOME prefix key runs
    # toggle-sidebar (an unescaped `;` ends the tmux command, so `list-keys -T prefix` lists the
    # whole table); fails_when=the key's trailing `;` is passed unescaped; why_new=Red Team
    # cycle 3 (verified on tmux 3.8); seam=none
    def test_a_semicolon_key_is_probed_as_itself
      tmux!("bind-key", "-T", "prefix", "F9", "run-shell", "true toggle-sidebar") # some other toggle binding
      assert_equal false, Installer.toggle_key_live?(";"), "unbound ; with another toggle bound"
      tmux!("bind-key", "-T", "prefix", "\\;", "run-shell", "true toggle-sidebar")
      assert_equal true, Installer.toggle_key_live?(";")
    end

    # Value: protects=a plain-shell upgrade finding the tmux.conf the RUNNING server loaded
    # (an XDG or --tmux-conf file), not only ~/.tmux.conf; fails_when=loaded_user_conf is
    # gated on $TMUX again; why_new=Red Team run 4 (D3); seam=none
    def test_the_loaded_conf_is_found_from_outside_tmux
      conf = File.join(ENV["HOME"], ".config", "elsewhere", "tmux.conf")
      FileUtils.mkdir_p(File.dirname(conf))
      File.write(conf, "set -g status on\n")
      tmux!("kill-server")
      wait_until("old server gone") { !tmux!("has-session") }
      tmux!("-f", conf, "new-session", "-d", "-s", "conf-probe")
      refute ENV["TMUX"], "asked from outside tmux"
      assert_equal File.realpath(conf), File.realpath(Installer.loaded_user_conf.to_s)
    end
  end
end
