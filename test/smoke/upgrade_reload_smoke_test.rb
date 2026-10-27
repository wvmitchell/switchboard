# frozen_string_literal: true

require_relative "smoke_helper"
require_relative "fake_keg"

module Switchboard
  # Real-tmux proof that `upgrade --finish`, run from a shell with no $TMUX (as after
  # `brew upgrade` in a plain terminal), makes switchboard's bindings and hooks live again
  # in the running server — what the unit tests can only show as a stubbed `run-shell`.
  # The server here starts with the fragment applied (SmokeCase), and the test strips it
  # back to the "server still has the old wiring" state an upgrade leaves behind.
  class UpgradeReloadSmokeTest < SmokeCase
    include FakeKeg

    def write_project_and_config
      super
      ENV[CodeReload::SPREAD_ENV] = "0" # before boot: a reload never waits out the spread here
    end

    # The home sidebar runs from a fake keg, so a test can change the code on disk under a
    # running sidebar without moving its install root: only a signal can make it reload then.
    def spawn_home_sidebar
      @prefix = path("prefix")
      keg("A")
      point_opt_at("A")
      ENV["SWITCHBOARD_BIN"] = opt_bin
      super
    ensure
      ENV["SWITCHBOARD_BIN"] = BIN
    end
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

    # --- the sidebar reload at the end of finish (#48) ---------------------------

    # `upgrade --finish` run as the INSTALLED binary: a `switchboard` on PATH that is this
    # checkout's bin, which is what Installer.installed_bin? checks. Returns [ok, output].
    def finish_as_installed(installed: true)
      env = {}
      if installed
        dir = path("installed-bin")
        FileUtils.mkdir_p(dir)
        File.symlink(BIN, File.join(dir, "switchboard")) unless File.exist?(File.join(dir, "switchboard"))
        env["PATH"] = "#{dir}:#{ENV['PATH']}"
      end
      out = IO.popen(env, [BIN, "upgrade", "--finish", "0.0.1"], err: %i[child out], in: File::NULL, &:read)
      [$?.success?, out]
    end

    def home_sidebar = sidebar_pane_ids(HOME).first
    def pid_of(pane) = tmux("display-message", "-p", "-t", pane, fmt("pane_pid")).strip.to_i
    def tag_of(pane) = tmux("show-options", "-p", "-v", "-t", pane, CodeReload::TAG).strip

    # Value: protects=upgrade --finish reaching every running sidebar (#48 R1); fails_when=finish
    # stops calling the reload, or reload_all misses a tagged pane; why_new=the reload smoke drives
    # reload-sidebars, not finish; seam=PATH symlink as the installed binary; no_claim=Homebrew itself
    def test_finish_reloads_a_running_sidebar_in_place
      pane = home_sidebar
      pid = pid_of(pane)
      wait_until("the sidebar tags its pane") { tag_of(pane) == pid.to_s }
      patch_wordmark(File.join(@prefix, "Cellar", "switchboard", "A")) # new code on disk, same install root
      ok, out = finish_as_installed
      assert ok, out
      assert_includes out, "sidebars: 1 asked to reload in place"
      wait_until("the new code paints the pane") { capture(pane).include?(MARK_B) }
      assert_equal pid, pid_of(pane), "in place: same process"
    end

    # Value: protects=a sidebar too old for the signal is restarted by finish (R1);
    # fails_when=finish signals it (killing it) or skips it; seam=PATH symlink as the installed binary
    def test_finish_restarts_a_sidebar_too_old_to_reload_itself
      pane = home_sidebar
      pid = pid_of(pane)
      wait_until("the sidebar tags its pane") { tag_of(pane) == pid.to_s }
      tmux!("set-option", "-p", "-u", "-t", pane, CodeReload::TAG) # what a pre-0.59 sidebar looks like
      ok, out = finish_as_installed
      assert ok, out
      assert_includes out, "sidebars: 1 restarted"
      wait_until("a new process in the same pane") { pid_of(pane).positive? && pid_of(pane) != pid }
      assert_equal [pane], sidebar_pane_ids(HOME)
      wait_until("the restarted sidebar paints") { capture(pane).include?(Sidebar::WORDMARK) }
    end

    # Value: protects=a dogfood checkout's upgrade never reloads the installed sidebars (the
    # installed-binary rule); fails_when=the gate in Upgrade.reload_sidebars is dropped; seam=none
    def test_finish_from_another_copy_leaves_the_sidebars_alone
      pane = home_sidebar
      pid = pid_of(pane)
      wait_until("the sidebar tags its pane") { tag_of(pane) == pid.to_s }
      tmux!("set-option", "-p", "-u", "-t", pane, CodeReload::TAG) # untagged: a reload would respawn it
      _, out = finish_as_installed(installed: false)
      refute_includes out, "sidebars:"
      sleep 1 # a (wrong) respawn would land within this
      assert_equal pid, pid_of(pane), "untouched"
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
