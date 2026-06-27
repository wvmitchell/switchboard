# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

module Switchboard
  # The shared keyed-marker machinery (issue #95) that Attention and Collapse — and,
  # soon, #107's per-workspace folds — sit on. The two caller suites
  # (attention_test.rb / collapse_test.rb) are the behavior-preservation oracle; this
  # suite pins the base contract directly, especially the bits neither caller isolates
  # cleanly: the write rescue, and that a torn/empty read is skipped BEFORE the
  # keep?-block (so a falsy block can never delete a half-written marker).
  class KeyedMarkerStoreTest < SandboxTest
    # A sandboxed store dir we pass explicitly to write/delete/scan.
    def store
      path("kms")
    end

    # --- key -----------------------------------------------------------------

    def test_key_is_stable_and_distinguishes_inputs
      assert_equal KeyedMarkerStore.key("acme"), KeyedMarkerStore.key("acme")
      refute_equal KeyedMarkerStore.key("acme"), KeyedMarkerStore.key("other")
      assert_match(/\A[0-9a-f]+\z/, KeyedMarkerStore.key("acme"), "hex digest")
    end

    # The .to_s coercion (review decision CM2): a non-String value keys without
    # raising, and key(nil) is crc32("") — NOT a TypeError as bare Zlib.crc32(nil) is.
    def test_key_coerces_non_strings_and_nil
      assert_equal KeyedMarkerStore.key("acme"), KeyedMarkerStore.key(:acme)
      assert_equal KeyedMarkerStore.key(""), KeyedMarkerStore.key(nil)
    end

    # --- dir -----------------------------------------------------------------

    def test_dir_uses_env_override_when_set
      ENV["SWITCHBOARD_KMS_TEST_DIR"] = path("override") # restored by teardown's ENV.replace
      assert_equal File.expand_path(path("override")),
                   KeyedMarkerStore.dir("SWITCHBOARD_KMS_TEST_DIR", "kms")
    end

    def test_dir_falls_back_to_xdg_state_home
      refute ENV.key?("SWITCHBOARD_KMS_TEST_DIR"), "fallback test assumes the override is unset"
      assert_equal File.expand_path(File.join(ENV["XDG_STATE_HOME"], "switchboard", "kms")),
                   KeyedMarkerStore.dir("SWITCHBOARD_KMS_TEST_DIR", "kms")
    end

    # dir is total: when File.expand_path WOULD raise, it degrades to a tmpdir sibling
    # instead of letting the raise escape the delegating callers' (now argument-position)
    # state_dir. A non-existent ~user override is the reliable, portable trigger —
    # unsetting HOME doesn't raise (expand_path falls back to the password database).
    # ENV is restored by teardown's ENV.replace.
    def test_dir_degrades_to_tmpdir_when_expand_path_would_raise
      ENV["SWITCHBOARD_KMS_TEST_DIR"] = "~no_such_user_xyz_42/state"
      d = KeyedMarkerStore.dir("SWITCHBOARD_KMS_TEST_DIR", "kms")
      assert_equal File.join(Dir.tmpdir, "switchboard", "kms"), d
    end

    # --- write ---------------------------------------------------------------

    def test_write_round_trips_and_leaves_no_tmp
      KeyedMarkerStore.write(store, KeyedMarkerStore.key("x"), "x")
      assert_includes KeyedMarkerStore.scan(store) { true }, "x"
      assert_empty Dir.glob(File.join(store, "*.tmp")), "the temp file is renamed away, never left behind"
    end

    # The rescue→nil failure path (review decision T1) — the one base path no caller
    # suite covers. Portable trigger (no chmod): nest the store dir under an existing
    # FILE so mkdir_p raises and is swallowed.
    def test_write_degrades_to_nil_on_unwritable_dir
      blocker = path("blocker")
      File.write(blocker, "i am a file, not a dir")
      buried = File.join(blocker, "sub") # mkdir_p(buried) must raise: parent is a file

      assert_nil KeyedMarkerStore.write(buried, KeyedMarkerStore.key("x"), "x")
      assert_empty KeyedMarkerStore.scan(buried) { true }, "nothing was written"
    end

    # --- delete --------------------------------------------------------------

    def test_delete_removes_the_marker
      k = KeyedMarkerStore.key("x")
      KeyedMarkerStore.write(store, k, "x")
      KeyedMarkerStore.delete(store, k)
      assert_empty KeyedMarkerStore.scan(store) { true }
    end

    def test_delete_is_idempotent_when_missing
      assert_nil KeyedMarkerStore.delete(store, KeyedMarkerStore.key("ghost")),
                 "deleting a missing marker is a quiet no-op"
    end

    # --- scan ----------------------------------------------------------------

    def test_scan_is_empty_for_a_missing_dir
      assert_empty KeyedMarkerStore.scan(path("nope")) { true }
    end

    def test_scan_keeps_on_truthy_block
      KeyedMarkerStore.write(store, KeyedMarkerStore.key("keep"), "keep")
      assert_includes KeyedMarkerStore.scan(store) { true }, "keep"
    end

    # A falsy keep?-return GCs the marker (the destructive contract).
    def test_scan_garbage_collects_on_falsy_block
      k = KeyedMarkerStore.key("gcme")
      KeyedMarkerStore.write(store, k, "gcme")
      assert_empty KeyedMarkerStore.scan(store) { false }
      refute File.exist?(File.join(store, k)), "a rejected marker is deleted"
    end

    def test_scan_ignores_an_inflight_tmp_file
      FileUtils.mkdir_p(store)
      File.write(File.join(store, "deadbeef.999.tmp"), "live")
      assert_empty KeyedMarkerStore.scan(store) { true }, "an in-flight/leftover .tmp is never a marker"
    end

    # The single most important invariant: a torn (empty) read is skipped BEFORE the
    # block runs, so even a falsy keep?-block can NOT delete it — proving skip-precedes-
    # block ordering. A racing scan must never erase a marker mid-write.
    def test_scan_skips_an_empty_torn_marker_without_deleting_even_when_block_is_falsy
      FileUtils.mkdir_p(store)
      torn = File.join(store, "torn")
      File.write(torn, "")
      assert_empty KeyedMarkerStore.scan(store) { false }
      assert File.exist?(torn), "an empty (torn) read is skipped this cycle, never deleted"
    end

    # One marker whose keep?-block raises must not kill the whole scan — that file is
    # skipped, the rest still scan. Critically, a RAISING predicate must KEEP the file
    # (the per-file rescue fires before either branch), never GC it — the safety
    # property a future #107 caller relies on so a predicate bug can't wipe state.
    def test_scan_isolates_a_raising_block_per_file
      KeyedMarkerStore.write(store, KeyedMarkerStore.key("good"), "good")
      KeyedMarkerStore.write(store, KeyedMarkerStore.key("bad"), "bad")
      live = KeyedMarkerStore.scan(store) { |c| raise "boom" if c == "bad"; true }
      assert_includes live, "good"
      refute_includes live, "bad"
      assert File.exist?(File.join(store, KeyedMarkerStore.key("bad"))),
             "a raising predicate keeps the file, never GCs it"
    end

    # --- file-level dependency hygiene (Codex #8) ----------------------------

    # Each caller must require_relative its base, not lean on the umbrella
    # (switchboard.rb) to load it first. Proven by loading the caller in a FRESH ruby
    # with only lib/ on the path — a missing self-require would NameError on
    # KeyedMarkerStore and exit non-zero. (In-process this can't be caught: the
    # umbrella is already loaded by test_helper.)
    def test_attention_loads_standalone
      assert_loads_standalone "switchboard/attention", "Switchboard::Attention.scan"
    end

    def test_collapse_loads_standalone
      assert_loads_standalone "switchboard/collapse", "Switchboard::Collapse.collapsed"
    end

    private

    def assert_loads_standalone(require_path, call)
      lib = File.expand_path("../lib", __dir__)
      script = %(require #{require_path.inspect}; #{call})
      out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)
      assert status.success?, "#{require_path} must load with only lib/ on the path:\n#{out}"
    end
  end
end
