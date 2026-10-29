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
      assert_equal :ok, CodeReload.preflight(install("ok"))
    end

    # Value: protects=a timeout is told apart from a failure, so only a real failure blocks a
    # root for good (a slow disk retries); fails_when=a hang reads as :failed or :ok; seam=none
    def test_preflight_fails_a_broken_missing_or_hung_binary
      assert_equal :failed, CodeReload.preflight(install("broken", "#!/bin/sh\nexit 1\n")), "non-zero exit"
      assert_equal :failed, CodeReload.preflight(path("nope", "bin", "switchboard")), "ENOENT"
      hung = install("hung", "#!/bin/sh\nsleep 30\n")
      started = Time.now
      assert_equal :timeout, CodeReload.preflight(hung, secs: 0.3), "past the bound"
      assert_operator Time.now - started, :<, 5, "the hang is killed, not waited out"
    end

    def test_preflight_passes_its_arguments_and_env
      seen = path("args.out")
      bin = install("args", "#!/bin/sh\nprintf '%s|%s' \"$*\" \"$#{CodeReload::RESUME_ENV}\" > #{seen}\n")
      assert_equal :ok, CodeReload.preflight(bin, "sidebar", "--check", env: { CodeReload::RESUME_ENV => "P" })
      assert_equal "sidebar --check|P", File.read(seen)
    end

    # Value: protects=a sidebar started under system Ruby can still reload (R6);
    # fails_when=the preflight inherits SB_REEXEC; seam=none
    def test_preflight_runs_without_the_reexec_guard
      seen = path("seen")
      bin = install("env", "#!/bin/sh\nprintf '%s' \"${SB_REEXEC-unset}\" > #{seen}\n")
      ENV["SB_REEXEC"] = "1"
      assert_equal :ok, CodeReload.preflight(bin)
      assert_equal "unset", File.read(seen)
    end

    def test_preflight_gives_the_child_no_stdin
      seen = path("stdin.out")
      bin = install("stdin", "#!/bin/sh\nif read -r line; then echo read > #{seen}; else echo eof > #{seen}; fi\n")
      assert_equal :ok, CodeReload.preflight(bin)
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

    # Value: protects=one non-UTF-8 name never crashes the fleet's reload (JSON.generate raises
    # on it); fails_when=encode stops scrubbing; seam=none
    def test_encode_survives_names_that_are_not_utf8
      bad = "/wt/caf\xE9".dup.force_encoding("UTF-8")
      raw = CodeReload.encode(cursor: { "kind" => "ws", "project" => "app", "path" => bad, "branch" => "x\xff".b },
                              hook_states: { bad => :done }, notify: { bad => Time.at(1) })
      got = CodeReload.decode(raw)
      assert got[:cursor]["path"].valid_encoding?
      assert_equal 1, got[:hook_states].size
    end

    # Value: protects=the payload always fits what decode accepts, keeping the cursor, and an
    # oversized resume never re-rings every alert (its notify cursor is gone); fails_when=encode
    # stops bounding it, or the fallback keeps announce; seam=none
    def test_an_oversized_baseline_is_dropped_but_the_cursor_kept
      huge = (1..2000).to_h { |i| ["/a/very/long/path/to/a/worktree/number-#{i}" * 2, :done] }
      raw = CodeReload.encode(cursor: { "kind" => "ws", "path" => "/wt/a" }, hook_states: huge, announce: true)
      assert_operator raw.bytesize, :<=, CodeReload::PAYLOAD_MAX
      got = CodeReload.decode(raw)
      assert_equal "/wt/a", got[:cursor]["path"]
      assert_empty got[:hook_states]
      refute got[:announce], "a silent first scan: no cursor to compare alerts against"
    end

    def test_an_unreadable_payload_is_still_a_reload
      ENV[CodeReload::RESUME_ENV] = "{garbage"
      assert_equal CodeReload::BLANK, CodeReload.take_resume, "handed over, so not a launch (no clear, no prune)"
      refute ENV.key?(CodeReload::RESUME_ENV)
    end

    def test_take_resume_removes_the_variable
      ENV[CodeReload::RESUME_ENV] = CodeReload.encode(offset: 1)
      assert_equal 1, CodeReload.take_resume[:offset]
      refute ENV.key?(CodeReload::RESUME_ENV), "children must never inherit a resume payload"
      assert_nil CodeReload.take_resume, "absent: a cold start"
    end

    # --- reaching every sidebar (R1, R2, R5) -----------------------------------

    def test_parse_reload_targets_splits_tagged_from_old
      raw = "%1\t101\t101\t\t\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n" \
            "%2\t102\t\t\t\tsb-sidebar\t\"/my dir/bin/switchboard\" sidebar\n" \
            "%3\t103\t99\t\t\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n" \
            "%4\t104\t104\t\t\tzsh\tzsh\n" \
            "%5\t105\t\t\t\tsb-sidebar\t\"unbalanced\n" \
            "%6\t106\t0\t\t\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n" \
            "%7\t107\t107\t/Cellar/b\t\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n" \
            "%8\t108\t108\t\t1\tsb-sidebar\t/opt/sb/bin/switchboard sidebar\n"
      got = Tmux.parse_reload_targets(raw).map { |t| [t.pane, t.pid, t.tagged, t.between, t.tag_pid, t.failed, t.bin] }
      assert_equal [["%1", 101, true, false, nil, false, "/opt/sb/bin/switchboard"],
                    ["%2", 102, false, false, nil, false, "/my dir/bin/switchboard"],
                    ["%3", 103, false, false, 99, false, "/opt/sb/bin/switchboard"], # a foreign tag: only its parent may vouch
                    ["%5", 105, false, false, nil, false, nil],
                    ["%6", 106, false, true, nil, false, "/opt/sb/bin/switchboard"], # mid-exec: neither signaled nor respawned
                    ["%7", 107, true, false, nil, true, "/opt/sb/bin/switchboard"]], # a failed reload, recorded
                                                                                          # %8: a dead pane (remain-on-exit) is skipped
                   got, "only sidebar panes; a tag must equal the pane's pid"
    end

    # Value: protects=a pane some other program titled sb-sidebar is never respawned (respawn
    # kills what runs there); fails_when=start_bin accepts any command; seam=none
    def test_only_a_plain_switchboard_sidebar_command_can_be_respawned
      assert_equal "/opt/sb/bin/switchboard", Tmux.start_bin("/opt/sb/bin/switchboard sidebar")
      assert_nil Tmux.start_bin("sleep 300"), "not switchboard"
      assert_nil Tmux.start_bin("/x/bin/switchboard sidebar --extra"), "extra arguments"
      assert_nil Tmux.start_bin("/x/bin/switchboard"), "no sidebar verb"
      assert_nil Tmux.start_bin("/x/bin/not-switchboard sidebar")
      assert_nil Tmux.start_bin(""), "no command"
    end

    # Value: protects=the cross-version contract: a newer image reads what an older one wrote;
    # fails_when=a payload key is renamed in both encode and decode; seam=none
    def test_a_frozen_v1_payload_still_decodes
      raw = '{"v":1,"cursor":{"kind":"ws","project":"app","path":"/wt/a","branch":null},"offset":3,' \
            '"hook_states":{"/wt/a":"done"},"notify":{"/wt/a":[12,345678901]},"announce":true}'
      got = CodeReload.decode(raw)
      assert_equal({ "kind" => "ws", "project" => "app", "path" => "/wt/a", "branch" => nil }, got[:cursor])
      assert_equal 3, got[:offset]
      assert_equal({ "/wt/a" => :done }, got[:hook_states])
      assert_equal({ "/wt/a" => Time.at(12, 345_678_901, :nsec) }, got[:notify])
      assert got[:announce]
    end

    # `preflight` answers each run as ->(bin, args) (args empty: `version`); a version run
    # also prints `version` to its out, as a real binary would.
    def reload_with(targets, preflight: ->(_bin, _args) { :ok }, version: "switchboard 0.60.5\n", respawn_ok: true,
                    parents: {}, unchanged: true, signal_ok: true)
      log = []
      fake = lambda do |bin, *args, out: File::NULL, **|
        log << [:preflight, bin, *args]
        out.write(version) if args.empty? && out.respond_to?(:write)
        preflight.call(bin, args)
      end
      counts = stub_method(Tmux, :sidebar_reload_targets, -> { targets }) do
       stub_method(Tmux, :same_reload_target?, ->(_t) { unchanged }) do
        stub_method(Tmux, :parent_pids, ->(_pids) { parents }) do
          stub_method(Tmux, :signal_sidebar, ->(pid) { log << [:signal, pid]; signal_ok }) do
            stub_method(Tmux, :respawn_sidebar, ->(t, marker) { log << [:respawn, t.pane, CodeReload.decode(marker).nil?]; respawn_ok }) do
              stub_method(CodeReload, :preflight, fake) { CodeReload.reload_all }
            end
          end
        end
       end
      end
      [counts, log]
    end

    # Value: protects=a pane that changed since the listing (respawned into an editor while
    # preflights ran) is never respawn-pane -k'd; fails_when=the recheck is dropped; seam=none
    def test_a_pane_that_changed_since_the_listing_is_left_alone
      counts, log = reload_with([target("%1", tagged: false, bin: install("c"))], unchanged: false)
      assert_equal 1, counts[:left]
      assert_empty log.select { |e| e.first == :respawn }
    end

    def test_same_reload_target_compares_the_live_pane
      t = Tmux::ReloadTarget.new(pane: "%1", pid: 10, tagged: false, between: false, bin: "/x/bin/switchboard")
      live = lambda do |line|
        stub_method(IO, :popen, ->(*_a, **_k, &_b) { system("true"); line }) { Tmux.same_reload_target?(t) }
      end
      assert live.call("10\t\t0\tsb-sidebar\t/x/bin/switchboard sidebar\n")
      refute live.call("11\t\t0\tsb-sidebar\t/x/bin/switchboard sidebar\n"), "a new process"
      refute live.call("10\t\t0\tsb-sidebar\tvim notes.md\n"), "a different command"
      refute live.call("10\t\t1\tsb-sidebar\t/x/bin/switchboard sidebar\n"), "dead"
      refute live.call("10\t10\t0\tsb-sidebar\t/x/bin/switchboard sidebar\n"), "tagged since"
      refute live.call("10\t4242\t0\tsb-sidebar\t/x/bin/switchboard sidebar\n"), "tagged by a child pid (fish) since"
    end

    def target(pane, tagged:, bin: nil, between: false, pid: 1, tag_pid: nil, failed: false)
      Tmux::ReloadTarget.new(pane: pane, pid: pid, tagged: tagged, between: between, tag_pid: tag_pid, failed: failed, bin: bin)
    end

    # Value: protects=a sidebar under a shell that doesn't exec it (fish) reloads in place
    # instead of a restart; fails_when=only pane_pid counts as tagged, or any tag pid is
    # signaled without the parent check; seam=none
    def test_a_sidebar_that_is_a_child_of_its_pane_is_signaled_directly
      counts, log = reload_with([target("%1", tagged: false, pid: 10, tag_pid: 11, bin: install("c"))], parents: { 11 => 10 })
      assert_equal({ signaled: 1, respawned: 0, left: 0, unreached: 0, failed: 0 }, counts)
      assert_equal [[:signal, 11]], log
      counts, log = reload_with([target("%1", tagged: false, pid: 10, tag_pid: 11, bin: install("c"))], parents: { 11 => 99 })
      refute_includes log, [:signal, 11], "a stale tag whose pid isn't the pane's child is never signaled"
      assert_equal 1, counts[:respawned], "it falls through to the restart pass instead of going uncounted"
    end

    def test_a_previous_failed_reload_is_counted
      counts, = reload_with([target("%1", tagged: true, failed: true)])
      assert_equal 1, counts[:failed]
      assert_equal 1, counts[:signaled], "and it's asked again"
    end

    # Value: protects=a sidebar that closed mid-reload is reported, and a
    # previously failed one is "asked again" only when it was; fails_when=a failed signal goes
    # uncounted, or :failed is counted before delivery; why_new=the stub always delivered;
    # seam=none; no_claim=a real ESRCH (signal stubbed)
    def test_a_signal_that_fails_is_counted_unreached
      counts, = reload_with([target("%1", tagged: true), target("%2", tagged: true, failed: true)], signal_ok: false)
      assert_equal({ signaled: 0, respawned: 0, left: 0, unreached: 2, failed: 0 }, counts)
      counts, log = reload_with([target("%1", tagged: false, pid: 10, tag_pid: 11, bin: install("c"), failed: true)],
                                parents: { 11 => 10 }, signal_ok: false)
      assert_equal({ signaled: 0, respawned: 0, left: 0, unreached: 1, failed: 0 }, counts, "a sidebar under fish, too")
      assert_empty log.select { |e| e.first == :respawn }, "never respawned on a failed signal"
    end

    # Value: protects=a sidebar gone before its signal lands is reported, not raised out of the
    # whole reload (and upgrade --finish); fails_when=signal_sidebar's rescue drops ESRCH or EPERM;
    # why_new=every reload test stubs the signal; seam=none
    def test_signaling_a_gone_sidebar_reads_as_unreached
      gone = Process.spawn("true", in: File::NULL)
      Process.wait(gone)
      refute Tmux.signal_sidebar(gone), "ESRCH"
      refute Tmux.signal_sidebar(1), "EPERM: pid 1 isn't ours" unless Process.uid.zero?
    end

    # Value: protects=a second reload never kills a sidebar mid-exec (R4); fails_when=a "0" tag
    # is treated as untagged and respawned; seam=none
    def test_a_sidebar_mid_exec_is_left_to_finish
      counts, log = reload_with([target("%1", tagged: false, between: true, bin: install("mid"))])
      assert_equal({ signaled: 1, respawned: 0, left: 0, unreached: 0, failed: 0 }, counts)
      assert_empty log, "neither signaled nor respawned"
      counts, = reload_with([target("%1", tagged: false, between: true, failed: true, bin: install("mid"))])
      assert_equal 1, counts[:failed], "a failed one mid-exec is being asked again"
    end

    # Value: protects=upgrade reloads every sidebar, old ones by their own start command (R1);
    # fails_when=an old sidebar gets the signal (its default action kills it) or isn't restarted;
    # seam=none; no_claim=real tmux (Tmux stubbed; the smoke test runs it)
    def test_reload_all_signals_new_sidebars_and_respawns_old_ones
      good = install("good")
      counts, log = reload_with([target("%1", tagged: true), target("%2", tagged: false, bin: good, failed: true)])
      assert_equal({ signaled: 1, respawned: 1, left: 0, unreached: 0, failed: 0 }, counts,
                   "a flagged pane that's restarted wasn't asked again (D2)")
      assert_includes log, [:signal, 1]
      assert_includes log, [:respawn, "%2", false], "with a decodable resume marker"
      refute_includes log, [:preflight, nil]
    end

    # Value: protects=no SIGUSR1 lands seconds after the listing read its pid (a sidebar that
    # exited meanwhile could have that pid reused by another process, which the signal would
    # quit); fails_when=signals and restart checks interleave again; why_new=no test watched
    # the order; seam=none; no_claim=a real pid reuse (signal and preflight stubbed)
    def test_every_signal_goes_out_before_any_restart_check
      _, log = reload_with([target("%1", tagged: false, bin: install("old")), target("%2", tagged: true, pid: 2),
                            target("%3", tagged: false, bin: install("older")), target("%4", tagged: true, pid: 4)])
      kinds = log.map(&:first)
      assert_equal [:signal, :signal], kinds.first(2), "both signals before the first preflight"
      assert_includes kinds, :preflight
    end

    # Value: protects=no sidebar vanishes on upgrade (R2, R5); fails_when=a missing, unparseable
    # or broken start binary is respawned, or a relative one is run from our cwd (the pane
    # resolves it against its own); seam=none
    def test_reload_all_leaves_a_sidebar_whose_binary_is_gone_or_broken
      broken = File.realpath(install("broken"))
      counts, log = reload_with([target("%1", tagged: false, bin: path("gone/bin/switchboard"), failed: true),
                                 target("%2", tagged: false, bin: nil),
                                 target("%3", tagged: false, bin: broken),
                                 target("%4", tagged: false, bin: "switchboard"),
                                 target("%5", tagged: false, bin: "bin/switchboard")],
                                preflight: ->(bin, _args) { bin == broken ? :failed : :ok })
      assert_equal({ signaled: 0, respawned: 0, left: 5, unreached: 0, failed: 0 }, counts)
      assert_empty log.select { |e| e.first == :respawn }
      assert_equal [[:preflight, broken]], log, "a missing or relative file isn't even run; a broken one stops at `version`"
    end

    # Value: protects=a sidebar whose start command names a keg (it booted while opt/ was
    # missing) is checked on that keg, which is what respawn-pane reruns, not on opt/'s newer
    # one; fails_when=the check follows opt/, so a cleaned-up keg is killed into a dead pane;
    # seam=none; no_claim=a real brew cleanup (rm stands in)
    def test_a_keg_path_sidebar_is_checked_on_its_own_keg
      old = install("Cellar/switchboard/0.58.0")
      install("Cellar/switchboard/0.60.5")
      FileUtils.mkdir_p(path("opt"))
      File.symlink(path("Cellar/switchboard/0.60.5"), path("opt/switchboard"))
      counts, log = reload_with([target("%1", tagged: false, bin: old)], version: "switchboard 0.58.0\n")
      assert_equal 1, counts[:respawned]
      assert_equal [[:preflight, File.realpath(old)]], log.select { |e| e.first == :preflight }, "its own keg, `version` only"
      FileUtils.rm_rf(path("Cellar/switchboard/0.58.0"))
      counts, log = reload_with([target("%1", tagged: false, bin: old)])
      assert_equal 1, counts[:left], "the keg is gone: respawn would rerun a missing file"
      assert_empty log
    end

    def test_reload_all_preflights_a_shared_binary_once
      bin = install("shared")
      real = File.realpath(bin)
      _, log = reload_with([target("%1", tagged: false, bin: bin), target("%2", tagged: false, bin: bin)])
      assert_equal [[:preflight, real], [:preflight, real, "sidebar", "--check"]], log.select { |e| e.first == :preflight },
                   "one version run and one check for both panes"
      assert_equal 2, log.count { |e| e.first == :respawn }
    end

    # Value: protects=a release that answers `version` but can't build a sidebar never
    # replaces a working old one; fails_when=the check result is ignored, or
    # a hung check reads as passed; why_new=only `version` was checked; seam=none
    # A `version` that prints its line and then hangs is left too, without a check.
    def test_a_release_that_fails_the_sidebar_check_is_left_running
      %i[failed timeout].each do |outcome|
        counts, log = reload_with([target("%1", tagged: false, bin: install("bad"))],
                                  preflight: ->(_bin, args) { args.empty? ? :ok : outcome })
        assert_equal 1, counts[:left], "a #{outcome} check"
        assert_empty log.select { |e| e.first == :respawn }
      end
      counts, log = reload_with([target("%1", tagged: false, bin: install("hung"))],
                                preflight: ->(_bin, args) { args.empty? ? :timeout : :ok })
      assert_equal 1, counts[:left], "a timed-out `version`"
      assert_equal 1, log.size, "no check, no respawn"
    end

    # Value: protects=the version gate never sends `sidebar --check` to a release older than
    # 0.59 (it would run a full hidden sidebar), and an exit 0 we can't read is never
    # restarted (D1); fails_when=the gate is dropped, inverted or off by one, or an unreadable
    # version falls through to a restart; seam=none
    # Value (the "\xFF" row): protects=a `version` that prints bytes that aren't UTF-8 leaves
    # the pane instead of crashing upgrade/reload-sidebars; fails_when=the read isn't scrubbed
    # (the regex raises ArgumentError, which nothing rescues); why_new=every other row is
    # valid UTF-8; seam=none; no_claim=other encodings of the version line
    def test_the_check_is_gated_on_the_release_version
      bin = install("v")
      checks = ->(log) { log.count { |e| e[2] == "sidebar" } }
      { "switchboard 0.58.9\n" => [1, 0], "switchboard 0.59.0\n" => [1, 1], "switchboard 1.0.0" => [1, 1],
        "not switchboard\n" => [0, 0], "" => [0, 0], "switchboard 0.60\n" => [0, 0],
        "\xFFswitchboard 0.60.5\n" => [0, 0] }.each do |out, (restarted, checked)|
        counts, log = reload_with([target("%1", tagged: false, bin: bin)], version: out)
        assert_equal restarted, counts[:respawned], out.inspect
        assert_equal checked, checks.call(log), "checks sent for #{out.inspect}"
      end
    end

    # Value: protects=a respawn never runs a keg no check saw (D5); fails_when=the
    # pre-respawn recheck is dropped; why_new=new guard; seam=none; no_claim=the ms between
    # the recheck and tmux's own exec
    def test_a_link_that_moved_after_the_check_is_left
      install("Cellar/a")
      install("Cellar/b")
      FileUtils.mkdir_p(path("opt"))
      File.symlink(path("Cellar/a"), path("opt/switchboard"))
      relink = lambda do |_bin, args|
        unless args.empty?
          File.unlink(path("opt/switchboard"))
          File.symlink(path("Cellar/b"), path("opt/switchboard"))
        end
        :ok
      end
      counts, log = reload_with([target("%1", tagged: false, bin: path("opt/switchboard/bin/switchboard"))], preflight: relink)
      assert_equal 1, counts[:left]
      assert_empty log.select { |e| e.first == :respawn }
    end

    # Value: protects=the version run and the check really reach the child: a pre-0.59
    # binary is never handed `sidebar --check`, a 0.59+ one gets it with the resume marker,
    # both through one resolved file (D3, D4); fails_when=preflight drops the args, env or
    # out, or the check re-resolves the link; why_new=every other row stubs preflight;
    # seam=none; no_claim=real releases (scripts stand in) or a real tmux respawn
    def test_real_binaries_get_the_check_only_from_0_59_on_the_file_their_version_came_from
      calls = path("calls")
      script = lambda do |version|
        "#!/bin/sh\necho \"$0 $* ${#{CodeReload::RESUME_ENV}:+marker}\" >> #{calls}\n" \
          "[ \"$1\" = version ] && echo 'switchboard #{version}'\nexit 0\n"
      end
      old = install("Cellar/old", script.call("0.58.0"))
      new = install("Cellar/new", script.call("0.60.5"))
      FileUtils.mkdir_p(path("opt"))
      File.symlink(path("Cellar/new"), path("opt/switchboard"))
      run = lambda do |bin|
        File.write(calls, "")
        targets = [target("%1", tagged: false, bin: bin)] # outside the stub: its body runs as Tmux
        stub_method(Tmux, :sidebar_reload_targets, -> { targets }) do
          stub_method(Tmux, :same_reload_target?, ->(_t) { true }) do
            stub_method(Tmux, :parent_pids, ->(_pids) { {} }) do
              stub_method(Tmux, :respawn_sidebar, ->(_t, _m) { true }) { CodeReload.reload_all }
            end
          end
        end
      end

      assert_equal 1, run.call(old)[:respawned]
      assert_equal ["#{File.realpath(old)} version"], File.readlines(calls, chomp: true).map(&:strip),
                   "0.58 gets `version` only"
      assert_equal 1, run.call(new)[:respawned]
      assert_equal ["#{File.realpath(new)} version", "#{File.realpath(new)} sidebar --check marker"],
                   File.readlines(calls, chomp: true).map(&:strip), "0.60 gets the check, with the marker"

      # The link moves to the 0.58 keg after the version run: the check stays on the keg whose
      # version was read (and the restart is then left: the link no longer names it).
      relink = <<~SH
        #!/bin/sh
        echo "$0 $*" >> #{calls}
        [ "$1" = version ] && { rm #{path('opt/switchboard')}; ln -s #{path('Cellar/old')} #{path('opt/switchboard')}; echo 'switchboard 0.60.5'; }
        exit 0
      SH
      File.write(new, relink)
      counts = run.call(path("opt/switchboard/bin/switchboard"))
      assert_equal ["#{File.realpath(new)} version", "#{File.realpath(new)} sidebar --check"],
                   File.readlines(calls, chomp: true).map(&:strip), "the check never reaches the 0.58 keg"
      assert_equal 1, counts[:left]
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

    # Value (the empty row): protects=a server with no sidebars reports zero counts, not "no
    # server"; fails_when=an empty listing returns nil or skips the counts; seam=none
    def test_reload_all_is_nil_off_a_server
      assert_nil stub_method(Tmux, :sidebar_reload_targets, -> { nil }) { CodeReload.reload_all }
      counts, log = reload_with([])
      assert_equal({ signaled: 0, respawned: 0, left: 0, unreached: 0, failed: 0 }, counts, "no sidebars: zeros, not nil")
      assert_empty log
    end

    def test_describe_names_what_happened
      assert_equal [[:ok, "sidebars: 3 asked to reload in place, 1 restarted"]],
                   CodeReload.describe({ signaled: 3, respawned: 1, left: 0, failed: 0 })
      assert_equal [[:ok, "sidebars: 2 restarted"],
                    [:note, "2 sidebars left running old code: couldn't restart them safely (switchboard missing, won't start or just moved, or not a plain `switchboard sidebar`)"],
                    [:note, "1 sidebar failed to reload last time (asked again now) — `switchboard doctor` lists any still on old code"]],
                   CodeReload.describe({ signaled: 0, respawned: 2, left: 2, failed: 1 })
      assert_empty CodeReload.describe({ signaled: 0, respawned: 0, left: 0, failed: 0 })
      assert_equal [[:note, "1 sidebar closed before the reload reached it"]],
                   CodeReload.describe({ signaled: 0, respawned: 0, left: 0, unreached: 1 }),
                   "an unreached-only reload still says so (reload-sidebars won't claim none are running)"
      assert_equal [:note, "2 sidebars closed before the reload reached them"],
                   CodeReload.describe({ signaled: 1, respawned: 0, left: 0, unreached: 2 }).last
    end

    # Value: protects=a sidebar that starts (new code) clears an earlier failed reload, and
    # going "between images" doesn't; fails_when=either half of the chain changes; seam=none
    def test_tagging_a_pane_clears_a_failed_reload_but_mid_exec_does_not
      calls = []
      stub_method(Tmux, :system, ->(*argv, **) { calls << argv; true }) do
        assert Tmux.tag_sidebar_pane("%3", 42)
        Tmux.tag_sidebar_pane("%3", 0)
        Tmux.flag_failed_reload("%3", "/Cellar/b")
      end
      assert_equal ["tmux", "set-option", "-p", "-t", "%3", CodeReload::TAG, "42",
                    ";", "set-option", "-p", "-u", "-t", "%3", CodeReload::FAILED_TAG], calls[0]
      assert_equal ["tmux", "set-option", "-p", "-t", "%3", CodeReload::TAG, "0"], calls[1]
      assert_equal ["tmux", "set-option", "-p", "-t", "%3", CodeReload::FAILED_TAG, "/Cellar/b"], calls[2]
      calls.clear
      stub_method(Tmux, :system, ->(*argv, **) { calls << argv; false }) do
        refute Tmux.tag_sidebar_pane("%3", 42, clear_failed: false), "a tag that didn't land says so"
      end
      assert_equal [["tmux", "set-option", "-p", "-t", "%3", CodeReload::TAG, "42"]], calls,
                   "old code re-tagging itself leaves the failure flag"
    end

    def test_real_bin_resolves_the_link_and_current_root_rides_it
      dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(dir, "keg", "bin"))
      FileUtils.touch(File.join(dir, "keg", "bin", "switchboard"))
      File.symlink(File.join(dir, "keg"), File.join(dir, "opt"))
      link = File.join(dir, "opt", "bin", "switchboard")
      assert_equal File.realpath(File.join(dir, "keg", "bin", "switchboard")), CodeReload.real_bin(link)
      assert_equal File.realpath(File.join(dir, "keg")), CodeReload.current_root(link)
      assert_nil CodeReload.real_bin(File.join(dir, "gone", "bin", "switchboard"))
      assert_nil CodeReload.real_bin("")
      assert_nil CodeReload.current_root(nil)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    # Value: protects=a sidebar that booted while opt/ was missing (so its SWITCHBOARD_BIN is a
    # keg path) still follows the next upgrade, even once that keg is cleaned up;
    # fails_when=real_bin realpaths the keg path as given; seam=none
    def test_real_bin_follows_opt_for_a_keg_path
      dir = Dir.mktmpdir
      %w[1.0 2.0].each do |v|
        FileUtils.mkdir_p(File.join(dir, "Cellar", "switchboard", v, "libexec", "bin"))
        FileUtils.touch(File.join(dir, "Cellar", "switchboard", v, "libexec", "bin", "switchboard"))
      end
      FileUtils.mkdir_p(File.join(dir, "opt"))
      File.symlink(File.join(dir, "Cellar", "switchboard", "2.0"), File.join(dir, "opt", "switchboard"))
      stranded = File.join(dir, "Cellar", "switchboard", "1.0", "libexec", "bin", "switchboard")
      newest = File.realpath(File.join(dir, "Cellar", "switchboard", "2.0", "libexec", "bin", "switchboard"))
      assert_equal newest, CodeReload.real_bin(stranded)
      assert_equal CodeReload.root_of(newest), CodeReload.current_root(stranded), "the backstop compares opt/'s keg"
      assert CodeReload.stale?(stranded)
      FileUtils.rm_f(File.join(dir, "opt", "switchboard")) # brew mid-relink, keg still there
      assert_equal File.realpath(stranded), CodeReload.real_bin(stranded), "no opt/: the keg as given"
      File.symlink(File.join(dir, "Cellar", "switchboard", "2.0"), File.join(dir, "opt", "switchboard"))
      FileUtils.rm_rf(File.join(dir, "Cellar", "switchboard", "1.0")) # brew cleanup
      assert_equal newest, CodeReload.real_bin(stranded)
      assert CodeReload.stale?(stranded), "a cleaned-up keg doesn't strand it"
      FileUtils.rm_f(File.join(dir, "opt", "switchboard"))
      assert_nil CodeReload.real_bin(stranded), "no opt/ and the keg is gone: nothing to run"
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    def test_parent_pids_reads_live_processes
      assert_equal({ Process.pid => Process.ppid }, Tmux.parent_pids([Process.pid]))
      assert_equal({}, Tmux.parent_pids([]))
    end

    def test_doctor_lists_sidebars_whose_reload_failed
      failed = Tmux::ReloadTarget.new(pane: "%4", pid: 9, failed: true)
      out, = stub_method(Tmux, :sidebar_reload_targets, -> { [failed, Tmux::ReloadTarget.new(pane: "%5", pid: 8)] }) do
        capture_io { CLI.doctor_reload_failures }
      end
      assert_includes out, "1 sidebar(s) still on old code after a failed reload (pane %4)"
      out, = stub_method(Tmux, :sidebar_reload_targets, -> { nil }) { capture_io { CLI.doctor_reload_failures } }
      assert_empty out, "silent off a server or with none"
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
