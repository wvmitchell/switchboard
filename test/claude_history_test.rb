# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # ClaudeHistory carries a Claude Code transcript folder across a workspace rename by hard
  # links, so both keys stay real directories. SWITCHBOARD_CLAUDE_PROJECTS_DIR (SandboxTest)
  # points the projects root at the sandbox; writers are stubbed per test, so no real
  # Claude process or `ps` decides anything here.
  class ClaudeHistoryTest < SandboxTest
    SID = "0b7c5d2e-1f3a-4b5c-8d9e-0a1b2c3d4e5f"
    LONG_AGO = Time.now - 3600

    def setup
      super
      FileUtils.mkdir_p(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"])
      # The sandbox tmpdir sits under macOS's /var symlink; Claude's keys are realpaths.
      ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"] = File.realpath(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"])
    end

    def root = ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"]

    def key(p) = File.join(root, ClaudeHistory.encode(p))

    def wt(*parts)
      d = path("wts", *parts)
      FileUtils.mkdir_p(File.dirname(d))
      File.join(File.realpath(File.dirname(d)), File.basename(d))
    end

    # A Claude transcript folder for `p`: one session log plus its <uuid>/ subfolder.
    def seed(p, body: "turn\n", age: LONG_AGO)
      dir = key(p)
      FileUtils.mkdir_p(File.join(dir, SID, "tool-results"))
      File.write(File.join(dir, "#{SID}.jsonl"), body)
      File.write(File.join(dir, SID, "tool-results", "r1.txt"), "out\n")
      age!(dir, age)
      dir
    end

    def age!(dir, time)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).each { |r| File.lutime(time, time, File.join(dir, r)) }
      File.utime(time, time, dir)
    end

    def ino(file) = File.lstat(file).ino

    # Every key a session writes to must be what gstack's guard accepts.
    def assert_guard_ok(dir)
      assert File.directory?(dir), "#{dir} is a directory"
      assert_equal dir, File.realpath(dir), "#{dir} is real, not reached through a symlink"
      assert File.lstat(File.join(dir, "#{SID}.jsonl")).file?, "its transcript is a regular file"
    end

    def no_symlinks = refute(Dir.children(root).any? { |n| File.symlink?(File.join(root, n)) }, "no symlink in projects/")

    def with_writers(index, &block) = stub_method(ClaudeSessions, :writers_by_key, ->(*) { index }, &block)

    def owned = ["#{ClaudeHistory.encode(File.realpath(FileUtils.mkdir_p(path('wts')).first))}-"]

    def legacy_bridge(from_path, to_dir)
      File.symlink(to_dir, key(from_path))
      key(from_path)
    end

    def test_encode_collapses_every_non_alphanumeric
      assert_equal "-Users-x-my-app-a-b", ClaudeHistory.encode("/Users/x/my_app/a.b")
      assert_equal "da-nang", ClaudeHistory.encode("da-nang")
    end

    # --- link -------------------------------------------------------------------------

    # Value: protects=a renamed live session keeps a real folder and the new key has its
    # history; fails_when=link moves the folder or leaves a symlink; why_new=link replaces
    # migrate; seam=none; no_claim=Claude's own append path (live check a)
    def test_link_leaves_both_keys_real_with_shared_inodes
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)

      assert_equal :linked, with_writers({}) { ClaudeHistory.link(old, new) }

      assert_guard_ok(key(old))
      assert_guard_ok(key(new))
      assert_equal ino(File.join(key(old), "#{SID}.jsonl")), ino(File.join(key(new), "#{SID}.jsonl"))
      assert_equal "out\n", File.read(File.join(key(new), SID, "tool-results", "r1.txt"))
      refute File.symlink?(File.join(key(new), SID)), "subfolders are real"
      no_symlinks
      File.write(File.join(key(old), "#{SID}.jsonl"), "more\n", mode: "a")
      assert_equal "turn\nmore\n", File.read(File.join(key(new), "#{SID}.jsonl")), "an append through the old key shows at the new"
    end

    def test_link_never_overwrites_a_file_at_the_new_key
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      FileUtils.mkdir_p(key(new))
      File.write(File.join(key(new), "#{SID}.jsonl"), "KEEP\n")

      with_writers({}) { ClaudeHistory.link(old, new) }

      assert_equal "KEEP\n", File.read(File.join(key(new), "#{SID}.jsonl"))
      assert_equal "turn\n", File.read(File.join(key(old), "#{SID}.jsonl"))
    end

    def test_link_without_history_or_with_one_shared_key_does_nothing
      assert_equal :no_source, ClaudeHistory.link(wt("proj", "old"), wt("proj", "new"))
      refute File.exist?(key(wt("proj", "new")))

      foo = wt("proj", "foo_bar")
      dir = seed(foo)
      assert_equal :no_source, ClaudeHistory.link(foo, wt("proj", "foo-bar"))
      assert File.exist?(File.join(dir, "#{SID}.jsonl"))
    end

    # Value: protects=a tool's folder beside the transcripts (monitor/) is carried, and a
    # symlink there can't silently stop the carry; fails_when=the layout check refuses plain
    # folders, the whole folder, or hides the skip; why_new=adversarial review (monitor/);
    # seam=none; no_claim=future Claude layouts
    def test_an_unrecognized_entry_is_skipped_and_reported_partial
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      FileUtils.mkdir_p(File.join(key(old), "monitor"))
      File.write(File.join(key(old), "monitor", "state.json"), "{}")
      File.symlink("/etc/hosts", File.join(key(old), "top-link"))
      File.symlink("/etc/hosts", File.join(key(old), SID, "nested-link"))

      assert_equal :partial, with_writers({}) { ClaudeHistory.link(old, new) }

      assert File.exist?(File.join(key(new), "#{SID}.jsonl")), "every transcript still links"
      assert File.exist?(File.join(key(new), "monitor", "state.json")), "a plain folder is carried"
      refute File.symlink?(File.join(key(new), "top-link"))
      refute File.symlink?(File.join(key(new), SID, "nested-link")), "a nested symlink is never followed or copied"
      assert_equal 1, ClaudeHistory.errors.first, "the skipped top-level entry is logged, so doctor can name it"
    end

    def test_a_split_transcript_at_the_new_key_reports_partial
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      seed(new, body: "a different copy\n")

      assert_equal :partial, with_writers({}) { ClaudeHistory.link(old, new) }
      assert_equal "a different copy\n", File.read(File.join(key(new), "#{SID}.jsonl")), "never overwritten"
    end

    def test_a_projects_bridge_at_the_new_key_becomes_a_real_folder
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      elsewhere = seed(wt("proj", "elsewhere"))
      legacy_bridge(new, elsewhere)

      with_writers({}) { ClaudeHistory.link(old, new) }

      refute File.symlink?(key(new))
      assert_guard_ok(key(new))
      assert File.exist?(File.join(elsewhere, "#{SID}.jsonl")), "the bridge's target keeps its data"
    end

    # Value: protects=a workspace renamed by the old code (src is a bridge) still carries
    # its history; fails_when=link reads the symlink after deleting it; why_new=Spec pass 3
    # ordering; seam=none; no_claim=none beyond protects
    def test_a_writerless_legacy_bridge_at_the_old_key_links_from_its_target
      old = wt("proj", "old")
      new = wt("proj", "new")
      real = seed(wt("proj", "first"))
      legacy_bridge(old, real)

      assert_equal :linked, with_writers({}) { ClaudeHistory.link(old, new) }

      assert_equal ino(File.join(real, "#{SID}.jsonl")), ino(File.join(key(new), "#{SID}.jsonl"))
      assert_guard_ok(key(new))
    end

    def test_a_writer_held_legacy_bridge_at_the_old_key_becomes_real
      old = wt("proj", "old")
      new = wt("proj", "new")
      real = seed(wt("proj", "first"))
      bridge = legacy_bridge(old, real)

      with_writers({ File.basename(bridge) => [{ pid: 1 }] }) { ClaudeHistory.link(old, new) }

      assert_guard_ok(bridge)
      assert_guard_ok(key(new))
    end

    # A rename A->B->C, then back to A: every key stays real and nothing is lost or clobbered.
    def test_chained_renames_keep_everything_and_relink_cleanly
      a = wt("proj", "a")
      b = wt("proj", "b")
      c = wt("proj", "c")
      seed(a)
      with_writers({}) do
        ClaudeHistory.link(a, b)
        ClaudeHistory.link(b, c)
        File.write(File.join(key(c), "f00dcafe.jsonl"), "c only\n")
        ClaudeHistory.link(c, a)
      end

      [a, b, c].each { |p| assert_guard_ok(key(p)) }
      assert_equal "c only\n", File.read(File.join(key(a), "f00dcafe.jsonl"))
      assert_equal "turn\n", File.read(File.join(key(a), "#{SID}.jsonl"))
      no_symlinks
    end

    # --- realize ----------------------------------------------------------------------

    def test_a_writerless_quiet_bridge_is_deleted_and_its_target_kept
      real = seed(wt("proj", "real"))
      bridge = legacy_bridge(wt("proj", "old"), real)

      assert_equal :deleted, with_writers({}) { ClaudeHistory.realize(bridge, now: Time.now) }

      refute File.symlink?(bridge)
      assert File.exist?(File.join(real, "#{SID}.jsonl"))
    end

    def test_a_bridge_whose_target_changed_recently_is_kept
      real = seed(wt("proj", "real"), age: Time.now - 60)
      bridge = legacy_bridge(wt("proj", "old"), real)

      assert_equal :kept_recent, with_writers({}) { ClaudeHistory.realize(bridge, now: Time.now) }
      assert File.symlink?(bridge)
    end

    # Value: protects=a failed `ps` or unreadable sessions dir never deletes under a live
    # session; fails_when=nil writers read as "none"; why_new=new; seam=none; no_claim=real ps
    def test_unknown_writers_convert_rather_than_delete
      real = seed(wt("proj", "real"))
      bridge = legacy_bridge(wt("proj", "old"), real)

      assert_equal :converted, with_writers(nil) { ClaudeHistory.realize(bridge, now: Time.now) }
      assert_guard_ok(bridge)
      assert_equal ino(File.join(real, "#{SID}.jsonl")), ino(File.join(bridge, "#{SID}.jsonl"))
      assert_empty Dir.children(root).grep(/\.sb-/), "no staging folder left"
    end

    def test_conversion_without_the_atomic_swap_still_lands_real
      real = seed(wt("proj", "real"))
      bridge = legacy_bridge(wt("proj", "old"), real)

      stub_method(ClaudeHistory, :exchange, ->(*) { false }) do
        assert_equal :converted, with_writers(nil) { ClaudeHistory.realize(bridge, now: Time.now) }
      end
      assert_guard_ok(bridge)
      assert_empty Dir.children(root).grep(/\.sb-/)
    end

    # Claude recreates the folder in the gap between unlink and rename: ours join its
    # files, a fresh transcript of its own is kept, nothing is overwritten.
    def test_a_path_recreated_mid_conversion_keeps_both
      real = seed(wt("proj", "real"))
      bridge = legacy_bridge(wt("proj", "old"), real)
      original = ClaudeHistory.method(:place)
      racing = lambda do |temp, link|
        Dir.mkdir(link)
        File.write(File.join(link, "#{SID}.jsonl"), "fresh\n")
        original.call(temp, link)
      end

      stub_method(ClaudeHistory, :exchange, ->(*) { false }) do
        stub_method(ClaudeHistory, :place, racing) { with_writers(nil) { ClaudeHistory.realize(bridge, now: Time.now) } }
      end

      assert_equal "fresh\n", File.read(File.join(bridge, "#{SID}.jsonl")), "Claude's fresh file is not overwritten"
      assert_equal "out\n", File.read(File.join(bridge, SID, "tool-results", "r1.txt")), "the rest linked in"
      assert_empty Dir.children(root).grep(/\.sb-/)
    end

    def test_a_failed_placement_keeps_the_staged_copy
      real = seed(wt("proj", "real"))
      bridge = legacy_bridge(wt("proj", "old"), real)

      stub_method(ClaudeHistory, :exchange, ->(*) { false }) do
        stub_method(ClaudeHistory, :place, ->(*) { raise Errno::EACCES }) do
          assert_equal :failed, with_writers(nil) { ClaudeHistory.realize(bridge, now: Time.now) }
        end
      end

      assert_equal real, File.realpath(bridge), "the live route is put back"
      staged = Dir.children(root).grep(/\.sb-/)
      assert_equal 1, staged.size, "staging is never deleted on failure"
      assert File.exist?(File.join(root, staged.first, "#{SID}.jsonl"))
      assert_equal 1, ClaudeHistory.errors.first, "the failure is logged"
    end

    # Value: protects=a conversion that couldn't stage every file never swaps in a
    # half-copy; fails_when=convert ignores staged.partial or leaves its staging folder;
    # why_new=only successful conversions were tested; seam=none; no_claim=the swap step
    def test_an_incomplete_staging_keeps_the_bridge_and_drops_the_staging
      real = seed(wt("proj", "real"))
      File.symlink("/etc/hosts", File.join(real, SID, "nested-link"))
      bridge = legacy_bridge(wt("proj", "old"), real)

      assert_equal :failed, with_writers(nil) { ClaudeHistory.realize(bridge, now: Time.now) }

      assert File.symlink?(bridge), "the bridge still routes to the full folder"
      assert File.exist?(File.join(real, "#{SID}.jsonl"))
      assert_empty Dir.children(root).grep(/\.sb-/), "only our extra names were removed"
    end

    # Value: protects=deletion only on a bridge nothing else routes through and whose
    # target we fully recognize; fails_when=the pointed_to? or recognized_layout? guard is
    # dropped; why_new=sweep's chain test converts the head first, so neither guard fires;
    # seam=none; no_claim=chains deeper than outer_first's walk
    def test_a_bridge_in_a_chain_or_over_an_unrecognized_folder_is_kept
      real = seed(wt("proj", "real"))
      middle = legacy_bridge(wt("proj", "mid"), real)
      legacy_bridge(wt("proj", "head"), middle)
      odd = seed(wt("proj", "odd"))
      File.symlink("/etc/hosts", File.join(odd, "a-link"))
      age!(odd, LONG_AGO)
      over_odd = legacy_bridge(wt("proj", "over-odd"), odd)

      with_writers({}) do
        assert_equal :pointed_to, ClaudeHistory.realize(middle, now: Time.now)
        assert_equal :kept_unrecognized, ClaudeHistory.realize(over_odd, now: Time.now)
      end
      assert File.symlink?(middle)
      assert File.symlink?(over_odd)
    end

    # Value: protects=a carry never writes through a symlinked subfolder into a place
    # outside the new key; fails_when=mirror's destination-symlink guard is dropped;
    # why_new=only source-side symlinks were tested; seam=none; no_claim=races after the check
    def test_link_never_writes_through_a_symlinked_subfolder_at_the_new_key
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      outside = path("outside")
      FileUtils.mkdir_p(outside)
      FileUtils.mkdir_p(key(new))
      File.symlink(outside, File.join(key(new), SID))

      assert_equal :partial, with_writers({}) { ClaudeHistory.link(old, new) }

      assert_empty Dir.children(outside), "nothing landed outside the key"
      assert File.exist?(File.join(key(new), "#{SID}.jsonl")), "the rest still linked"
    end

    def test_a_bridge_outside_projects_or_dangling_is_left_alone
      outside = path("elsewhere")
      FileUtils.mkdir_p(outside)
      out_link = legacy_bridge(wt("proj", "out"), outside)
      dangling = legacy_bridge(wt("proj", "gone"), File.join(root, "nothing-here"))

      with_writers({}) do
        assert_equal :skipped, ClaudeHistory.realize(out_link, now: Time.now)
        assert_equal :skipped, ClaudeHistory.realize(dangling, now: Time.now)
      end
      assert File.symlink?(out_link)
      assert File.symlink?(dangling)
    end

    # --- sweep ------------------------------------------------------------------------

    # Value: protects=a live session writing through the head of a chain keeps a working
    # folder while the rest is cleaned; fails_when=a middle link is deleted first or under
    # it; why_new=new; seam=none; no_claim=none beyond protects
    def test_sweep_walks_a_chain_from_its_head
      b = seed(wt("proj", "b"))
      a = legacy_bridge(wt("proj", "a"), b)
      x = legacy_bridge(wt("proj", "x"), a)
      foreign = File.join(root, "-somewhere-else")
      File.symlink(b, foreign)

      sum = with_writers({ File.basename(x) => [{ pid: 1 }] }) { ClaudeHistory.sweep(owned: owned, now: Time.now) }

      assert_guard_ok(x)
      refute File.symlink?(a), "the writerless middle link is gone"
      assert File.exist?(File.join(b, "#{SID}.jsonl")), "the real folder is untouched"
      assert File.symlink?(foreign), "a symlink under someone else's key is never touched"
      assert_equal 1, sum.converted
      assert_equal 1, sum.deleted
    end

    def test_sweep_removes_only_old_staging_folders
      old = File.join(root, ".-k.sb-1-abcd")
      fresh = File.join(root, ".-k.sb-2-ef01")
      [old, fresh].each { |d| Dir.mkdir(d) }
      File.utime(Time.now - 7200, Time.now - 7200, old)

      with_writers({}) { ClaudeHistory.sweep(owned: owned, now: Time.now) }

      refute File.exist?(old)
      assert File.exist?(fresh)
    end

    def test_reap_bridges_removes_only_owned_dangling_links
      mine = legacy_bridge(wt("proj", "gone"), File.join(root, "missing"))
      theirs = File.join(root, "-not-ours")
      File.symlink(File.join(root, "missing"), theirs)

      ClaudeHistory.reap_bridges(owned: owned)

      refute File.symlink?(mine)
      assert File.symlink?(theirs)
    end

    # --- catch_up ---------------------------------------------------------------------

    def test_catch_up_links_what_the_old_key_gained_and_reports_clashes
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      with_writers({}) { ClaudeHistory.link(old, new) }
      File.write(File.join(key(old), "1234abcd-0000-0000-0000-000000000000.jsonl"), "after clear\n")
      File.write(File.join(key(old), SID, "custom-title.json"), "old title")
      File.write(File.join(key(new), SID, "custom-title.json"), "new title")

      sum = ClaudeHistory.catch_up([[old, new]])

      assert_equal "after clear\n", File.read(File.join(key(new), "1234abcd-0000-0000-0000-000000000000.jsonl"))
      assert_equal 1, sum.linked
      assert_equal "new title", File.read(File.join(key(new), SID, "custom-title.json")), "PR1 replaces nothing"
      assert_equal 1, sum.clashes.size
      assert File.directory?(key(old)), "PR1 never removes the old folder"
    end

    # Value: protects=a reused name never receives a stranger's history; fails_when=a pair
    # qualifies without rename's inode evidence; why_new=CEO row 33; seam=none;
    # no_claim=Claude's resume picker (live check e)
    def test_a_pair_without_shared_inodes_is_not_caught_up
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      FileUtils.mkdir_p(key(new))
      File.write(File.join(key(new), "feedface-0000-0000-0000-000000000000.jsonl"), "someone else\n")

      sum = ClaudeHistory.catch_up([[old, new]])

      assert_equal 0, sum.linked
      refute File.exist?(File.join(key(new), "#{SID}.jsonl"))
    end

    # Value: protects=a rename whose own link was skipped (lock busy) is still caught up once
    # a session has started at the new path, while a reused name's older sessions are not;
    # fails_when=qualifies? ignores the bridge's time, or trusts files older than it;
    # why_new=adversarial review (all three voices); seam=none; no_claim=filesystems without birthtime
    def test_a_skipped_link_is_caught_up_when_the_new_key_only_holds_newer_files
      old = wt("proj", "old")
      new = wt("proj", "new")
      stale = wt("proj", "stale")
      seed(old)
      FileUtils.mkdir_p([new, stale, key(new), key(stale)])
      File.write(File.join(key(stale), "feedface-0000-0000-0000-000000000000.jsonl"), "earlier owner\n")
      age!(key(stale), LONG_AGO)
      sleep 0.01
      FileUtils.rm_rf(old)
      File.symlink(new, old) # rename's worktree bridge, made after the stale files
      sleep 0.01
      File.write(File.join(key(new), "beefcafe-0000-0000-0000-000000000000.jsonl"), "new session\n")

      assert_equal 2, ClaudeHistory.catch_up([[old, new]]).linked, "carried after the fact"
      assert_equal 0, ClaudeHistory.catch_up([[old, stale]]).linked, "older files mean another owner"
    end

    def test_a_new_key_with_no_files_yet_is_caught_up
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)

      ClaudeHistory.catch_up([[old, new]])

      assert_guard_ok(key(new))
    end

    def test_catch_up_is_a_noop_when_the_pair_shares_one_folder
      foo = wt("proj", "foo_bar")
      dir = seed(foo)

      assert_equal 0, ClaudeHistory.catch_up([[foo, wt("proj", "foo-bar")]]).linked
      assert File.exist?(File.join(dir, "#{SID}.jsonl"))
    end

    # Value: protects=the sidebar never freezes behind a prune holding the history lock;
    # fails_when=link waits unbounded on the lock; why_new=red-team finding; seam=none;
    # no_claim=real prune durations
    def test_link_gives_up_on_a_held_lock_and_reports_partial
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)
      ClaudeHistory.with_lock do
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          writer.write(with_writers({}) { ClaudeHistory.link(old, new) }.inspect)
          exit!(0)
        end
        writer.close
        unless ProcessIdentity.wait_within(pid, 6)
          Process.kill("KILL", pid)
          Process.wait(pid)
          flunk "link waited on the lock instead of giving up"
        end
        assert_equal ":partial", reader.read, "prune's catch-up finishes the carry later"
      end
      refute File.exist?(key(new))
    end

    # Value: protects=a new workspace or rename destination never inherits a stranger's
    # history through a projects bridge; fails_when=the bridge is kept when provably free,
    # or converted when doubtful; why_new=targeted + red-team findings; seam=none;
    # no_claim=Claude's own resume picker
    def test_a_new_owners_key_drops_a_free_bridge_and_never_converts_a_doubtful_one
      stranger = seed(wt("proj", "stranger"), age: Time.now - 30)
      File.write(File.join(stranger, ".odd"), "x")
      legacy_bridge(wt("proj", "fresh"), stranger)
      assert_equal :deleted, with_writers({}) { ClaudeHistory.free_key(wt("proj", "fresh")) }
      refute File.symlink?(key(wt("proj", "fresh"))), "a recent or odd target doesn't keep a free bridge"
      assert File.exist?(File.join(stranger, "#{SID}.jsonl")), "the target keeps its data"

      old = wt("proj", "old")
      seed(old)
      doubtful = legacy_bridge(wt("proj", "new"), stranger)
      assert_equal :partial, with_writers(nil) { ClaudeHistory.link(old, wt("proj", "new")) }
      assert File.symlink?(doubtful), "never converted into the new owner's history"
      assert_equal 1, ClaudeHistory.errors.first, "and doctor hears about it"
    end

    # --- doctor helpers ---------------------------------------------------------------

    def test_inspect_pairs_counts_without_changing_anything
      old = wt("proj", "old")
      new = wt("proj", "new")
      seed(old)

      found = ClaudeHistory.inspect_pairs([[old, new]])

      assert_equal 2, found.first[:missing]
      refute File.exist?(key(new))
    end

    # Value: protects=doctor's reused-name line fires on an earlier workspace's sessions
    # and not on this one's own; fails_when=reused? compares the wrong times or always
    # answers false; why_new=reused? had no test; seam=none; no_claim=Linux (no birthtime)
    def test_reused_tells_an_earlier_workspaces_sessions_from_its_own
      w = wt("proj", "reused")
      FileUtils.mkdir_p(w)
      skip "no birthtime on this filesystem" unless (File.stat(w).birthtime rescue nil)

      refute ClaudeHistory.reused?(w), "no history folder yet"
      seed(w, age: Time.now)
      refute ClaudeHistory.reused?(w), "its own fresh sessions"
      age!(key(w), File.stat(w).birthtime - 3600)
      assert ClaudeHistory.reused?(w), "sessions older than the workspace"
    end

    def test_errors_are_one_line_each_and_trimmed
      2.times { ClaudeHistory.record_error("link", "/x/key", RuntimeError.new("boom\nsecond line")) }
      count, since = ClaudeHistory.errors
      assert_equal 2, count
      refute_empty since
      assert_equal 2, File.readlines(ClaudeHistory.log_path).size, "a multi-line message stays one line"

      60.times { ClaudeHistory.record_error("link", "/x/key", RuntimeError.new("e")) }
      ClaudeHistory.trim_log
      assert_equal ClaudeHistory::LOG_LINES, File.readlines(ClaudeHistory.log_path).size
    end

    def test_projects_root_prefers_the_override_then_claude_config_then_home
      assert_equal root, ClaudeHistory.projects_root, "the test override wins"

      ENV.delete("SWITCHBOARD_CLAUDE_PROJECTS_DIR")
      ENV["CLAUDE_CONFIG_DIR"] = path("custom-claude")
      assert_equal path("custom-claude", "projects"), ClaudeHistory.projects_root

      ENV.delete("CLAUDE_CONFIG_DIR")
      assert_equal File.join(Dir.home, ".claude", "projects"), ClaudeHistory.projects_root
    end
  end
end
