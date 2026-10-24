# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

module Switchboard
  # MarkerBlock is the shared file-surgery primitive behind BOTH the tmux.conf line
  # (`Installer`) and the global `~/.codex/config.toml` block (`CodexHook`). The
  # marked-region edits are also exercised indirectly through those callers' suites;
  # these tests pin the primitive's own contract directly — especially the branches a
  # regression would silently hit in two places at once: the symlink-cycle guard, the
  # parent-dir creation, and the mode-preservation on rewrite.
  class MarkerBlockTest < SandboxTest
    B = "# >>> sb test >>>"
    E = "# <<< sb test <<<"

    # --- marked-region text ops ---------------------------------------------

    def test_build_appends_one_normalized_region
      out = MarkerBlock.build("existing\n", B, E, "inner")
      assert_equal "existing\n#{B}\ninner\n#{E}\n", out
    end

    def test_build_inserts_a_separating_newline_when_body_lacks_one
      out = MarkerBlock.build("no-newline", B, E, "x")
      assert_equal "no-newline\n#{B}\nx\n#{E}\n", out
    end

    def test_strip_removes_the_region_and_is_a_noop_when_absent
      body = MarkerBlock.build("keep\n", B, E, "drop")
      assert_equal "keep\n", MarkerBlock.strip(body, B, E)
      assert_equal "untouched\n", MarkerBlock.strip("untouched\n", B, E)
    end

    def test_present?
      refute MarkerBlock.present?("nothing here", B)
      assert MarkerBlock.present?(MarkerBlock.build("", B, E, "x"), B)
    end

    # Value: protects=strip/present? agreeing on a marker line with trailing text (older
    # releases wrote `# >>> … >>> (managed by …)`); fails_when=strip goes back to needing
    # the bare mark + newline, so present? says "there" while strip removes nothing — the
    # false "removed" uninstall reported on a real machine; why_new=every other test
    # builds its region with the current bare marks; seam=none
    def test_strip_and_region_accept_trailing_text_on_marker_lines
      body = "keep\n#{B} (managed by an older release)\nold\n#{E}\ntail\n"
      assert MarkerBlock.present?(body, B)
      assert_equal "old\n", body[MarkerBlock.region(B, E), 1]
      assert_equal "keep\ntail\n", MarkerBlock.strip(body, B, E)
      assert_nil "no region\n"[MarkerBlock.region(B, E), 1]
    end

    # --- backup --------------------------------------------------------------

    def test_backup_is_first_write_only_and_skips_a_missing_source
      MarkerBlock.backup(path("absent.toml")) # no source → no crash, no .bak
      refute File.exist?(path("absent.toml.bak"))

      file = path("cfg.toml")
      File.write(file, "original")
      MarkerBlock.backup(file)
      File.write(file, "changed")
      MarkerBlock.backup(file) # second call must not clobber the pristine .bak
      assert_equal "original", File.read("#{file}.bak")
    end

    # --- atomic_write --------------------------------------------------------

    def test_atomic_write_creates_a_missing_parent_dir
      dest = path("nested", "deep", "cfg.toml") # neither dir exists yet
      MarkerBlock.atomic_write(dest, "hi")
      assert_equal "hi", File.read(dest), "mkdir_p'd the parent so the write lands"
    end

    def test_atomic_write_preserves_an_existing_files_mode
      dest = path("cfg.toml")
      File.write(dest, "v1")
      File.chmod(0o600, dest)
      MarkerBlock.atomic_write(dest, "v2")
      assert_equal "v2", File.read(dest)
      assert_equal 0o600, File.stat(dest).mode & 0o7777, "0600 isn't widened to the umask default"
    end

    def test_atomic_write_writes_through_a_symlink_and_leaves_no_temp
      target = path("real.toml")
      File.write(target, "old")
      link = path("link.toml")
      File.symlink(target, link)
      MarkerBlock.atomic_write(link, "new")
      assert File.symlink?(link), "the symlink itself survives"
      assert_equal "new", File.read(target), "the write went through to the target"
      assert_empty Dir.glob(path("*.sb-tmp")), "no temp left behind"
    end

    # --- real_target ---------------------------------------------------------

    def test_real_target_passes_a_plain_path_and_follows_a_chain
      assert_equal path("plain"), MarkerBlock.real_target(path("plain"))

      File.write(path("end"), "x")
      File.symlink(path("end"), path("mid"))
      File.symlink(path("mid"), path("head"))
      assert_equal path("end"), MarkerBlock.real_target(path("head"))
    end

    # A pathological symlink loop must terminate, not spin forever.
    def test_real_target_terminates_on_a_symlink_cycle
      File.symlink(path("b"), path("a"))
      File.symlink(path("a"), path("b")) # a → b → a
      out = nil
      Timeout.timeout(5) { out = MarkerBlock.real_target(path("a")) }
      assert_includes [path("a"), path("b")], out, "returns one of the cycle nodes, no infinite loop"
    end

    # Value: protects=a failed atomic write leaving no stray temp file beside the target
    # (in .claude/ it would dirty git status and keep a tree from being discarded);
    # fails_when=the rescue cleanup is dropped; why_new=cycle-2 Red Team; seam=none
    def test_a_failed_atomic_write_removes_its_temp_file
      dir = path("w")
      FileUtils.mkdir_p(dir)
      target = File.join(dir, "settings.json")
      stub_method(File, :rename, ->(*) { raise Errno::EXDEV, "rename" }) do
        assert_raises(Errno::EXDEV) { MarkerBlock.atomic_write(target, "{}") }
      end
      assert_empty Dir.children(dir)
    end

    # Value: protects=a file written with a mode never existing without it (the temp file gets
    # it before the rename); fails_when=atomic_write ignores mode:; why_new=run 4 (D6); seam=none
    # Value: protects=the reporter never landing un-runnable, even for an instant hooks exec it;
    # fails_when=the chmod moves after the rename or an existing mode wins; why_new=audit tests 2+3;
    # seam=none; no_claim=a crash between write and rename
    def test_atomic_write_sets_a_given_mode_before_the_file_appears
      target = path("script.sh")
      at_rename = nil
      real = File.method(:rename)
      spy = ->(from, to) { at_rename = File.stat(from).mode & 0o777; real.call(from, to) }
      stub_method(File, :rename, spy) { MarkerBlock.atomic_write(target, "#!/bin/sh\n", mode: 0o755) }
      assert_equal 0o755, at_rename, "the temp file already had the mode when it was renamed in"
      assert_equal 0o755, File.stat(target).mode & 0o777

      File.chmod(0o644, target) # a stale script: the requested mode outranks the existing one
      MarkerBlock.atomic_write(target, "#!/bin/sh\n", mode: 0o755)
      assert_equal 0o755, File.stat(target).mode & 0o777, "mode: overrides an existing file's mode"
    end

    # Value: protects=a private (0600) file's contents never sitting world-readable in the
    # temp copy, while a new file still gets the usual umask mode; fails_when=the temp file is
    # written before its mode is set; why_new=Codex adversarial run 4 (High); seam=none
    def test_the_temp_file_is_never_wider_than_private
      target = path("settings.json")
      File.write(target, "old")
      File.chmod(0o600, target)
      seen = nil
      real = File.method(:chmod)
      spy = ->(mode, f) { seen ||= File.stat(f).mode & 0o777; real.call(mode, f) }
      stub_method(File, :chmod, spy) { MarkerBlock.atomic_write(target, "secret") }
      assert_equal 0o600, seen, "the temp file was created private"
      assert_equal 0o600, File.stat(target).mode & 0o777
      fresh = path("fresh.json")
      MarkerBlock.atomic_write(fresh, "x")
      assert_equal 0o666 & ~File.umask, File.stat(fresh).mode & 0o777, "a new file keeps the umask default"
    end

    # Value: protects=every atomic write (config, tmux.conf, codex block, hook settings, the
    # reporter) after a crashed run left its temp file under this same pid; fails_when=the
    # rm_f before the EXCL create is dropped (EEXIST forever); why_new=run-5 testing
    # specialist; seam=none
    def test_a_leftover_temp_from_a_crashed_run_with_this_pid_doesnt_block_the_write
      target = path("settings.json")
      File.write("#{target}.#{Process.pid}.sb-tmp", "half-written")
      MarkerBlock.atomic_write(target, "{}")
      assert_equal "{}", File.read(target)
      assert_empty Dir.glob(path("*.sb-tmp")), "the stale temp was replaced, not left behind"
    end
  end
end
