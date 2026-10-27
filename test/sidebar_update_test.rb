# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # The sidebar's update line (#47): the header it draws, when it reads the cache, the
  # warm-gate entries that repaint hidden panes, and the gates on the background check.
  class SidebarUpdateTest < SidebarCase
    LINE = "↑ 0.57.0 available · switchboard upgrade"

    def with_cue(sb, cue = "0.57.0")
      sb.instance_variable_set(:@update_cue, cue)
      sb
    end

    # A sidebar that counts as the installed Homebrew binary, without a `command -v`.
    def applying(sb)
      sb.instance_variable_set(:@update_applies, true)
      sb
    end

    def version_file(version)
      file = path("keg", "version.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, "module Switchboard\n  VERSION = \"#{version}\"\nend\n")
      file
    end

    # --- the header (option K) ----------------------------------------------

    def test_the_line_sits_under_the_wordmark_off_home
      head = with_cue(sidebar(nodes: [proj("app"), ws("a")])).send(:header, 40)
      assert_equal 2, head.size
      assert_includes head[0], Sidebar::WORDMARK
      assert_equal LINE, strip_ansi(head[1]), "the full line is exactly 40 cols"
      assert_includes head[1], "#{Sidebar::UPDATE_FG}↑ 0.57.0 available\e[0m", "the message in yellow"
      assert_includes head[1], "#{Sidebar::NOTE_FG} · switchboard upgrade\e[0m", "the command dim"
    end

    def test_on_home_the_line_comes_before_the_greeting
      sb = with_cue(sidebar(nodes: [proj("app"), ws("a")]))
      sb.instance_variable_set(:@home, true)
      head = sb.send(:header, 40)
      assert_equal 5, head.size, "wordmark, update, greeting, console, rule"
      assert_equal LINE, strip_ansi(head[1])
      assert_match(/good /, strip_ansi(head[2]))
    end

    def test_no_cue_no_line
      assert_equal 1, sidebar(nodes: [proj("app")]).send(:header, 40).size
    end

    def test_a_narrow_pane_drops_the_command_then_cuts_the_message
      sb = with_cue(sidebar)
      assert_equal "↑ 0.57.0 available", strip_ansi(sb.send(:header, 39)[1]), "one col short: the command half goes"
      cut = sb.send(:header, 10)[1]
      assert_equal "↑ 0.57.0 …", strip_ansi(cut)
      assert cut.start_with?(Sidebar::UPDATE_FG) && cut.end_with?("\e[0m"), "the escape is never split"
    end

    def test_the_tree_starts_one_row_lower_while_the_line_shows
      sb = with_cue(sidebar(nodes: [proj("app"), ws("a")]))
      out = stub_method(sb, :winsize, -> { [12, 40] }) { capture_stdout { sb.send(:render) } }
      assert_includes out, "\e[2;1H\e[K#{sb.send(:header, 40)[1]}", "the update line on row 2"
      assert_match(/\e\[3;1H\e\[K[^\e]*(\e\[[0-9;]*m)*[^\n]*app/, out, "the tree starts on row 3")
    end

    # --- reading the cache (rebuild) ----------------------------------------

    def test_refresh_reads_a_newer_cached_release
      sb = applying(sidebar)
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      sb.send(:refresh_update_cue)
      assert_equal "99.0.0", sb.instance_variable_get(:@update_cue)

      UpdateCheck.write("latest" => VERSION, "checked_at" => 1)
      sb.send(:refresh_update_cue)
      assert_nil sb.instance_variable_get(:@update_cue), "current: no line"
    end

    # Value: protects=the line clears once the upgrade lands, while this process still runs
    # the old code (D2); fails_when=refresh compares the loaded VERSION; seam=version_file stub
    def test_refresh_compares_against_the_installed_version_file
      sb = applying(sidebar)
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      file = version_file("98.0.0")
      stub_method(UpdateCheck, :version_file, -> { file }) do
        sb.send(:refresh_update_cue)
        assert_equal "99.0.0", sb.instance_variable_get(:@update_cue)

        File.write(file, "VERSION = \"99.0.0\"\n")
        File.utime(Time.now + 5, Time.now + 5, file) # the keg swap moves its mtime
        sb.send(:refresh_update_cue)
        assert_nil sb.instance_variable_get(:@update_cue), "upgraded: the line clears without a restart"
      end
    end

    def test_refresh_shows_nothing_when_off_or_not_brew
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      sb = sidebar
      sb.instance_variable_set(:@update_applies, false)
      sb.send(:refresh_update_cue)
      assert_nil sb.instance_variable_get(:@update_cue), "a clone or dogfood checkout"
      assert_nil sb.instance_variable_get(:@update_seen)

      File.write(Config.path, YAML.dump("update_check" => false))
      sb = applying(sidebar)
      sb.send(:refresh_update_cue)
      assert_nil sb.instance_variable_get(:@update_cue), "update_check: false"
    end

    def test_the_sandbox_shows_a_seeded_line_without_the_brew_match
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      ENV["SWITCHBOARD_SANDBOX"] = "1"
      sb = sidebar
      sb.instance_variable_set(:@update_applies, false)
      sb.send(:refresh_update_cue)
      assert_equal "99.0.0", sb.instance_variable_get(:@update_cue)
    end

    # --- the warm gate (D12) --------------------------------------------------

    # Value: protects=a hidden pane repaints a cache write that landed between rebuild and
    # reload's baseline; fails_when=reload samples the update entry fresh; seam=none
    def test_reload_baselines_the_cache_it_read_not_a_fresh_stat
      sb = applying(sidebar(nodes: [proj("app")]))
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      sb.send(:refresh_update_cue) # what rebuild read
      later = Time.now + 30
      File.utime(later, later, UpdateCheck.cache_path) # the child writes again, mid-reload
      %i[rebuild locate refresh_diffs].each { |m| sb.define_singleton_method(m) {} }
      sb.define_singleton_method(:refresh_agents) { |**| true }
      sb.instance_variable_get(:@edges).define_singleton_method(:refresh_stale_prs) { |_| }
      sb.define_singleton_method(:maybe_check_update) {}
      sb.send(:reload)
      refute_equal sb.instance_variable_get(:@warm_fp), sb.send(:warm_fingerprint),
                   "the next off-screen tick sees a change, so it warms"
    end

    def test_an_installed_version_bump_moves_the_warm_fingerprint
      sb = applying(sidebar(nodes: [proj("app")]))
      file = version_file("0.57.0")
      stub_method(UpdateCheck, :version_file, -> { file }) do
        before = sb.send(:warm_fingerprint)
        File.utime(Time.now + 30, Time.now + 30, file)
        refute_equal before, sb.send(:warm_fingerprint), "a hidden pane repaints after the upgrade lands"
      end
    end

    def test_the_update_entry_is_nil_while_the_line_is_off
      sb = sidebar
      sb.instance_variable_set(:@update_applies, false)
      assert_nil sb.send(:update_fingerprint), "no stats, and no baseline mismatch with reload's nil"
    end

    # --- the background check's gates ----------------------------------------

    def spawns(sb)
      spawned = []
      stub_method(Process, :spawn, ->(*args, **) { spawned << args; 4242 }) do
        stub_method(Process, :detach, ->(_pid) {}) { sb.send(:maybe_check_update) }
      end
      spawned
    end

    def armed
      ENV["SWITCHBOARD_BIN"] = "/opt/homebrew/bin/switchboard"
      ENV.delete(UpdateCheck::DISABLE_ENV)
      applying(sidebar)
    end

    def test_spawns_check_update_once_when_due_and_claims_first
      sb = armed
      assert_equal [["/opt/homebrew/bin/switchboard", "check-update"]], spawns(sb)
      refute UpdateCheck.due?, "the attempt file was touched before the spawn"
      assert_empty spawns(sb), "this pane's debounce"
      assert_empty spawns(armed), "another pane right after reads not due"
    end

    def test_no_spawn_when_any_gate_says_no
      assert_empty spawns(armed.tap { ENV[UpdateCheck::DISABLE_ENV] = "1" }), "kill switch"
      assert_empty spawns(armed.tap { ENV["SWITCHBOARD_SANDBOX"] = "1" }), "the sandbox never fetches"
      assert_empty spawns(armed.tap { ENV.delete("SWITCHBOARD_BIN") }), "no wrapper"
      assert_empty spawns(armed.tap { |sb| sb.instance_variable_set(:@update_applies, false) }), "not the brew binary"
      File.write(Config.path, YAML.dump("update_check" => false))
      assert_empty spawns(armed), "update_check: false"
    end

    def test_no_spawn_while_the_answer_is_fresh
      UpdateCheck.write("latest" => "0.1.0", "checked_at" => 1)
      assert_empty spawns(armed)
    end
  end
end
