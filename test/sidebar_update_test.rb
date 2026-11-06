# frozen_string_literal: true

require_relative "support/sidebar_case"

module Switchboard
  # The sidebar's update line (#47): the header it draws, when it reads the cache, the
  # warm-gate entries that repaint hidden panes, and the gates on the background check.
  class SidebarUpdateTest < SidebarCase
    LINE = "↑ 0.57.0 available · switchboard upgrade"

    def update_of(sb) = sb.instance_variable_get(:@update)

    def config_of(sb) = sb.instance_variable_get(:@config)

    def with_cue(sb, cue = "0.57.0")
      update_of(sb).instance_variable_set(:@cue, cue)
      sb
    end

    # A sidebar that counts as the installed Homebrew binary, without a `command -v`.
    def applying(sb)
      update_of(sb).instance_variable_set(:@applies, true)
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
      update_of(sb).refresh(config_of(sb))
      assert_equal "99.0.0", update_of(sb).cue

      UpdateCheck.write("latest" => VERSION, "checked_at" => 1)
      update_of(sb).refresh(config_of(sb))
      assert_nil update_of(sb).cue, "current: no line"
    end

    # Value: protects=the line clears once the upgrade lands, while this process still runs
    # the old code (D2); fails_when=refresh compares the loaded VERSION; seam=version_file stub
    def test_refresh_compares_against_the_installed_version_file
      sb = applying(sidebar)
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      file = version_file("98.0.0")
      stub_method(UpdateCheck, :version_file, -> { file }) do
        update_of(sb).refresh(config_of(sb))
        assert_equal "99.0.0", update_of(sb).cue

        File.write(file, "VERSION = \"99.0.0\"\n")
        File.utime(Time.now + 5, Time.now + 5, file) # the keg swap moves its mtime
        update_of(sb).refresh(config_of(sb))
        assert_nil update_of(sb).cue, "upgraded: the line clears without a restart"
      end
    end

    def test_refresh_shows_nothing_when_off_or_not_brew
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      sb = sidebar
      update_of(sb).instance_variable_set(:@applies, false)
      update_of(sb).refresh(config_of(sb))
      assert_nil update_of(sb).cue, "a clone or dogfood checkout"
      assert_nil update_of(sb).seen

      File.write(Config.path, YAML.dump("update_check" => false))
      sb = applying(sidebar)
      update_of(sb).refresh(config_of(sb))
      assert_nil update_of(sb).cue, "update_check: false"
    end

    def test_the_sandbox_shows_a_seeded_line_without_the_brew_match
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      ENV["SWITCHBOARD_SANDBOX"] = "1"
      sb = sidebar
      update_of(sb).instance_variable_set(:@applies, false)
      update_of(sb).refresh(config_of(sb))
      assert_equal "99.0.0", update_of(sb).cue
    end

    # --- the warm gate (D12) --------------------------------------------------

    # Value: protects=a hidden pane repaints a cache write that landed between rebuild and
    # reload's baseline; fails_when=reload samples the update entry fresh; seam=none
    def test_reload_baselines_the_cache_it_read_not_a_fresh_stat
      sb = applying(sidebar(nodes: [proj("app")]))
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      update_of(sb).refresh(config_of(sb)) # what rebuild read
      later = Time.now + 30
      File.utime(later, later, UpdateCheck.cache_path) # the child writes again, mid-reload
      %i[rebuild locate refresh_diffs].each { |m| sb.define_singleton_method(m) {} }
      sb.define_singleton_method(:refresh_agents) { |**| true }
      sb.instance_variable_get(:@edges).define_singleton_method(:refresh_stale_prs) { |_| }
      update_of(sb).define_singleton_method(:maybe_check) { |_| }
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
      update_of(sb).instance_variable_set(:@applies, false)
      assert_nil update_of(sb).fingerprint(config_of(sb)), "no stats, and no baseline mismatch with reload's nil"
    end

    # --- the background check's gates ----------------------------------------

    def spawns(sb)
      spawned = []
      stub_method(Process, :spawn, ->(*args, **) { spawned << args; 4242 }) do
        stub_method(Process, :detach, ->(_pid) {}) { update_of(sb).maybe_check(config_of(sb)) }
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
      assert_empty spawns(armed.tap { |sb| update_of(sb).instance_variable_set(:@applies, false) }), "not the brew binary"
      File.write(Config.path, YAML.dump("update_check" => false))
      assert_empty spawns(armed), "update_check: false"
    end

    # Value: protects=the sidebar's two call sites into the cue, with its current config; fails_when=rebuild
    # stops refreshing the line, or reload stops asking for a check; why_new=the moved code's tests call
    # the cue directly, and reload's stub it; seam=none; no_claim=a real scan
    def test_rebuild_and_reload_drive_the_cue
      sb = applying(sidebar(nodes: [proj("app")]))
      calls = []
      update_of(sb).define_singleton_method(:refresh) { |config| calls << [:refresh, config] }
      update_of(sb).define_singleton_method(:maybe_check) { |config| calls << [:check, config] }
      sb.send(:rebuild)
      assert_equal [[:refresh, config_of(sb)]], calls
      calls.clear
      %i[rebuild locate refresh_diffs].each { |m| sb.define_singleton_method(m) {} }
      sb.define_singleton_method(:refresh_agents) { |**| true }
      sb.instance_variable_get(:@edges).define_singleton_method(:refresh_stale_prs) { |_| }
      sb.send(:reload)
      assert_equal [[:check, config_of(sb)]], calls
    end

    # Value: protects=a pane asking for a check at most once a minute; fails_when=the debounce goes, so
    # every reload stats the cache again; why_new=the second-spawn test passes on the claim alone;
    # seam=stubs due?; no_claim=the wall clock
    def test_a_pane_only_asks_once_inside_the_window
      sb = armed
      asked = 0
      stub_method(UpdateCheck, :due?, -> { asked += 1; false }) { 2.times { spawns(sb) } }
      assert_equal 1, asked
    end

    # Value: protects=the line following the config the sidebar holds now, since a reload reassigns it;
    # fails_when=the cue pins the config it first saw; why_new=holding its own copy is the easy mistake
    # in this shape; seam=none; no_claim=none beyond protects
    def test_the_line_follows_a_reassigned_config
      sb = applying(sidebar)
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      assert_equal "99.0.0", update_of(sb).refresh(config_of(sb))
      File.write(Config.path, YAML.dump("update_check" => false))
      sb.instance_variable_set(:@config, Config.new)
      update_of(sb).refresh(config_of(sb))
      assert_nil update_of(sb).cue
      assert_nil update_of(sb).seen, "reload's baseline clears with the line"
      assert_nil sb.send(:warm_fingerprint)[-2], "the warm gate's update entry goes quiet too"
    end

    def test_no_spawn_while_the_answer_is_fresh
      UpdateCheck.write("latest" => "0.1.0", "checked_at" => 1)
      assert_empty spawns(armed)
    end

    # Value: protects=a long-running pane checking again once its window elapses; fails_when=the window
    # never reopens, so the pane stops checking for good; why_new=the debounce tests stay inside the window;
    # seam=none; no_claim=the wall clock
    def test_a_pane_asks_again_once_the_window_elapses
      sb = armed
      now = 1000.0
      stub_method(Process, :clock_gettime, ->(*) { now }) do
        stub_method(UpdateCheck, :due?, -> { true }) do
          spawns(sb)
          now += Sidebar::UpdateCue::SPAWN_TTL
          assert_equal [["/opt/homebrew/bin/switchboard", "check-update"]], spawns(sb)
        end
      end
    end

    # Value: protects=a binary that can't be spawned leaving the reload running; fails_when=the rescue goes
    # and the error reaches the run loop; why_new=every other test's spawn succeeds; seam=none;
    # no_claim=other exception classes
    def test_a_failed_spawn_returns_nil_instead_of_raising
      sb = armed
      tries = 0
      outcome = stub_method(Process, :spawn, ->(*, **) { tries += 1; raise Errno::ENOENT }) do
        update_of(sb).maybe_check(config_of(sb))
      rescue Errno::ENOENT => e
        e
      end
      assert_equal 1, tries, "it did try"
      assert_nil outcome
    end

    # Value: protects=seen lagging what refresh drew, never leading it; fails_when=the stat moves after the
    # read, baselining a write that wasn't drawn; why_new=the reload test only pins that reload uses seen;
    # seam=none; no_claim=a real concurrent writer
    def test_refresh_stats_the_cache_before_reading_it
      sb = applying(sidebar)
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      cache = UpdateCheck.cache_path
      drawn = File.mtime(cache).to_f
      later = Time.now + 30
      read = UpdateCheck.method(:read)
      write_during_read = lambda do |*|
        read.call.tap { File.utime(later, later, cache) }
      end
      stub_method(UpdateCheck, :read, write_during_read) { update_of(sb).refresh(config_of(sb)) }
      assert_equal "99.0.0", update_of(sb).cue
      assert_equal drawn, update_of(sb).seen[0], "the baseline predates the write"
      assert_equal later.to_f, File.mtime(cache).to_f, "the write did land mid-read"
    end

    # Value: protects=an unparseable version.rb comparing against the loaded VERSION; fails_when=the
    # fallback goes and the line silently disappears; why_new=every other version.rb parses; seam=none;
    # no_claim=a missing version.rb
    def test_an_unparseable_version_file_falls_back_to_the_loaded_version
      sb = applying(sidebar)
      file = version_file("0.0.1")
      File.write(file, "not a version\n")
      stub_method(UpdateCheck, :version_file, -> { file }) do
        UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
        update_of(sb).refresh(config_of(sb))
        assert_equal "99.0.0", update_of(sb).cue

        UpdateCheck.write("latest" => VERSION, "checked_at" => 1)
        update_of(sb).refresh(config_of(sb))
        assert_nil update_of(sb).cue, "level with the loaded VERSION: no line"
      end
    end

    # Value: protects=update_check: false hiding the line in the sandbox too; fails_when=show? asks the
    # sandbox first; why_new=the opt-out and the sandbox are only tested apart; seam=none; no_claim=fetching
    def test_the_opt_out_beats_the_sandbox
      UpdateCheck.write("latest" => "99.0.0", "checked_at" => 1)
      ENV["SWITCHBOARD_SANDBOX"] = "1"
      sb = sidebar
      update_of(sb).refresh(config_of(sb))
      assert_equal "99.0.0", update_of(sb).cue, "the sandbox shows it until opted out"

      File.write(Config.path, YAML.dump("update_check" => false))
      update_of(sb).refresh(Config.new)
      assert_nil update_of(sb).cue
      assert_nil update_of(sb).seen
    end
  end
end
