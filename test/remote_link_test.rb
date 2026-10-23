# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Switchboard
  # Claude's live session files → which workspaces are reachable from the phone.
  # Real files in the sandboxed sessions dir; the live session is THIS test process
  # (its real pid + lstart), so the liveness gate runs for real. lsof is stubbed only
  # where a test needs a cwd the OS can't fake (a moved dir).
  class RemoteLinkTest < SandboxTest
    STALE = 7200 # the default 120 min, in seconds

    def setup
      super
      FileUtils.mkdir_p(RemoteLink.sessions_dir)
    end

    def wt(name)
      d = path("worktrees", name)
      FileUtils.mkdir_p(d)
      File.realpath(d)
    end

    def me_start
      ProcessIdentity.start_of(Process.pid)
    end

    def write_session(file, **over)
      data = { "pid" => Process.pid, "sessionId" => "s-#{file}", "cwd" => over.delete(:cwd),
               "startedAt" => 1_792_696_353_818, "procStart" => me_start, "kind" => "interactive",
               "name" => "a-name", "status" => "busy", "statusUpdatedAt" => (Time.now.to_f * 1000).to_i,
               "bridgeSessionId" => "session_01L45oDnx5EE9wmapDpFmAfd" }.merge(over.transform_keys(&:to_s))
      data.delete_if { |_, v| v == :absent }
      File.write(File.join(RemoteLink.sessions_dir, "#{file}.json"), JSON.generate(data))
    end

    # doctor's health only counts pids whose process IS Claude (claude_pids). The fixtures'
    # "live session" is this test process (ruby), so health assertions declare it Claude;
    # the real check runs in the recycled-pid tests below.
    def as_claude(&blk)
      stub_method(RemoteLink, :claude_pids, ->(pids) { pids.map(&:to_i).to_set }, &blk)
    end

    def scan(paths, **kw)
      stub_method(Agents, :cwds_of, ->(*) { {} }) { RemoteLink.scan(paths, stale_after: STALE, **kw) }
    end

    def test_a_live_linked_session_maps_to_its_worktree_with_the_claude_url
      w = wt("alpha")
      write_session("1", cwd: w)
      links = scan([w])[w]
      assert_equal 1, links.size
      assert_equal "https://claude.ai/code/session_01L45oDnx5EE9wmapDpFmAfd", links.first.url
      refute links.first.stale
    end

    def test_no_bridge_id_means_no_link
      w = wt("alpha")
      write_session("1", cwd: w, bridgeSessionId: :absent)
      assert_empty scan([w])
    end

    def test_a_malformed_or_overlong_bridge_id_is_ignored
      w = wt("alpha")
      write_session("1", cwd: w, bridgeSessionId: "session_bad id")
      write_session("2", cwd: w, bridgeSessionId: "session_#{'a' * 65}")
      write_session("3", cwd: w, bridgeSessionId: 42)
      assert_empty scan([w])
    end

    def test_a_garbled_file_beside_a_valid_one_keeps_the_valid_link
      w = wt("alpha")
      File.write(File.join(RemoteLink.sessions_dir, "bad.json"), "{ not json")
      File.write(File.join(RemoteLink.sessions_dir, "array.json"), "[1,2]")
      write_session("1", cwd: w)
      assert_equal 1, scan([w])[w].size
    end

    def test_a_dead_or_recycled_pid_shows_no_link
      w = wt("alpha")
      write_session("dead", cwd: w, pid: 2**22 + 12_345)
      write_session("recycled", cwd: w, procStart: "Thu Jan  1 00:00:00 2026") # our pid, someone else's start
      assert_empty scan([w])
    end

    def test_a_non_ascii_session_name_still_reads_under_a_c_locale
      w = wt("alpha")
      write_session("1", cwd: w, name: "Compass’s Night Watch ⇅")
      old = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      assert_equal "Compass’s Night Watch ⇅", scan([w])[w].first.name
    ensure
      Encoding.default_external = old
    end

    # Value: protects=a non-ASCII worktree path under tmux's C locale (git output arrives
    # US-ASCII, the JSON cwd UTF-8) neither raises nor wipes EVERY link; fails_when=owner
    # compares the paths as text again; why_new=red team, ship 2 (reproduced
    # Encoding::CompatibilityError); seam=none; no_claim=a real C-locale git read
    def test_a_non_ascii_worktree_path_under_a_c_locale_keeps_every_link
      cafe = wt("café")
      plain = wt("plain")
      write_session("1", cwd: cafe, bridgeSessionId: "session_cafe")
      write_session("2", cwd: plain, bridgeSessionId: "session_plain")
      paths = [cafe, plain].map { |p| p.dup.force_encoding(Encoding::US_ASCII) } # how a C-locale git read hands them over
      links = scan(paths)
      assert_equal %w[session_cafe session_plain], paths.map { |p| links[p]&.first&.bridge_id }
    end

    # Value: protects=a dead leftover file costs a kill(0), not a `ps` fork, on every full scan
    # of every visible pane; fails_when=scan calls same? before the liveness check; why_new=red
    # team, ship 2; seam=none (counts same? calls); no_claim=real fork counts
    def test_the_full_scan_never_spawns_ps_for_a_dead_pid
      w = wt("alpha")
      dead = 2**22 + 12_345
      write_session("dead", cwd: w, pid: dead)
      asked = []
      real_same = ProcessIdentity.method(:same?)
      stub_method(ProcessIdentity, :same?, ->(pid, started) { asked << pid; real_same.call(pid, started) }) do
        assert_empty scan([w])
      end
      refute_includes asked, dead
    end

    def test_a_session_started_in_a_subdir_belongs_to_the_deepest_worktree
      w = wt("alpha")
      sub = File.join(w, "app", "models")
      FileUtils.mkdir_p(sub)
      write_session("1", cwd: sub)
      assert_equal [w], scan([w, path("worktrees")]).keys
    end

    # Rename A→B while the agent runs, then rename another workspace C→A (Rename clears
    # the dead A bridge). The file's frozen cwd A now names C's tree; the kernel cwd
    # (lsof) is still B, and that's where the link belongs.
    def test_a_rename_onto_the_old_name_attributes_by_the_kernel_cwd
      a = wt("A")
      b = wt("B")
      write_session("1", cwd: a)
      links = stub_method(Agents, :cwds_of, ->(pids) { pids.to_h { |p| [p, b] } }) do
        RemoteLink.scan([a, b], stale_after: STALE)
      end
      assert_equal [b], links.keys
    end

    def test_without_an_lsof_answer_the_recorded_cwd_resolves_through_the_rename_bridge
      b = wt("B")
      File.symlink(b, path("worktrees", "A"))
      write_session("1", cwd: path("worktrees", "A"))
      assert_equal [b], scan([b]).keys
    end

    def test_several_links_in_one_worktree_are_all_kept_newest_first
      w = wt("alpha")
      write_session("old", cwd: w, startedAt: 100, bridgeSessionId: "session_old")
      write_session("new", cwd: w, startedAt: 300, bridgeSessionId: "session_new")
      write_session("mid", cwd: w, startedAt: :absent, procStart: "Thu Jan  1 00:00:00 1970", bridgeSessionId: "session_mid")
      links = stub_method(ProcessIdentity, :same?, ->(*) { true }) { scan([w])[w] }
      assert_equal %w[session_new session_old session_mid], links.map(&:bridge_id),
                   "startedAt orders; a missing one falls back to procStart (epoch 0 here) and is kept, not dropped"
    end

    def test_an_interactive_link_idle_past_the_threshold_is_stale
      w = wt("alpha")
      now = Time.now
      write_session("1", cwd: w, status: "idle", statusUpdatedAt: ((now.to_f - 121 * 60) * 1000).to_i)
      assert scan([w], now: now)[w].first.stale
    end

    def test_just_under_the_threshold_or_busy_is_not_stale
      w = wt("alpha")
      now = Time.now
      write_session("1", cwd: w, status: "idle", statusUpdatedAt: ((now.to_f - 119 * 60) * 1000).to_i)
      write_session("2", cwd: w, status: "busy", statusUpdatedAt: 0, bridgeSessionId: "session_busy")
      assert_equal [false, false], scan([w], now: now)[w].map(&:stale)
    end

    def test_a_background_job_is_never_stale
      w = wt("alpha")
      write_session("1", cwd: w, kind: "bg", status: "idle", statusUpdatedAt: 0)
      link = scan([w])[w].first
      assert link.bg?
      refute link.stale
    end

    def test_stale_off_marks_nothing
      w = wt("alpha")
      write_session("1", cwd: w, status: "idle", statusUpdatedAt: 0)
      links = stub_method(Agents, :cwds_of, ->(*) { {} }) { RemoteLink.scan([w], stale_after: nil) }
      refute links[w].first.stale
    end

    def test_scan_is_total
      stub_method(Dir, :glob, ->(*) { raise "boom" }) do
        assert_equal({}, RemoteLink.scan([path("x")], stale_after: STALE))
      end
    end

    def test_sessions_dir_follows_the_override_then_claude_config_dir_then_home
      assert_equal path("claude-sessions"), RemoteLink.sessions_dir
      ENV.delete("SWITCHBOARD_CLAUDE_SESSIONS_DIR")
      ENV["CLAUDE_CONFIG_DIR"] = path("cc")
      assert_equal path("cc", "sessions"), RemoteLink.sessions_dir
      ENV["CLAUDE_CONFIG_DIR"] = ""
      assert_equal File.join(Dir.home, ".claude", "sessions"), RemoteLink.sessions_dir
    end

    def test_fingerprint_ignores_status_churn_but_moves_on_a_link_change
      w = wt("alpha")
      cache = {}
      tick = Time.now
      write = lambda do |name, **over| # a strictly newer mtime per write, on any filesystem
        write_session(name, **over)
        File.utime(tick += 5, tick, File.join(RemoteLink.sessions_dir, "#{name}.json"))
      end
      write.call("1", cwd: w, status: "busy")
      before = RemoteLink.fingerprint(cache, stale_after: STALE)
      write.call("1", cwd: w, status: "idle") # Claude rewrites on every flip
      write.call("2", cwd: w, bridgeSessionId: :absent) # an unlinked session elsewhere
      assert_equal before, RemoteLink.fingerprint(cache, stale_after: STALE)

      write.call("1", cwd: w, bridgeSessionId: :absent) # /rc off
      refute_equal before, RemoteLink.fingerprint(cache, stale_after: STALE)
    end

    def test_fingerprint_moves_when_a_link_crosses_the_stale_line
      w = wt("alpha")
      now = Time.now
      write_session("1", cwd: w, status: "idle", statusUpdatedAt: ((now.to_f - 100 * 60) * 1000).to_i)
      cache = {}
      fresh = RemoteLink.fingerprint(cache, stale_after: STALE, now: now)
      refute_equal fresh, RemoteLink.fingerprint(cache, stale_after: STALE, now: now + 30 * 60)
    end

    # Value: protects=two files sharing cwd + bridge id but differing in liveness (a crash
    # leftover beside its resumed session) still fingerprint; fails_when=the tuple carries raw
    # booleans and Array#sort raises (fingerprint nil, hidden panes miss every link change);
    # why_new=every other fingerprint test has distinct cwd/bridge tuples; seam=none;
    # no_claim=Claude really reusing a bridge id on resume
    def test_fingerprint_survives_a_tie_that_differs_only_in_liveness
      w = wt("alpha")
      write_session("live", cwd: w, bridgeSessionId: "session_same")
      write_session("dead", cwd: w, pid: 2**22 + 12_345, bridgeSessionId: "session_same")
      fp = RemoteLink.fingerprint({}, stale_after: STALE)
      refute_nil fp, "a tie on cwd + bridge id must not raise in sort"
      assert_equal 2, fp.size
    end

    def test_fingerprint_reparses_only_changed_files
      w = wt("alpha")
      write_session("1", cwd: w)
      write_session("2", cwd: w, bridgeSessionId: "session_two")
      cache = {}
      RemoteLink.fingerprint(cache, stale_after: STALE)
      reads = 0
      orig = RemoteLink.method(:read_json)
      stub_method(RemoteLink, :read_json, ->(f) { reads += 1; orig.call(f) }) do
        RemoteLink.fingerprint(cache, stale_after: STALE)
        assert_equal 0, reads, "unchanged files come from the cache"
        File.utime(Time.now + 5, Time.now + 5, File.join(RemoteLink.sessions_dir, "2.json"))
        RemoteLink.fingerprint(cache, stale_after: STALE)
        assert_equal 1, reads
      end
    end

    # The shared lsof parser (Agents.cwds_of) against the real OS: this process's cwd.
    def test_cwds_of_reports_a_live_pid_s_kernel_cwd
      skip "no lsof" if `command -v lsof 2>/dev/null`.strip.empty?
      got = Agents.cwds_of([Process.pid, 0, -1])
      assert_equal [Process.pid], got.keys, "invalid pids are dropped before the call"
      assert_equal File.realpath(Dir.pwd), File.realpath(got[Process.pid])
    end

    # Value: protects=a session in an UNTRACKED dir sharing a tracked worktree's name prefix shows no link;
    # fails_when=owner's "#{r}/" boundary becomes a bare prefix match; why_new=no test has a prefix-sharing
    # sibling; seam=none; no_claim=lsof attribution (cwds_of stubbed empty, recorded cwd used)
    def test_an_untracked_sibling_sharing_a_name_prefix_never_claims_the_link
      fix = wt("fix")
      write_session("1", cwd: wt("fix-ci")) # a peer tool's worktree, or any dir switchboard doesn't track
      write_session("2", cwd: fix, bridgeSessionId: "session_mine")
      links = scan([fix])
      assert_equal ["session_mine"], links[fix].map(&:bridge_id)
    end

    # Value: protects=an idle session missing statusUpdatedAt keeps every link on screen;
    # fails_when=stale?'s Numeric guard goes and nil/1000.0 raises into scan's total rescue (all links
    # vanish); why_new=stale tests always set statusUpdatedAt; seam=none; no_claim=none beyond protects
    def test_an_idle_session_without_a_status_time_neither_hides_links_nor_reads_stale
      w = wt("alpha")
      write_session("1", cwd: w, status: "idle", statusUpdatedAt: :absent)
      write_session("2", cwd: w, bridgeSessionId: "session_two")
      links = scan([w])[w].to_a
      assert_equal 2, links.size, "one odd file must not blank the scan"
      assert_equal [false, false], links.map(&:stale)
    end

    # Value: protects=links without startedAt order newest-first by a real `ps -o lstart` procStart;
    # fails_when=start_ms's strptime format/squeeze breaks (all 0, pid order wins); why_new=the existing
    # case only uses an epoch-0 procStart, indistinguishable from a parse failure; seam=none;
    # no_claim=liveness (ProcessIdentity.alive? and same? stubbed true)
    def test_procstart_in_ps_lstart_format_orders_links_without_startedat
      w = wt("alpha")
      write_session("new", cwd: w, pid: 100, startedAt: :absent, procStart: "Thu Oct  1 19:12:32 2026", bridgeSessionId: "session_new")
      write_session("old", cwd: w, pid: 200, startedAt: :absent, procStart: "Tue Sep 29 08:00:00 2026", bridgeSessionId: "session_old")
      links = stub_method(ProcessIdentity, :alive?, ->(*) { true }) do # fake pids: liveness isn't this test's subject
        stub_method(ProcessIdentity, :same?, ->(*) { true }) { scan([w])[w] }
      end
      assert_equal %w[session_new session_old], links.map(&:bridge_id), "the later lstart is newer, whatever the pids say"
    end

    # Value: protects=each pid gets ITS OWN kernel cwd from the batched lsof; fails_when=the
    # p/n pairing is off by one or every path lands on the first pid; why_new=the real-lsof
    # test above passes one pid; seam=none; no_claim=lsof output on Linux CI (skips without lsof)
    def test_cwds_of_pairs_each_pid_with_its_own_cwd
      skip "no lsof" if `command -v lsof 2>/dev/null`.strip.empty?
      other = wt("elsewhere")
      child = Process.spawn("sleep", "30", chdir: other, out: File::NULL, err: File::NULL)
      got = Agents.cwds_of([Process.pid, child])
      assert_equal File.realpath(Dir.pwd), File.realpath(got[Process.pid])
      assert_equal other, File.realpath(got[child])
    ensure
      Process.kill("TERM", child) if child
      Process.wait(child) if child
    end

    # Value: protects=under a C locale a non-ASCII kernel cwd comes back as the real path,
    # not lsof's `caf\xc3\xa9` escape (which matches no worktree, so the ⇅ — and the
    # hook-less agent dot — never shows); fails_when=cwds_of stops decoding lsof's \xNN;
    # why_new=ship 2 QA (reproduced); seam=none (real lsof); no_claim=Linux lsof output
    def test_cwds_of_decodes_lsof_escapes_under_a_c_locale
      skip "no lsof" if `command -v lsof 2>/dev/null`.strip.empty?
      cafe = wt("café")
      child = Process.spawn("sleep", "30", chdir: cafe, out: File::NULL, err: File::NULL)
      old = ENV["LC_ALL"]
      ENV["LC_ALL"] = "C"
      got = Agents.cwds_of([child])[child]
      ENV["LC_ALL"] = old
      assert_equal cafe.b, File.realpath(got).b
    ensure
      ENV["LC_ALL"] = old
      Process.kill("TERM", child) if child
      Process.wait(child) if child
    end

    # Value: protects=a decoded non-ASCII lsof cwd (raw bytes) matched against a non-ASCII
    # worktree path in another encoding finds the agent instead of raising — a raise there
    # reaches refresh_agents' rescue and blanks EVERY dot; fails_when=Agents.active compares
    # as text again; why_new=ship 2 pass 3 red team (reproduced CompatibilityError);
    # seam=none (stubs the agent cwd list); no_claim=a real hook-less agent
    def test_agents_active_matches_a_decoded_non_ascii_cwd_without_raising
      cafe = wt("café")
      decoded = Agents.lsof_path("#{File.dirname(cafe)}/caf\\xc3\\xa9/app").dup.force_encoding(Encoding::US_ASCII)
      got = stub_method(Agents, :agent_cwds, ->(*) { [decoded] }) { Agents.active([cafe]) }
      assert_equal Set[cafe], got
    end

    def test_lsof_path_keeps_a_real_dir_whose_name_looks_escaped
      odd = wt("a\\x41b")
      assert_equal odd, Agents.lsof_path(odd), "a real path is never decoded"
      assert_equal "#{path('worktrees')}/AB".b, Agents.lsof_path("#{path('worktrees')}/\\x41B").b
    end

    # Value: protects=a linked Claude killed before removing its file still moves the warm
    # fingerprint; fails_when=the tuple drops the liveness bit; why_new=fingerprint tests only
    # change file content; seam=none; no_claim=a real crashed Claude (a sleep child stands in)
    def test_fingerprint_moves_when_a_linked_session_dies_without_its_file
      w = wt("alpha")
      child = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
      write_session("dying", cwd: w, pid: child)
      cache = {}
      before = RemoteLink.fingerprint(cache, stale_after: STALE)
      Process.kill("KILL", child)
      Process.wait(child)
      child = nil
      refute_equal before, RemoteLink.fingerprint(cache, stale_after: STALE), "same file, dead pid"
    ensure
      if child
        Process.kill("KILL", child)
        Process.wait(child)
      end
    end

    # Value: protects=a reconnect that re-keys to a same-LENGTH bridge id, rewritten by rename
    # inside one mtime tick, still moves the warm fingerprint; fails_when=the stamp drops the
    # inode (size and mtime are equal); why_new=the other same-tick test changes the size;
    # seam=none; no_claim=Claude's real write path (temp + rename assumed)
    def test_fingerprint_sees_a_same_size_rekey_written_by_rename
      w = wt("alpha")
      file = File.join(RemoteLink.sessions_dir, "1.json")
      t = Time.at(Time.now.to_i)
      write_session("1", cwd: w, bridgeSessionId: "session_AAAA")
      File.utime(t, t, file)
      cache = {}
      before = RemoteLink.fingerprint(cache, stale_after: STALE)
      write_session("tmp", cwd: w, bridgeSessionId: "session_BBBB", sessionId: "s-1")
      File.rename(File.join(RemoteLink.sessions_dir, "tmp.json"), file)
      File.utime(t, t, file)
      refute_equal before, RemoteLink.fingerprint(cache, stale_after: STALE)
    end

    # Value: protects=doctor counts exactly what the glyph shows (one shape rule); fails_when=
    # health adds a field check record lacks (e.g. sessionId); why_new=no test compared the two
    # readers on one file; seam=none; no_claim=none beyond protects
    def test_health_and_scan_agree_on_a_file_without_a_session_id
      w = wt("alpha")
      write_session("1", cwd: w, sessionId: :absent)
      as_claude do
        assert_equal scan([w]).fetch(w, []).size, RemoteLink.health[:linked]
        assert_equal 1, RemoteLink.health[:shaped]
      end
    end

    # Value: protects=a pid past pid_t is skipped, not raised — Process.kill(0, pid) raises
    # RangeError, which would trip the cheap scan's and health's total rescue and blank EVERY
    # link / zero the canary; fails_when=shaped? loses its upper bound; why_new=no test used an
    # out-of-range pid; seam=none; no_claim=none beyond protects
    def test_an_out_of_range_pid_is_skipped_without_blanking_the_others
      w = wt("alpha")
      write_session("huge", cwd: w, pid: 2**40, bridgeSessionId: "session_huge")
      write_session("ok", cwd: w)
      assert_equal 1, RemoteLink.scan([w], stale_after: STALE, cheap: true)[w].size
      as_claude { assert_equal [2, 1, 1], RemoteLink.health.values_at(:files, :shaped, :linked) }
    end

    def test_health_counts_files_shape_links_and_start_time_drift
      w = wt("alpha")
      write_session("1", cwd: w)
      write_session("2", cwd: w, bridgeSessionId: :absent)
      write_session("3", cwd: w, procStart: "Thu Jan  1 00:00:00 2026") # live pid, start time moved
      File.write(File.join(RemoteLink.sessions_dir, "bad.json"), "{")
      h = as_claude { RemoteLink.health }
      assert_equal({ dir: RemoteLink.sessions_dir, files: 4, shaped: 3, alive: 3, drift: 1, linked: 1 }, h)
    end

    # Value: protects=a lone crash leftover whose pid now runs some OTHER program (pid 1) is
    # not a live Claude session, so it can't fake a format drift; fails_when=health counts a
    # pid as live without checking it is Claude; why_new=red team pass 2 (drift == alive still
    # alarmed with one leftover); seam=none (the real ps check); no_claim=a real recycled pid
    def test_health_ignores_a_live_pid_that_is_not_claude
      write_session("leftover", cwd: wt("alpha"), pid: 1, procStart: "Mon Jan  5 09:00:00 2026")
      assert_equal [1, 0, 0], RemoteLink.health.values_at(:shaped, :alive, :drift)
    end

    # Value: protects=Claude is recognized by executable name (argv[0] or the script node
    # runs), not by a substring anywhere in its arguments; fails_when=the match loosens to
    # "mentions claude"; why_new=new rule; seam=none (stubs the one ps read); no_claim=real ps
    def test_claude_pids_matches_the_executable_not_a_mention
      ps = "  11 claude --dangerously-skip-permissions\n  12 /usr/bin/node /opt/claude-code/bin/claude\n" \
           "  13 tail -f /Users/me/.claude/sessions/11.json\n  14 vim claude.md\n"
      got = stub_method(IO, :popen, ->(*, **) { ps }) { RemoteLink.claude_pids([11, 12, 13, 14]) }
      assert_equal [11, 12], got.to_a.sort
    end

    # Value: protects=a pid 0/-1 file never counts as a live session (kill(0, 0) signals
    # the process group, kill(0, -1) every process); fails_when=health's shape rule drifts
    # from record's positive-pid rule; why_new=health tests use real pids; seam=none;
    # no_claim=none beyond protects
    def test_health_ignores_non_positive_pids
      write_session("zero", cwd: wt("alpha"), pid: 0, procStart: "x")
      write_session("neg", cwd: wt("alpha"), pid: -1, procStart: "x")
      h = RemoteLink.health
      assert_equal [2, 0, 0, 0], h.values_at(:files, :shaped, :alive, :drift)
    end

    # Value: protects=the off-screen (cheap) scan spawns no ps/lsof yet still drops a dead
    # pid and places a live one by its recorded cwd; fails_when=cheap falls back to same?
    # or cwds_of; why_new=all scan tests run the full check; seam=none; no_claim=real
    # hidden-pane timing
    def test_the_cheap_scan_spawns_nothing_and_still_drops_the_dead
      w = wt("alpha")
      write_session("live", cwd: w, bridgeSessionId: "session_live")
      write_session("dead", cwd: w, pid: 2**22 + 12_345, bridgeSessionId: "session_dead")
      links = stub_method(ProcessIdentity, :same?, ->(*) { flunk "cheap must not spawn ps" }) do
        stub_method(Agents, :cwds_of, ->(*) { flunk "cheap must not run lsof" }) do
          RemoteLink.scan([w], stale_after: STALE, cheap: true)
        end
      end
      assert_equal ["session_live"], links[w].map(&:bridge_id)
    end

    # Value: protects=a /rc toggle written within one mtime tick still moves the warm
    # fingerprint; fails_when=the cache keys on mtime alone (ext4 ticks every few ms);
    # why_new=other fingerprint tests move the mtime; seam=none; no_claim=a real ext4 tick
    def test_fingerprint_sees_a_same_mtime_rewrite_that_drops_the_link
      w = wt("alpha")
      file = File.join(RemoteLink.sessions_dir, "1.json")
      t = Time.at(Time.now.to_i)
      write_session("1", cwd: w)
      File.utime(t, t, file)
      cache = {}
      before = RemoteLink.fingerprint(cache, stale_after: STALE)
      write_session("1", cwd: w, bridgeSessionId: :absent) # /rc off, same tick
      File.utime(t, t, file)
      refute_equal before, RemoteLink.fingerprint(cache, stale_after: STALE)
    end
  end
end
