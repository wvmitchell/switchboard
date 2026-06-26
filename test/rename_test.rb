# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Rename.perform end-to-end against real throwaway worktrees (the move + bridge
  # are real git; the tmux session rename is the one stubbed seam). The shared
  # core behind both the sidebar `r` key and `switchboard rename` (issue #42).
  class RenameTest < SandboxTest
    # Config registering `proj` -> a real repo.
    def config_for(repo)
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"),
                                        "projects" => [{ "name" => "proj", "path" => repo }]))
      Config.new
    end

    # A linked worktree at wts/proj/<leaf> off `repo` (returns its path).
    def add_worktree(repo, leaf, branch: leaf)
      dest = path("wts", "proj", leaf)
      git(repo, "worktree", "add", "-q", dest, "-b", branch)
      dest
    end

    def test_perform_moves_the_dir_and_leaves_a_bridge
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      result = Rename.perform(config_for(repo), "proj", old, "new")

      assert_equal :ok, result.status
      dest = path("wts", "proj", "new")
      assert_equal dest, result.dest
      assert File.directory?(dest)
      assert File.symlink?(old), "a bridge symlink is left at the old path"
      assert_equal File.realpath(dest), File.realpath(old), "the bridge resolves to the new dir"
    end

    # The whole point of the rename surviving a restart: Claude's transcript dir,
    # keyed by the (now-changed) cwd, is carried to the new path so `/resume` finds
    # it (issue #42 follow-up).
    def test_perform_carries_the_claude_history_to_the_new_path
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      # Claude keys by the canonicalized cwd; the worktree is real here, so on macOS
      # (/var -> /private/var) the raw sandbox path and Claude's key differ — seed at
      # the realpath key the running agent actually wrote under.
      hist = File.join(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"], ClaudeHistory.encode(File.realpath(old)))
      FileUtils.mkdir_p(hist)
      File.write(File.join(hist, "s1.jsonl"), "turn\n")

      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status

      dest_hist = File.join(ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"],
                            ClaudeHistory.encode(File.realpath(path("wts", "proj", "new"))))
      assert File.exist?(File.join(dest_hist, "s1.jsonl")), "the transcript moved to the new key"
    end

    def test_perform_unknown_project_is_failed
      config = config_for(temp_git_repo("proj"))
      assert_equal :failed, Rename.perform(config, "nope", path("x"), "new").status
    end

    def test_perform_blank_name_is_invalid
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "..").status # sanitizes to ""
      assert File.directory?(old), "no move on an invalid name"
    end

    # Agents type branch-style names; a "/" the sanitizer preserves would nest the
    # dir while the session/leaf see only the basename, so rename rejects it.
    def test_perform_rejects_a_slash_in_the_name
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :invalid, Rename.perform(config_for(repo), "proj", old, "feature/auth").status
      assert File.directory?(old), "no move on a slashed name"
    end

    def test_perform_rename_to_the_same_name_is_unchanged
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      assert_equal :unchanged, Rename.perform(config_for(repo), "proj", old, "old").status
      assert File.directory?(old)
    end

    def test_perform_real_dir_collision_is_exists
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      FileUtils.mkdir_p(path("wts", "proj", "taken"))
      assert_equal :exists, Rename.perform(config_for(repo), "proj", old, "taken").status
      assert File.directory?(old), "no move onto a real dir"
    end

    # A stale rename-bridge squatting the target must not block the move.
    def test_perform_clears_a_stale_bridge_at_the_target
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      other = add_worktree(repo, "other", branch: "other")
      File.symlink(other, path("wts", "proj", "dest"))
      assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "dest").status
      assert File.directory?(path("wts", "proj", "dest"))
    end

    def test_perform_move_failure_is_failed
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Git, :move_worktree, ->(*, **) { false }) do
        assert_equal :failed, Rename.perform(config, "proj", old, "new").status
      end
    end

    def test_perform_renames_the_session_with_sanitized_leaf_names
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      seen = []
      stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(o, n) { seen << [o, n]; true }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "new").status
        end
      end
      assert_equal [["sb/proj/old", "sb/proj/new"]], seen
    end

    # Dir moved but a *reachable* session's rename failed -> :partial (recoverable;
    # prune reaps the orphan), distinct from a clean :ok.
    def test_perform_is_partial_when_a_live_session_rename_fails
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      config = config_for(repo)
      stub_method(Tmux, :has_session?, ->(_) { true }) do
        stub_method(Tmux, :rename_session, ->(*) { false }) do
          assert_equal :partial, Rename.perform(config, "proj", old, "new").status
        end
      end
      assert File.directory?(path("wts", "proj", "new")), "the dir still moved on :partial"
    end

    # No live session (clientless rename from a plain shell) is not a failure.
    def test_perform_is_ok_when_no_session_exists
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "old")
      stub_method(Tmux, :has_session?, ->(_) { false }) do
        assert_equal :ok, Rename.perform(config_for(repo), "proj", old, "new").status
      end
    end

    # A case-only rename (Old -> old) must NOT misreport as :exists/:failed. On a
    # case-insensitive FS (macOS) the two names are the same dir -> :unchanged; on a
    # case-sensitive FS they're distinct -> a real :ok move. Either is honest; the
    # regression (caught in review) was the bogus :exists the old File.exist? guard
    # produced on macOS.
    def test_perform_handles_a_case_only_rename_without_a_false_collision
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "Old")
      result = Rename.perform(config_for(repo), "proj", old, "old")
      assert_includes %i[ok unchanged], result.status,
                      "a case-only rename is not a collision or a failure"
    end

    # foo.bar and foo-bar both sanitize to the session sb/proj/foo-bar, so the dir
    # moves (dest != old_path) but the session names collapse equal — no tmux call.
    def test_perform_skips_session_rename_when_names_collapse_equal
      repo = temp_git_repo("proj")
      old = add_worktree(repo, "foo.bar")
      config = config_for(repo)
      stub_method(Tmux, :has_session?, ->(*) { flunk "no session check when names collapse" }) do
        stub_method(Tmux, :rename_session, ->(*) { flunk "no rename when names collapse" }) do
          assert_equal :ok, Rename.perform(config, "proj", old, "foo-bar").status
        end
      end
      assert File.directory?(path("wts", "proj", "foo-bar"))
    end

    # --- name suggestion (issue #84) -----------------------------------------

    def test_slugify_title_strips_the_glyph_downcases_and_caps_at_a_word_boundary
      assert_equal "fix-tmux-status-bar", Rename.slugify_title("⠐ Fix tmux status bar text truncation")
    end

    def test_slugify_title_handles_the_idle_glyph
      assert_equal "hello-world", Rename.slugify_title("✳ Hello World")
    end

    def test_slugify_title_rejects_a_slash_and_empties
      assert_nil Rename.slugify_title("feature/auth"), "a surviving slash is rejected"
      assert_nil Rename.slugify_title("⠐ "), "glyph-only -> empty -> nil"
      assert_nil Rename.slugify_title(""), "empty -> nil"
      assert_nil Rename.slugify_title(nil), "nil -> nil"
    end

    # Invalid UTF-8 (a non-UTF-8 locale's OSC title / i18n commit subject) must NOT
    # crash the regex/downcase/sanitize — it's scrubbed, the UI degrades gracefully.
    def test_slugify_title_scrubs_invalid_utf8_instead_of_raising
      bad = (+"\xFF Fix the bug").force_encoding("UTF-8")
      refute bad.valid_encoding?, "the fixture is genuinely invalid UTF-8"
      assert_equal "fix-the-bug", Rename.slugify_title(bad)
    end

    def test_slugify_title_strips_a_trailing_punctuation_dash
      assert_equal "fix-the-bug", Rename.slugify_title("Fix the bug !")
    end

    def test_slugify_title_strips_a_leading_dash_from_a_dropped_nonascii_alnum
      # "é" survives the Unicode [[:alnum:]] glyph-strip but ASCII \w in sanitize
      # drops it, leaving a leading dash that must be trimmed.
      assert_equal "thing-here", Rename.slugify_title("é-thing here")
    end

    # A Worktree for suggest() — path under wts/proj, base optional (git is stubbed).
    def wt(leaf, base: nil)
      Worktree.new(project: "proj", path: path("wts", "proj", leaf), base: base)
    end

    # Title present -> use it and SKIP the git fallback (a fallback shouldn't shell
    # `git log` on every keypress). The flunk proves the laziness.
    def test_suggest_uses_the_title_and_skips_the_lazy_git_fallback
      config = config_for(temp_git_repo("proj"))
      stub_method(Tmux, :agent_pane_title, ->(*) { "⠐ Fix the parser" }) do
        stub_method(Git, :first_commit_subject, ->(*) { flunk "git fallback must be lazy when a title exists" }) do
          assert_equal %w[fix-the-parser], Rename.suggest(config, wt("alpha"), session: "s")
        end
      end
    end

    def test_suggest_falls_back_to_git_when_no_title
      config = config_for(temp_git_repo("proj"))
      stub_method(Tmux, :agent_pane_title, ->(*) { nil }) do
        stub_method(Git, :first_commit_subject, ->(*) { "Add the parser" }) do
          assert_equal %w[add-the-parser], Rename.suggest(config, wt("alpha"), session: "s")
        end
      end
    end

    def test_suggest_drops_the_current_leaf
      config = config_for(temp_git_repo("proj"))
      stub_method(Tmux, :agent_pane_title, ->(*) { "alpha" }) do # equals the current name
        assert_empty Rename.suggest(config, wt("alpha"), session: "s")
      end
    end

    def test_suggest_drops_a_denylisted_title
      config = config_for(temp_git_repo("proj"))
      stub_method(Tmux, :agent_pane_title, ->(*) { "wip" }) do
        assert_empty Rename.suggest(config, wt("alpha"), session: "s")
      end
    end

    def test_suggest_drops_a_bare_numeric_title
      config = config_for(temp_git_repo("proj"))
      stub_method(Tmux, :agent_pane_title, ->(*) { "✳ 12345" }) do
        assert_empty Rename.suggest(config, wt("alpha"), session: "s")
      end
    end

    def test_suggest_drops_a_real_sibling_collision
      config = config_for(temp_git_repo("proj"))
      FileUtils.mkdir_p(path("wts", "proj", "taken"))
      stub_method(Tmux, :agent_pane_title, ->(*) { "taken" }) do
        assert_empty Rename.suggest(config, wt("alpha"), session: "s")
      end
    end

    # A stale rename-bridge symlink at the target is NOT a collision — perform clears
    # it — so suggest must still offer the name (mirrors perform's :exists check).
    def test_suggest_keeps_a_name_that_only_collides_with_a_bridge_symlink
      config = config_for(temp_git_repo("proj"))
      FileUtils.mkdir_p(path("wts", "proj"))
      File.symlink(path("wts", "proj", "elsewhere"), path("wts", "proj", "bridged"))
      stub_method(Tmux, :agent_pane_title, ->(*) { "bridged" }) do
        assert_equal %w[bridged], Rename.suggest(config, wt("alpha"), session: "s")
      end
    end

    def test_suggest_returns_nothing_when_disabled
      File.write(Config.path, YAML.dump("worktree_root" => path("wts"), "suggest_names" => false,
                                        "projects" => [{ "name" => "proj", "path" => temp_git_repo("proj") }]))
      config = Config.new
      stub_method(Tmux, :agent_pane_title, ->(*) { flunk "no pane read when suggestions are off" }) do
        assert_empty Rename.suggest(config, wt("alpha"), session: "s")
      end
    end
  end
end
