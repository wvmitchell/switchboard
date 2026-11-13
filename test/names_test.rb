# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Names: what each workspace is called, keyed by its folder's realpath. Real files in the
  # sandboxed store; the reads are all-or-nothing and never delete.
  class NamesTest < SandboxTest
    def dir(*parts) = FileUtils.mkdir_p(path(*parts)).first.then { |d| File.realpath(d) }

    def test_write_read_and_delete_round_trip
      real = dir("wts", "app", "calm-fern-0a1b")
      assert_equal :ok, Names.write(real, "oauth-fix", project: "app", branch: "wv/oauth-fix", named_at: 5)
      status, map = Names.read_all
      assert_equal :ok, status
      e = map.fetch(real)
      assert_equal ["oauth-fix", "5", "app", "wv/oauth-fix", ""], [e.name, e.named_at, e.project, e.branch, e.missing_since]
      assert_equal "oauth-fix", Names.name_for(real)
      assert_equal :ok, Names.delete(real)
      assert_equal :ok, Names.delete(real), "deleting a missing entry is fine"
      assert_nil Names.name_for(real)
    end

    # Value: protects=a hand-edited entry can never reach tmux or a printed command;
    # fails_when=write or read stops validating; seam=none
    def test_a_name_that_isnt_a_clean_leaf_is_refused_and_never_read
      real = dir("wts", "app", "x")
      ["a/b", "has\ttab", "esc\e[31m", "semi;colon", ""].each do |bad|
        refute_equal :ok, Names.write(real, bad, project: "app"), bad.inspect
      end
      FileUtils.mkdir_p(Names.dir)
      File.write(File.join(Names.dir, Names.key(real)), "#{real}\tbad;name\t1\tapp\t\t\n")
      assert_empty Names.read_all.last
      assert_equal [File.join(Names.dir, Names.key(real))], Names.invalid
    end

    def test_an_entry_under_the_wrong_key_is_ignored_and_reported
      real = dir("wts", "app", "x")
      FileUtils.mkdir_p(Names.dir)
      File.write(File.join(Names.dir, "not-its-key"), "#{real}\tok-name\t1\tapp\t\t\n")
      assert_empty Names.read_all.last
      assert_equal 1, Names.invalid.size
    end

    # Value: protects=an unreadable store is never read as "no names" by anything that
    # decides; fails_when=read_all returns a partial or empty map on an error; seam=none
    def test_an_unreadable_store_is_an_error_not_an_empty_map
      skip "root reads anything" if Process.uid.zero?
      real = dir("wts", "app", "x")
      Names.write(real, "named", project: "app")
      File.chmod(0o000, Names.dir)
      status, where, = Names.read_all
      assert_equal :error, status
      assert_equal Names.dir, where
    ensure
      File.chmod(0o755, Names.dir) if File.exist?(Names.dir)
    end

    # Value: protects=an entry deleted mid-read (a rename back, a delete, prune) never makes the
    # whole store read as unreadable; fails_when=read_all lets a per-file ENOENT abort the
    # scan; seam=File.read
    def test_an_entry_deleted_mid_read_is_skipped_not_an_error
      a = dir("wts", "app", "a")
      b = dir("wts", "app", "b")
      Names.write(a, "kept", project: "app")
      Names.write(b, "gone", project: "app")
      gone = File.join(Names.dir, Names.key(b))
      real_read = File.method(:read)
      status, map = stub_method(File, :read, ->(f, **o) { f == gone ? raise(Errno::ENOENT, f) : real_read.call(f, **o) }) { Names.read_all }
      assert_equal :ok, status
      assert_equal ["kept"], map.values.map(&:name)
    end

    # Value: protects=a long-lived sidebar keeps showing names through a transient read
    # failure; fails_when=the cache is dropped on an error; seam=Names.read_all
    def test_a_failed_reread_keeps_the_last_good_names
      real = dir("wts", "app", "x")
      Names.write(real, "named", project: "app")
      assert_equal "named", Names.name_for(real)
      FileUtils.touch(File.join(Names.dir, "zz-new")) # the stamp changes, so the next lookup rereads
      stub_method(Names, :read_all, -> { [:error, Names.dir, "EIO"] }) do
        assert_equal "named", Names.name_for(real)
      end
    end

    # Value: protects=every reader resolves a duplicate the same way, from local facts alone,
    # and never splits a session; fails_when=one side keeps the name, or a dead entry or a
    # symlink flips a live workspace; seam=none
    def test_a_stored_name_yields_to_a_folder_or_a_live_entry_with_the_same_session_name
      a = dir("wts", "app", "a")
      b = dir("wts", "app", "b")
      dir("wts", "app", "taken.name")
      Names.write(a, "taken-name", project: "app")
      assert_nil Names.name_for(a), "a folder that sanitizes alike wins"

      Names.write(a, "same", project: "app")
      Names.write(b, "same", project: "app")
      assert_nil Names.name_for(a)
      assert_nil Names.name_for(b), "both sides of an entry clash fall back"

      FileUtils.rm_rf(b)
      assert_equal "same", Names.name_for(a), "a dead entry can't flip a live workspace"

      File.symlink(a, File.join(File.dirname(a), "bridge-name"))
      Names.write(a, "bridge-name", project: "app")
      assert_equal "bridge-name", Names.name_for(a), "a legacy bridge symlink never takes a name"
    end

    def test_worktree_display_name_reads_the_store_lazily_by_realpath
      real = dir("wts", "app", "calm-fern-0a1b")
      link = path("link-to-it")
      File.symlink(real, link)
      Names.write(real, "oauth-fix", project: "app")
      assert_equal "oauth-fix", Worktree.new(project: "app", path: link).display_name
      assert_equal "calm-fern-0a1b", Worktree.new(project: "app", path: real).folder_name
      assert_equal "sb/app/oauth-fix", Tmux.session_name(Worktree.new(project: "app", path: real))
    end

    # Value: protects=a delete drops the name only once the folder is really gone, and a
    # failed removal keeps it; fails_when=forget_name runs before or without the removal;
    # seam=Git.remove_worktree
    def test_deleting_a_workspace_drops_its_name_only_after_the_folder_is_gone
      repo = temp_git_repo("app")
      wt = path("wts", "app", "feat")
      git(repo, "worktree", "add", "-q", "-b", "feat", wt)
      real = File.realpath(wt)
      Names.write(real, "oauth-fix", project: "app")
      stub_method(Git, :remove_worktree, ->(*, **) { false }) { Workspaces.remove!(repo, wt, "feat") }
      assert_equal "oauth-fix", Names.name_for(real), "a failed removal keeps the name"
      Workspaces.remove!(repo, wt, "feat")
      refute File.exist?(wt)
      assert_empty Names.read_all.last
    end
  end
end
