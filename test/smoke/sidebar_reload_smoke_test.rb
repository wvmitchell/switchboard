# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # Real-tmux proof of #48: a running sidebar swaps in new code in its own pane. The
  # home sidebar runs from a FAKE Homebrew prefix — <tmp>/Cellar/switchboard/{A,B} are
  # copies of this checkout, <tmp>/opt/switchboard links to one — so StablePath gives it
  # the opt path, exactly as under brew, and "upgrading" is repointing that link. B's
  # wordmark is patched so the swap is visible on screen.
  class SidebarReloadSmokeTest < SmokeCase
    MARK_B = "◖═◗ SwitchboarB"

    def write_project_and_config
      super
      @proj2 = temp_git_repo("proj2")
      File.open(ENV["SWITCHBOARD_CONFIG"], "a") { |f| f.puts "  - name: proj2\n    path: #{@proj2}" }
      ENV[CodeReload::SPREAD_ENV] = "0" # before boot: every pane inherits it
    end

    def spawn_home_sidebar
      @prefix = path("prefix")
      keg("A")
      keg("B") { |root| patch_wordmark(root) }
      point_opt_at("A")
      ENV["SWITCHBOARD_BIN"] = File.join(@prefix, "opt", "switchboard", "bin", "switchboard")
      super
      @pane = sidebar_pane_ids(HOME).first
      @pid = pane_pid
      wait_until("the sidebar tags its pane with its pid") { tag == @pid.to_s }
    end

    def keg(name)
      root = File.join(@prefix, "Cellar", "switchboard", name)
      FileUtils.mkdir_p(root)
      FileUtils.cp_r(File.join(REPO, "bin"), root)
      FileUtils.cp_r(File.join(REPO, "lib"), root)
      yield root if block_given?
      root
    end

    def patch_wordmark(root)
      render = File.join(root, "lib", "switchboard", "sidebar", "render.rb")
      File.write(render, File.read(render).sub(Sidebar::WORDMARK, MARK_B))
    end

    def point_opt_at(name)
      opt = File.join(@prefix, "opt", "switchboard")
      FileUtils.mkdir_p(File.dirname(opt))
      FileUtils.rm_f(opt)
      File.symlink(File.join(@prefix, "Cellar", "switchboard", name), opt)
    end

    def break_keg(name)
      File.write(File.join(@prefix, "Cellar", "switchboard", name, "bin", "switchboard"), "#!/bin/sh\nexit 1\n")
    end

    def pane_pid = tmux("display-message", "-p", "-t", @pane, fmt("pane_pid")).strip.to_i
    def tag = tmux("show-options", "-p", "-v", "-t", @pane, CodeReload::TAG).strip

    # The row under the reverse-video cursor bar, or nil.
    def cursor_row
      tmux("capture-pane", "-e", "-p", "-t", @pane).lines.find { |l| l.match?(/\e\[(?:\d+;)*7m/) }.to_s.gsub(/\e\[[0-9;]*m/, "")
    end

    # Focus the sidebar (the bar only shows when focused) and move the cursor onto proj2.
    def put_cursor_on_proj2
      tmux!("select-pane", "-t", @pane)
      wait_until("the cursor bar shows") { !cursor_row.strip.empty? }
      wait_until("the cursor moves onto proj2") do
        tmux!("send-keys", "-t", @pane, "j") unless cursor_row.include?("proj2")
        cursor_row.include?("proj2")
      end
    end

    def assert_swapped_in_place
      wait_until("B's code paints the pane") { capture(@pane).include?(MARK_B) }
      assert_equal [@pane], sidebar_pane_ids(HOME), "the same pane, not a new one"
      assert_equal @pid, pane_pid, "exec keeps the pid: no respawn"
      wait_until("the new image re-tags its pane") { tag == @pid.to_s }
    end

    # Value: protects=a 0.59+ sidebar swaps code in its own pane, keeping pane id, pid and
    # cursor (R1, D1); fails_when=the trap, wake, exec, resume or setup-clear regress;
    # why_new=no test exec'd a sidebar before; seam=fake brew prefix;
    # no_claim=Homebrew's own install steps (fake Cellar/opt links stand in)
    def test_reload_sidebars_swaps_the_code_in_place
      put_cursor_on_proj2
      point_opt_at("B")
      assert run_bin("reload-sidebars"), "the verb exits 0"
      assert_swapped_in_place
      assert_includes cursor_row, "proj2", "the cursor rode the payload across exec"
    end

    # Value: protects=a plain `brew upgrade` (nobody signals) still reloads (planning D3);
    # fails_when=the tick backstop is dropped; seam=fake brew prefix
    def test_a_moved_keg_alone_reloads_within_a_tick
      point_opt_at("B")
      assert_swapped_in_place
    end

    # Value: protects=a release that can't load never kills a pane (preflight); fails_when=the
    # preflight is skipped or ignored; seam=none; no_claim=raises after load
    def test_a_broken_release_leaves_the_old_sidebar_running
      put_cursor_on_proj2
      break_keg("B")
      point_opt_at("B")
      run_bin("reload-sidebars")
      sleep 2 # give a (wrong) exec time to happen: what we assert is that nothing changes
      assert ProcessIdentity.alive?(@pid), "same process, alive"
      assert_equal [@pane], sidebar_pane_ids(HOME)
      assert_includes capture(@pane), Sidebar::WORDMARK, "still A's frame"
      wait_until("it still answers keys") do
        tmux!("send-keys", "-t", @pane, "k")
        !cursor_row.include?("proj2")
      end
    end

    # Value: protects=an older (untagged) sidebar is restarted by its own start command and
    # paints (R1); fails_when=respawn passes a command, drops -e, or the restarted process
    # doesn't paint; seam=none; no_claim=real 0.57 code (an untagged copy stands in)
    def test_an_untagged_sidebar_is_restarted_by_its_own_command
      tmux!("set-option", "-p", "-u", "-t", @pane, CodeReload::TAG) # what a pre-0.59 sidebar looks like
      assert run_bin("reload-sidebars")
      wait_until("a new process in the same pane") { pane_pid.positive? && pane_pid != @pid }
      assert_equal [@pane], sidebar_pane_ids(HOME), "respawn keeps the pane and its title"
      wait_until("the restarted sidebar paints") { capture(@pane).include?(Sidebar::WORDMARK) }
      wait_until("...and tags itself") { tag == pane_pid.to_s }
    end

    # Value: protects=overlapping reloads never kill a sidebar mid-boot (R4); fails_when=USR1
    # isn't ignored across exec or the tag isn't cleared; seam=none
    def test_back_to_back_reloads_leave_the_sidebar_alive
      point_opt_at("B")
      3.times { run_bin("reload-sidebars") }
      assert_swapped_in_place
      run_bin("reload-sidebars")
      sleep 1
      assert ProcessIdentity.alive?(@pid)
      assert_equal [@pane], sidebar_pane_ids(HOME)
      wait_until("still painting B") { capture(@pane).include?(MARK_B) }
    end
  end
end
