# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # CodeReload (#48): the pure pieces behind a sidebar swapping in new code in place —
  # the moved-keg check, the preflight, and the resume payload handed across exec.
  class CodeReloadTest < SandboxTest
    # A fake install: <root>/bin/switchboard (an executable script) under <root>.
    def install(root, script = "#!/bin/sh\nexit 0\n")
      bin = path(root, "bin", "switchboard")
      FileUtils.mkdir_p(File.dirname(bin))
      File.write(bin, script)
      File.chmod(0o755, bin)
      bin
    end

    # --- stale?: the backstop (planning D3, Homebrew only) --------------------

    def test_stale_when_the_bin_now_resolves_to_another_install
      a = install("Cellar/a")
      install("Cellar/b")
      FileUtils.mkdir_p(path("opt"))
      File.symlink(path("Cellar/a"), path("opt/switchboard"))
      bin = path("opt/switchboard/bin/switchboard")
      loaded = File.expand_path("../..", File.realpath(a))

      stub_const(:LOADED_ROOT, loaded) do
        refute CodeReload.stale?(bin), "opt still points at the keg we loaded"
        File.unlink(path("opt/switchboard"))
        File.symlink(path("Cellar/b"), path("opt/switchboard"))
        assert CodeReload.stale?(bin), "brew upgrade repointed opt at a new keg"
      end
    end

    def test_not_stale_for_this_checkout_or_an_unknown_bin
      refute CodeReload.stale?(File.join(CodeReload::LOADED_ROOT, "bin", "switchboard")),
             "a clone's root never moves"
      refute CodeReload.stale?(nil)
      refute CodeReload.stale?("")
      refute CodeReload.stale?(path("gone", "bin", "switchboard")), "an unresolvable bin is not a reason to exec"
    end

    # --- preflight ------------------------------------------------------------

    def test_preflight_passes_a_binary_that_runs_version
      assert CodeReload.preflight(install("ok"))
    end

    def test_preflight_fails_a_broken_missing_or_hung_binary
      refute CodeReload.preflight(install("broken", "#!/bin/sh\nexit 1\n")), "non-zero exit"
      refute CodeReload.preflight(path("nope", "bin", "switchboard")), "ENOENT"
      hung = install("hung", "#!/bin/sh\nsleep 30\n")
      started = Time.now
      refute CodeReload.preflight(hung, secs: 0.3), "past the bound"
      assert_operator Time.now - started, :<, 5, "the hang is killed, not waited out"
    end

    # Value: protects=a sidebar started under system Ruby can still reload (R6);
    # fails_when=the preflight inherits SB_REEXEC; seam=none
    def test_preflight_runs_without_the_reexec_guard
      seen = path("seen")
      bin = install("env", "#!/bin/sh\nprintf '%s' \"${SB_REEXEC-unset}\" > #{seen}\n")
      ENV["SB_REEXEC"] = "1"
      assert CodeReload.preflight(bin)
      assert_equal "unset", File.read(seen)
    end

    def test_preflight_gives_the_child_no_stdin
      seen = path("stdin.out")
      bin = install("stdin", "#!/bin/sh\nif read -r line; then echo read > #{seen}; else echo eof > #{seen}; fi\n")
      assert CodeReload.preflight(bin)
      assert_equal "eof", File.read(seen).strip, "a broken binary can't read the pane's keys"
    end

    # --- the resume payload (cross-version contract, v1) ----------------------

    def test_payload_round_trip
      raw = CodeReload.encode(cursor: { "kind" => "ws", "project" => "app", "path" => "/wt/a", "branch" => nil },
                              offset: 3, hook_states: { "/wt/a" => :done, "/wt/b" => :thinking },
                              notify: { "/wt/a" => Time.at(12, 345_678_901, :nsec) }, announce: true)
      got = CodeReload.decode(raw)
      assert_equal({ "kind" => "ws", "project" => "app", "path" => "/wt/a", "branch" => nil }, got[:cursor])
      assert_equal 3, got[:offset]
      assert_equal({ "/wt/a" => :done, "/wt/b" => :thinking }, got[:hook_states])
      assert_equal({ "/wt/a" => Time.at(12, 345_678_901, :nsec) }, got[:notify], "exact to the nanosecond")
      assert got[:announce]
    end

    def test_payload_garbage_wrong_version_or_oversized_is_a_cold_start
      assert_nil CodeReload.decode(nil)
      assert_nil CodeReload.decode("")
      assert_nil CodeReload.decode("{nope")
      assert_nil CodeReload.decode("[1]")
      assert_nil CodeReload.decode(JSON.generate("v" => 2))
      assert_nil CodeReload.decode(JSON.generate("v" => 1, "pad" => "x" * CodeReload::PAYLOAD_MAX))
      assert_nil CodeReload.decode("\xff\xfe".b)
    end

    def test_payload_drops_only_the_bad_fields
      got = CodeReload.decode(JSON.generate("v" => 1, "cursor" => { "kind" => 7 }, "offset" => -2,
                                            "hook_states" => { "/a" => "done", "/b" => "exploded", "/c" => 3 },
                                            "notify" => { "/a" => "soon", "/b" => [4, 5], "/c" => 4.5, "/d" => [1, 2, 3] }))
      assert_nil got[:cursor]
      assert_equal 0, got[:offset]
      assert_equal({ "/a" => :done }, got[:hook_states])
      assert_equal({ "/b" => Time.at(4, 5, :nsec) }, got[:notify])
    end

    # Value: protects=a switch-in reload never replays heard chimes (R7);
    # fails_when=a missing field reads as announce; seam=none
    def test_a_payload_without_announce_is_silent
      refute CodeReload.decode(JSON.generate("v" => 1))[:announce]
    end

    def test_take_resume_removes_the_variable
      ENV[CodeReload::RESUME_ENV] = CodeReload.encode(offset: 1)
      assert_equal 1, CodeReload.take_resume[:offset]
      refute ENV.key?(CodeReload::RESUME_ENV), "children must never inherit a resume payload"
      assert_nil CodeReload.take_resume, "absent: a cold start"
    end

    # --- reaching every sidebar (R1, R2, R5) -----------------------------------

    def test_parse_reload_targets_splits_tagged_from_old
      raw = "%1\t101\t101\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n" \
            "%2\t102\t\tsb-sidebar\t\"/my dir/bin/switchboard\" sidebar\n" \
            "%3\t103\t99\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n" \
            "%4\t104\t104\tzsh\tzsh\n" \
            "%5\t105\t\tsb-sidebar\t\"unbalanced\n"
      got = Tmux.parse_reload_targets(raw).map { |t| [t.pane, t.pid, t.tagged, t.bin] }
      assert_equal [["%1", 101, true, "/opt/sb/bin/switchboard"],
                    ["%2", 102, false, "/my dir/bin/switchboard"],
                    ["%3", 103, false, "/opt/sb/bin/switchboard"], # a stale tag: respawned, never signaled
                    ["%5", 105, false, nil]], got, "only sidebar panes; a tag must equal the pane's pid"
    end

    def reload_with(targets, preflight: ->(_bin) { true }, respawn_ok: true)
      log = []
      counts = stub_method(Tmux, :sidebar_reload_targets, -> { targets }) do
        stub_method(Tmux, :signal_sidebar, ->(t) { log << [:signal, t.pane]; true }) do
          stub_method(Tmux, :respawn_sidebar, ->(t, marker) { log << [:respawn, t.pane, CodeReload.decode(marker).nil?]; respawn_ok }) do
            stub_method(CodeReload, :preflight, ->(bin) { log << [:preflight, bin]; preflight.call(bin) }) { CodeReload.reload_all }
          end
        end
      end
      [counts, log]
    end

    def target(pane, tagged:, bin: nil)
      Tmux::ReloadTarget.new(pane: pane, pid: 1, tagged: tagged, bin: bin)
    end

    # Value: protects=upgrade reloads every sidebar, old ones by their own start command (R1);
    # fails_when=an old sidebar gets the signal (its default action kills it) or isn't restarted;
    # seam=none; no_claim=real tmux (Tmux stubbed; the smoke test runs it)
    def test_reload_all_signals_new_sidebars_and_respawns_old_ones
      good = install("good")
      counts, log = reload_with([target("%1", tagged: true), target("%2", tagged: false, bin: good)])
      assert_equal({ signaled: 1, respawned: 1, left: 0 }, counts)
      assert_includes log, [:signal, "%1"]
      assert_includes log, [:respawn, "%2", false], "with a decodable resume marker"
      refute_includes log, [:preflight, nil]
    end

    # Value: protects=no sidebar vanishes on upgrade (R2, R5); fails_when=a missing, unparseable
    # or broken start binary is respawned; seam=none
    def test_reload_all_leaves_a_sidebar_whose_binary_is_gone_or_broken
      broken = install("broken")
      counts, log = reload_with([target("%1", tagged: false, bin: path("gone/bin/switchboard")),
                                 target("%2", tagged: false, bin: nil),
                                 target("%3", tagged: false, bin: broken)],
                                preflight: ->(bin) { bin != broken })
      assert_equal({ signaled: 0, respawned: 0, left: 3 }, counts)
      assert_empty log.select { |e| e.first == :respawn }
      refute_includes log, [:preflight, path("gone/bin/switchboard")], "a missing file isn't even run"
    end

    def test_reload_all_preflights_a_shared_binary_once
      bin = install("shared")
      _, log = reload_with([target("%1", tagged: false, bin: bin), target("%2", tagged: false, bin: bin)])
      assert_equal 1, log.count { |e| e.first == :preflight }
      assert_equal 2, log.count { |e| e.first == :respawn }
    end

    # Value: protects=an untagged sidebar on tmux < 3.0 (no respawn-pane -e) is still restarted,
    # by its own start command; fails_when=the no-(-e) retry is dropped, or a command is passed
    # (repointing a checkout's sidebar at another binary); why_new=smoke runs a modern tmux, so
    # only the -e call ever ran; seam=none; no_claim=a real tmux 2.x server
    def test_respawn_falls_back_without_the_env_flag_on_old_tmux
      calls = []
      ok = stub_method(Tmux, :system, ->(*argv, **) { calls << argv; !argv.include?("-e") }) do
        Tmux.respawn_sidebar(target("%7", tagged: false), "MARK")
      end
      assert ok
      assert_equal [["tmux", "respawn-pane", "-k", "-e", "#{CodeReload::RESUME_ENV}=MARK", "-t", "%7"],
                    ["tmux", "respawn-pane", "-k", "-t", "%7"]], calls,
                   "-e first, then the bare retry; never a command (the pane reruns its own)"
      calls.clear
      stub_method(Tmux, :system, ->(*argv, **) { calls << argv; true }) { Tmux.respawn_sidebar(target("%7", tagged: false), "M") }
      assert_equal 1, calls.size, "a modern tmux takes -e: no second respawn"
    end

    def test_a_failed_respawn_counts_as_left
      counts, = reload_with([target("%1", tagged: false, bin: install("x"))], respawn_ok: false)
      assert_equal 1, counts[:left]
    end

    def test_reload_all_is_nil_off_a_server
      assert_nil stub_method(Tmux, :sidebar_reload_targets, -> { nil }) { CodeReload.reload_all }
    end

    def test_describe_names_what_happened
      assert_equal ["sidebars: 3 reloading in place, 1 restarted", nil],
                   CodeReload.describe({ signaled: 3, respawned: 1, left: 0 })
      assert_equal ["sidebars: 2 restarted", "2 sidebars left running old code: their switchboard was removed or doesn't start"],
                   CodeReload.describe({ signaled: 0, respawned: 2, left: 2 })
      assert_equal [nil, nil], CodeReload.describe({ signaled: 0, respawned: 0, left: 0 })
    end

    # --- spread ---------------------------------------------------------------

    def test_spread_delay_is_bounded_and_overridable
      ENV.delete(CodeReload::SPREAD_ENV)
      100.times { assert_includes 0.0..CodeReload::SPREAD, CodeReload.spread_delay }
      ENV[CodeReload::SPREAD_ENV] = "0"
      assert_equal 0.0, CodeReload.spread_delay
      ENV[CodeReload::SPREAD_ENV] = "junk"
      assert_operator CodeReload.spread_delay, :<=, CodeReload::SPREAD
    end

    private

    def stub_const(name, value)
      old = CodeReload.const_get(name)
      CodeReload.send(:remove_const, name)
      CodeReload.const_set(name, value)
      yield
    ensure
      CodeReload.send(:remove_const, name)
      CodeReload.const_set(name, old)
    end
  end
end
