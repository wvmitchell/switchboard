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

    def test_replace_is_idempotent
      once = MarkerBlock.replace("base\n", B, E, "v1")
      twice = MarkerBlock.replace(once, B, E, "v2")
      assert_equal 1, twice.scan(B).size, "exactly one region after re-replace"
      assert_includes twice, "v2"
      refute_includes twice, "v1", "the old region is stripped, not stacked"
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
  end
end
