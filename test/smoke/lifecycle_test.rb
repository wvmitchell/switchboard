# frozen_string_literal: true

require_relative "smoke_helper"

module Switchboard
  # The real-tmux lifecycle (issue #104): boot an isolated server, attach a real client,
  # drive the actual binary, and assert against live tmux state. This is the layer the
  # stubbed unit suite structurally can't reach — pane recycling, hook firing, split/kill
  # timing. The close-pane test is the #64 regression guard (red before the fix).
  class LifecycleTest < SmokeCase
    def test_create_workspace_spawns_a_session_with_one_sidebar
      sess = create_workspace
      assert sess.start_with?("sb/proj/"), "a placeholder workspace session is created"
      refute_equal HOME, sess, "a workspace session is distinct from home"
      assert_equal 1, sidebar_pane_ids(sess).size, "the workspace window has exactly one sidebar pane"
    end

    # The client-session-changed hook pokes (C-l), it must not SPAWN — so each session
    # keeps exactly one sidebar across a switch round-trip (no duplication).
    def test_switching_sessions_keeps_a_single_sidebar_per_session
      sess = create_workspace
      switch_client(HOME)
      switch_client(sess)
      assert_equal 1, sidebar_pane_ids(HOME).size, "home keeps one sidebar across the poke"
      assert_equal 1, sidebar_pane_ids(sess).size, "the workspace keeps one sidebar (no duplication)"
    end

    # prefix-s is reconcile-across-windows (#24): dismiss clears every window's sidebar and
    # flips the flag off; summon brings them all back. Driven via the same Tmux.toggle_sidebar
    # the binding's run-shell invokes.
    def test_toggle_dismisses_and_summons_the_sidebar_across_all_windows
      sess = create_workspace
      tmux!("new-window", "-t", sess)
      wait_until("both windows have a sidebar") do
        window_ids(sess).size == 2 && windows_with_sidebar(sess).size == 2
      end

      switch_client(sess)
      Tmux.toggle_sidebar # dismiss (visible here -> off for the whole session)
      wait_until("every window's sidebar is dismissed") { windows_with_sidebar(sess).empty? }
      assert_equal "off", sidebar_flag(sess)

      Tmux.toggle_sidebar # summon (hidden -> on for every window)
      wait_until("every window gets its sidebar back") do
        windows_with_sidebar(sess).size == window_ids(sess).size && window_ids(sess).size == 2
      end
    end

    # after-new-window hook -> sidebar-sync spawns a sidebar for a new window of a session
    # that opts in.
    def test_a_new_window_gets_its_own_sidebar_via_the_after_new_window_hook
      sess = create_workspace
      before = window_ids(sess).size
      tmux!("new-window", "-t", sess)
      wait_until("the new window gets a sidebar") do
        window_ids(sess).size == before + 1 && windows_with_sidebar(sess).size == before + 1
      end
    end

    # #64 REGRESSION GUARD: close the work pane and the sidebar must NOT wedge the window
    # full-width. From a workspace it falls home and exits, so the window (and its now-lone
    # session) closes and the client lands on home. Red against the pre-fix sidebar.
    def test_closing_a_workspace_work_pane_falls_home_instead_of_wedging
      sess = create_workspace # client is now on sess
      tmux!("kill-pane", "-t", work_pane_id(sess))
      wait_until("the wedged window/session is gone and we're back home") do
        !session?(sess) && client_session == HOME
      end
    end

    # #64 home special-case (D6): home is the anchor, so closing its work pane self-heals in
    # place (a fresh work shell beside the tree) rather than exiting (which would kill the
    # anchor) or wedging full-width. Home survives with two panes again.
    def test_closing_the_home_work_pane_self_heals_and_keeps_home_alive
      assert_equal 2, active_window_pane_count(HOME), "home starts as work pane + sidebar"
      tmux!("kill-pane", "-t", work_pane_id(HOME))
      wait_until("home re-grows a work pane, never wedges, and survives") do
        session?(HOME) && active_window_pane_count(HOME) == 2 && sidebar_pane_ids(HOME).size == 1
      end
    end

    # rename lifecycle (#94): dir move + branch + tmux session rename, in place.
    def test_renaming_a_workspace_moves_its_dir_and_session
      sess = create_workspace
      leaf = sess.split("/").last
      newname = "renamed"
      system(BIN, "rename", newname, chdir: worktree_path(leaf), out: File::NULL, err: File::NULL)
      wait_until("the renamed session exists and the old one is gone") do
        session?("sb/proj/#{newname}") && !session?(sess)
      end
      assert Dir.exist?(worktree_path(newname)), "the worktree dir moved to the new name"
    end

    # prune lifecycle: a worktree removed out from under its session leaves an orphan that
    # prune reconciles away (vs the live git worktrees).
    def test_prune_kills_a_session_orphaned_by_a_removed_worktree
      sess = create_workspace
      leaf = sess.split("/").last
      system("git", "-C", @project, "worktree", "remove", "--force", worktree_path(leaf),
             out: File::NULL, err: File::NULL)
      # prune deliberately spares a session younger than SESSION_GRACE (the launch-race
      # guard), so age the orphan past it — a deterministic wait, not a flake.
      sleep Reconcile::SESSION_GRACE + 1
      assert_isolated_socket!
      # prune reaps sidebar PROCESSES with a machine-global `ps`; without the isolated-server
      # guard it would SIGTERM the developer's REAL sidebar (its tty isn't a pane on this
      # throwaway server). The flag MUST be live before we drive prune — see SmokeCase#setup.
      assert_equal "1", ENV["SWITCHBOARD_SANDBOX"],
                   "prune must run under the isolated-server guard, else it kills the dev's real sidebar"
      run_bin("prune")
      wait_until("the orphaned session is reconciled away") { !session?(sess) }
    end

    # `e` reuse (issue: repeated `e` stacked a new editor pane each press). The idempotence
    # lives in stash_editor_pane + live_editor_pane on the home session; exercise THAT against
    # real tmux with a stand-in pane. We don't drive the full `e`/edit_in_home flow here: it
    # resolves ${VISUAL:-${EDITOR:-vi}} in the pane's shell (the CI runner has no editor/vi, so
    # the command exits and the pane closes) and its switch() would exec over the test process.
    # The pure key→pane gate is covered by tmux_test's reusable_editor_pane; this is the live
    # half — show-options/list-panes/#{pane_dead} — which is what varies across tmux builds.
    def test_live_editor_pane_reuses_a_live_stashed_pane_and_drops_it_once_closed
      editor = tmux("split-window", "-t", HOME, "-d", "-P", "-F", fmt("pane_id"), "sleep 100000").strip
      refute editor.empty?, "spawned a stand-in editor pane in home"
      Tmux.stash_editor_pane(editor)
      assert_equal editor, Tmux.live_editor_pane, "the stashed, still-live pane is the one `e` reuses"

      tmux!("kill-pane", "-t", editor) # the :q that closes the editor
      wait_until("the editor pane is gone") { !active_window_pane_ids(HOME).include?(editor) }
      assert_nil Tmux.live_editor_pane, "a closed editor pane is dropped, so the next `e` spawns fresh"
    end

    # remain-on-exit keeps a :q'd editor as a DEAD pane list-panes still reports; the gate must
    # filter it (#{pane_dead}) or `e` would re-focus the corpse forever instead of reopening.
    def test_live_editor_pane_ignores_a_dead_editor_pane_under_remain_on_exit
      tmux!("set-option", "-t", HOME, "remain-on-exit", "on")
      editor = tmux("split-window", "-t", HOME, "-d", "-P", "-F", fmt("pane_id"), "true").strip # exits at once
      refute editor.empty?, "spawned a stand-in editor pane in home"
      Tmux.stash_editor_pane(editor)
      wait_until("the pane exits and goes dead but stays listed") do
        active_window_pane_ids(HOME).include?(editor) && pane_dead?(editor)
      end
      assert_nil Tmux.live_editor_pane, "a dead editor pane is filtered, not reused"
    end

    # quit: full teardown — every sb/ session gone (current one last), agent state cleared.
    def test_quit_tears_down_every_sb_session
      create_workspace
      refute_empty sb_sessions, "precondition: switchboard sessions exist"
      assert_isolated_socket!
      run_bin("quit")
      wait_until("every sb/ session is torn down") { sb_sessions.empty? }
      assert_empty Dir.glob(File.join(ENV["SWITCHBOARD_STATE_DIR"], "*")), "agent state is cleared"
    end
  end
end
