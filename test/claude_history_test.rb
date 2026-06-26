# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # ClaudeHistory.migrate carries a Claude Code transcript dir across a workspace
  # rename so `/resume` keeps working (issue #42 follow-up). SWITCHBOARD_CLAUDE_PROJECTS_DIR
  # (set by SandboxTest) points the project root at the sandbox, so nothing here
  # touches the real ~/.claude.
  class ClaudeHistoryTest < SandboxTest
    def root
      ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"]
    end

    # Seed a transcript dir for `path` with one session file; returns its dir.
    def seed_history(path, session: "s1", body: "turn\n")
      dir = File.join(root, ClaudeHistory.encode(path))
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "#{session}.jsonl"), body)
      dir
    end

    def encoded(path)
      File.join(root, ClaudeHistory.encode(path))
    end

    # The encoding Claude uses: every non-alphanumeric run becomes "-", so "/",
    # "_" and "." all collapse the same way (lossy, hence forward-encode only).
    def test_encode_collapses_every_non_alphanumeric
      assert_equal "-Users-x-dvc-deal-a-b", ClaudeHistory.encode("/Users/x/dvc_deal/a.b")
      assert_equal "da-nang", ClaudeHistory.encode("da-nang") # an existing dash survives
    end

    def test_migrate_moves_the_dir_and_leaves_a_bridge
      old = path("wts", "proj", "old")
      new = path("wts", "proj", "new")
      seed_history(old)

      ClaudeHistory.migrate(old, new)

      assert File.directory?(encoded(new)), "history now lives under the new path key"
      assert File.exist?(File.join(encoded(new), "s1.jsonl")), "the transcript came along"
      assert File.symlink?(encoded(old)), "a bridge symlink is left at the old key"
      assert_equal File.realpath(encoded(new)), File.realpath(encoded(old)),
                   "the bridge resolves to the moved dir (in-flight appends still land there)"
    end

    def test_migrate_is_a_noop_when_no_history_exists
      old = path("wts", "proj", "old")
      new = path("wts", "proj", "new")

      ClaudeHistory.migrate(old, new) # nothing seeded

      refute File.exist?(encoded(new)), "no dir conjured for a path with no transcripts"
      refute File.symlink?(encoded(old)), "no bridge for a path with no transcripts"
    end

    # foo_bar and foo-bar encode to the same project dir, so there's nothing to
    # move — the history already sits at the shared key. Must not symlink-onto-self.
    def test_migrate_is_a_noop_when_the_keys_collapse_equal
      old = path("wts", "proj", "foo_bar")
      new = path("wts", "proj", "foo-bar")
      assert_equal ClaudeHistory.encode(old), ClaudeHistory.encode(new), "precondition: same key"
      dir = seed_history(old)

      ClaudeHistory.migrate(old, new)

      assert File.directory?(dir), "the shared dir is untouched"
      refute File.symlink?(dir), "it stays a real dir, not a self-referencing link"
      assert File.exist?(File.join(dir, "s1.jsonl"))
    end

    # An existing target (you'd run an agent at the new name before) is folded
    # into, never clobbered — and the merge branch still leaves a bridge at src.
    def test_migrate_merges_into_an_existing_target_without_clobbering
      old = path("wts", "proj", "old")
      new = path("wts", "proj", "new")
      seed_history(old, session: "from-old")
      File.write(File.join(seed_history(new, session: "from-new"), "from-new.jsonl"), "KEEP\n")

      ClaudeHistory.migrate(old, new)

      assert File.exist?(File.join(encoded(new), "from-old.jsonl")), "old transcript folded in"
      assert_equal "KEEP\n", File.read(File.join(encoded(new), "from-new.jsonl")),
                   "an existing target transcript is kept, not overwritten"
      assert File.symlink?(encoded(old)), "the merge branch still bridges the old key"
      assert_equal File.realpath(encoded(new)), File.realpath(encoded(old)),
                   "in-flight appends to the old key follow the bridge to the merged dir"
    end

    # Claude keys by the canonicalized cwd (`pwd -P`), so migrate must resolve
    # symlinked ancestors (macOS /var -> /private/var, a symlinked HOME) the same
    # way AgentState/Attention do — else the lookup misses and history never moves.
    # Regression for the raw-vs-realpath bug (both reviewers flagged it).
    def test_migrate_resolves_symlinked_ancestors_to_claudes_key
      realbase = path("real")
      FileUtils.mkdir_p(File.join(realbase, "wts", "proj"))
      link = path("link")
      File.symlink(realbase, link)
      old = File.join(link, "wts", "proj", "old") # reached via a symlinked ancestor
      new = File.join(link, "wts", "proj", "new")
      # The key a real agent (pwd -P) wrote under: ancestors fully resolved (the
      # sandbox tmpdir itself is under macOS /var -> /private/var), leaf appended.
      canon_parent = File.realpath(File.join(realbase, "wts", "proj"))
      seed_history(File.join(canon_parent, "old"))

      ClaudeHistory.migrate(old, new)

      assert File.exist?(File.join(encoded(File.join(canon_parent, "new")), "s1.jsonl")),
             "history found + moved under the canonical key despite a symlinked ancestor"
      refute File.exist?(File.join(encoded(File.join(link, "wts", "proj", "new")), "s1.jsonl")),
             "nothing written under the raw (un-canonicalized) key"
    end

    # A second rename before any restart: the old key is already a bridge from the
    # first rename. Follow it to the real dir and re-point, so no symlink chain forms.
    def test_migrate_follows_a_prior_bridge_instead_of_chaining
      old = path("wts", "proj", "old")
      new = path("wts", "proj", "new")
      real = File.join(root, "real-dir")
      FileUtils.mkdir_p(real)
      File.write(File.join(real, "s1.jsonl"), "turn\n")
      FileUtils.mkdir_p(File.dirname(encoded(old)))
      File.symlink(real, encoded(old)) # a prior rename's bridge

      ClaudeHistory.migrate(old, new)

      assert File.directory?(encoded(new)), "the real dir moved to the new key"
      refute File.symlink?(encoded(new)), "the new key is the real dir, not a link"
      assert File.exist?(File.join(encoded(new), "s1.jsonl"))
      refute File.exist?(real), "the prior real dir was moved, not left behind"
      assert File.symlink?(encoded(old)), "the old bridge is re-pointed"
      assert_equal File.realpath(encoded(new)), File.realpath(encoded(old)),
                   "old key resolves straight to the new dir — no chain through the dead real dir"
    end

    # GC parity with Reconcile.reap_bridges: dangling rename bridges are swept, but
    # a live bridge (and a chain whose endpoint still exists) is kept.
    def test_reap_bridges_removes_only_dangling_links
      FileUtils.mkdir_p(root)
      real = File.join(root, "keep-real")
      FileUtils.mkdir_p(real)
      File.symlink(real, File.join(root, "live-link"))           # resolves -> kept
      File.symlink(File.join(root, "gone"), File.join(root, "dead-link")) # dangles -> reaped
      # A dangling chain (a -> b -> gone): File.exist? follows the whole chain, so both go.
      File.symlink(File.join(root, "missing"), File.join(root, "b"))
      File.symlink(File.join(root, "b"), File.join(root, "a"))

      ClaudeHistory.reap_bridges

      assert File.directory?(real), "a real project dir is untouched"
      assert File.symlink?(File.join(root, "live-link")), "a live bridge is kept"
      refute File.symlink?(File.join(root, "dead-link")), "a dangling bridge is swept"
      refute File.symlink?(File.join(root, "a")), "a dangling chain is swept (head)"
      refute File.symlink?(File.join(root, "b")), "a dangling chain is swept (link)"
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
