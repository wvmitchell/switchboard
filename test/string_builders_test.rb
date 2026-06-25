# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Pure string builders — no shell-out, no state. These pin the invariants that
  # quietly break things when they regress: a name that escapes the worktree
  # root, a session name tmux rejects, a PR badge with the wrong color.
  #
  # (More builders — name_from_url, session_name, home_dir, repo_slug, View
  # badges — land here in T7; this file starts with the sanitize security guard.)
  class StringBuildersTest < Minitest::Test
    # Creator.sanitize is the gate on a user-supplied workspace name before it
    # becomes both a directory under worktree_root and a git branch. The bug it
    # closes: the old char class kept "." and "/", so "../../x" survived and
    # File.join walked out of the root. The invariant now: the result never
    # contains a "." / ".." / empty segment, so it can't climb out.
    def test_sanitize_leaves_a_plain_name_untouched
      assert_equal "feature-login", Creator.sanitize("feature-login")
    end

    def test_sanitize_turns_spaces_into_dashes
      assert_equal "my-new-thing", Creator.sanitize("my  new\tthing")
    end

    def test_sanitize_drops_exotic_characters
      assert_equal "ab", Creator.sanitize("a$b!")
    end

    def test_sanitize_keeps_dots_inside_a_segment
      # version-ish names are fine; only "." / ".." *segments* are traversal.
      assert_equal "v1.2.0-fix", Creator.sanitize("v1.2.0-fix")
    end

    def test_sanitize_preserves_a_legit_nested_name
      assert_equal "feature/login", Creator.sanitize("feature/login")
    end

    # --- traversal guard (the bug) -------------------------------------------

    def test_sanitize_strips_parent_traversal
      assert_equal "etc/passwd", Creator.sanitize("../../etc/passwd")
    end

    def test_sanitize_strips_a_leading_absolute_slash
      assert_equal "tmp/x", Creator.sanitize("/tmp/x")
    end

    def test_sanitize_strips_interior_dot_dot
      assert_equal "a-b/x", Creator.sanitize("a b/../x")
    end

    def test_sanitize_drops_a_lone_dot_to_empty
      assert_equal "", Creator.sanitize(".")
    end

    def test_sanitize_drops_dot_dot_to_empty
      assert_equal "", Creator.sanitize("..")
    end

    def test_sanitize_collapses_a_traversal_only_name_to_empty
      # create() rejects an empty result as "invalid workspace name".
      assert_equal "", Creator.sanitize("../../..")
    end

    def test_sanitize_result_never_escapes_worktree_root
      # Property: for any input, File.join(root, project, sanitized) stays under
      # root — i.e. the expanded path is a descendant of root/project.
      root = "/work/root/proj"
      ["../../etc", "/etc", "a/../../b", "....//..", "x/./y"].each do |bad|
        name = Creator.sanitize(bad)
        next if name.empty?

        dest = File.expand_path(File.join(root, name))
        assert dest.start_with?("#{root}/"), "#{bad.inspect} -> #{name.inspect} escaped to #{dest}"
      end
    end

    # --- Registrar.name_from_url --------------------------------------------

    def test_name_from_url_handles_ssh_https_and_suffixes
      assert_equal "repo", Registrar.name_from_url("git@github.com:org/repo.git")
      assert_equal "repo", Registrar.name_from_url("https://github.com/org/repo.git")
      assert_equal "repo", Registrar.name_from_url("https://github.com/org/repo")
      assert_equal "repo", Registrar.name_from_url("https://github.com/org/repo/")
      assert_equal "repo", Registrar.name_from_url("/local/path/repo")
    end

    def test_name_from_url_blank_is_empty
      assert_equal "", Registrar.name_from_url("")
    end

    # --- Tmux.session_name (tmux forbids . : and whitespace) -----------------

    def test_session_name_sanitizes_dots_colons_and_spaces
      wt = Worktree.new(project: "my.proj", path: "/a/b/feat x", branch: nil,
                        dirty: false, pr: nil, base: nil, primary: false)
      assert_equal "sb/my-proj/feat-x", Tmux.session_name(wt)
    end

    # --- Tmux.home_dir (the persistent home session lives in $HOME) ----------

    def test_home_dir_uses_HOME
      with_env("HOME" => "/custom/home") { assert_equal "/custom/home", Tmux.home_dir }
    end

    def test_home_dir_falls_back_to_cwd_when_HOME_unset
      with_env("HOME" => nil) { assert_equal Dir.pwd, Tmux.home_dir }
    end

    # --- Tmux.sidebar_flag_on? (@sb_sidebar decision; unset reads as on) ------

    def test_sidebar_flag_on_only_explicit_off_hides
      assert Tmux.sidebar_flag_on?(""),    "unset (no flag) shows — preserves auto-show"
      assert Tmux.sidebar_flag_on?("on"),  "explicit on shows"
      refute Tmux.sidebar_flag_on?("off"), "explicit off is the only hide"
    end

    # --- View PR-badge helpers (all that survived the picker removal) --------

    def test_pr_identifier_handles_missing_and_non_hash
      assert_equal "#5", View.pr_identifier("identifier" => "#5")
      assert_equal "#?", View.pr_identifier({})   # present-but-empty -> placeholder
      assert_equal "", View.pr_identifier(nil)    # corrupt cache row -> "" (no raise)
    end

    def test_pr_state_maps_status_and_draft
      assert_equal "OPEN", View.pr_state("status" => "open")
      assert_equal "MERGED", View.pr_state("status" => "merged")
      assert_equal "DRAFT", View.pr_state("status" => "open", "is_draft" => 1)
    end

    def test_pr_tag_colors_by_state_and_is_empty_without_a_pr
      assert_equal "", View.pr_tag(nil)
      open_tag = View.pr_tag("identifier" => "#5", "status" => "open")
      assert_includes open_tag, "#5"
      assert_includes open_tag, "\e[32m" # OPEN -> green
      draft_tag = View.pr_tag("identifier" => "#6", "status" => "open", "is_draft" => 1)
      assert_includes draft_tag, "\e[33m" # DRAFT -> yellow
    end

    # --- View diff-count badge (issue #79) -----------------------------------

    def test_diff_label_formats_and_hides_zero
      assert_equal "+22 −333", View.diff_label([22, 333])
      assert_equal "+5", View.diff_label([5, 0])      # one-sided
      assert_equal "−9", View.diff_label([0, 9])
      assert_equal "", View.diff_label([0, 0])        # clean branch -> nothing
      assert_equal "", View.diff_label(nil)           # no count yet -> nothing
      assert_equal "", View.diff_label("garbage")     # corrupt entry -> no raise
    end

    def test_diff_label_abbreviates_large_counts
      assert_equal "+999", View.diff_label([999, 0])
      assert_equal "+1k", View.diff_label([1000, 0])    # 1.0k collapses to 1k
      assert_equal "+1.5k", View.diff_label([1500, 0])
      assert_equal "+12k −68k", View.diff_label([12_345, 67_890])
    end

    def test_diff_tag_colors_additions_green_and_deletions_red
      tag = View.diff_tag([22, 333])
      assert_includes tag, "\e[32m+22\e[0m"   # additions green
      assert_includes tag, "\e[31m−333\e[0m"  # deletions red
      assert_equal "", View.diff_tag([0, 0])  # nothing to color when clean
      assert_equal "", View.diff_tag(nil)
    end

    # --- Editor.command ($VISUAL > $EDITOR > vi; empty is unset) -------------

    def test_editor_command_prefers_visual_then_editor
      with_env("VISUAL" => "code -w", "EDITOR" => "nano") { assert_equal "code -w", Editor.command }
      with_env("VISUAL" => nil, "EDITOR" => "nano") { assert_equal "nano", Editor.command }
    end

    def test_editor_command_treats_empty_as_unset_and_falls_back_to_vi
      # "" is truthy in Ruby; a bare || chain would pick it and try to exec the
      # config file. The empty VISUAL must fall through to EDITOR, both-empty to vi.
      with_env("VISUAL" => "", "EDITOR" => "nano") { assert_equal "nano", Editor.command }
      with_env("VISUAL" => "", "EDITOR" => "") { assert_equal "vi", Editor.command }
      with_env("VISUAL" => nil, "EDITOR" => nil) { assert_equal "vi", Editor.command }
    end

    # SHELL_COMMAND mirrors #command's precedence (VISUAL > EDITOR > vi) and its
    # empty-is-unset rule (shell `:-`), but defers resolution to the spawned shell
    # — so the sidebar's `e` editor pane sees an EDITOR set after the long-lived
    # sidebar process started. Pinned so the two resolutions can't drift.
    def test_editor_shell_command_defers_resolution_to_the_shell
      assert_equal "${VISUAL:-${EDITOR:-vi}}", Editor::SHELL_COMMAND
    end

    private

    # Set/clear env vars for the block, restoring prior values after.
    def with_env(vars)
      old = vars.to_h { |k, _| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      old.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    end
  end
end
