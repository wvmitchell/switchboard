# frozen_string_literal: true

require "rbconfig"
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
      sess = create_workspace(enter: true) # client is now on sess
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
    # The session and sidebar appear while the background build is still running, and
    # rename refuses (:building) until the agent has started. A slow setup script holds
    # that window open on purpose, so the test always crosses it: re-issue the rename
    # until it's accepted (a refusal moves nothing), as switch_client does for switches.
    def test_renaming_a_workspace_moves_its_dir_and_session
      File.open(ENV["SWITCHBOARD_CONFIG"], "a") { |f| f.puts "worktree_creation_command: sleep 2" }
      sess = create_workspace
      leaf = sess.split("/").last
      newname = "renamed"
      said = nil
      wait_until("the build lets the rename through") do
        said = IO.popen([BIN, "rename", newname, { chdir: worktree_path(leaf), err: %i[child out] }], &:read)
        !said.include?("still being created")
      end
      wait_until("the renamed session exists and the old one is gone (rename said: #{said.strip})") do
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
      Editor.stash_editor_pane(editor)
      assert_equal editor, Editor.live_editor_pane, "the stashed, still-live pane is the one `e` reuses"

      tmux!("kill-pane", "-t", editor) # the :q that closes the editor
      wait_until("the editor pane is gone") { !active_window_pane_ids(HOME).include?(editor) }
      assert_nil Editor.live_editor_pane, "a closed editor pane is dropped, so the next `e` spawns fresh"
    end

    # remain-on-exit keeps a :q'd editor as a DEAD pane list-panes still reports; the gate must
    # filter it (#{pane_dead}) or `e` would re-focus the corpse forever instead of reopening.
    def test_live_editor_pane_ignores_a_dead_editor_pane_under_remain_on_exit
      tmux!("set-option", "-t", HOME, "remain-on-exit", "on")
      editor = tmux("split-window", "-t", HOME, "-d", "-P", "-F", fmt("pane_id"), "true").strip # exits at once
      refute editor.empty?, "spawned a stand-in editor pane in home"
      Editor.stash_editor_pane(editor)
      wait_until("the pane exits and goes dead but stays listed") do
        active_window_pane_ids(HOME).include?(editor) && pane_dead?(editor)
      end
      assert_nil Editor.live_editor_pane, "a dead editor pane is filtered, not reused"
    end

    # The delete-hang fix end-to-end: deleting the workspace you're IN hands the slow
    # `git worktree remove` to a DETACHED daemon that must outlive the session kill
    # (Process.daemon / setsid, immune to the pane-teardown SIGHUP) and then falls home.
    # Offline stubs can't reach this — it's real processes + a real session kill. The
    # assertion is end-state (worktree + branch gone, we're home), never a wall-clock
    # bound. Sending `d` then `y` drives the real sidebar confirm (a clean placeholder
    # needs no force prompt); `g` `j` first land the cursor on the workspace row.
    def test_deleting_the_current_workspace_falls_home_and_the_daemon_removes_it
      sess = create_workspace(enter: true) # client is now on sess (a clean placeholder)
      leaf = sess.split("/").last
      wt = worktree_path(leaf)
      pane = sidebar_pane_ids(sess).first or flunk "no sidebar in the workspace to drive"
      # Both the branch it started on and a later, unmerged one go with it.
      started_on = Git.current_branch(wt)
      assert system("git", "-C", wt, "checkout", "-q", "-b", "later-unmerged"), "moved to a second branch"
      assert system("git", "-C", wt, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "ahead"),
             "put work on it"

      open_delete_prompt(pane, leaf)
      # A broadcast landing on the open prompt isn't its answer: it used to read as "no",
      # the prompt vanished, and this `y` hit the tree. The delete below is the proof.
      tmux!("send-keys", "-t", pane, Tmux::WARM_POKE)
      tmux!("send-keys", "-t", pane, "y") # confirm (clean placeholder ⇒ no force prompt)

      wait_until("we fall home and the workspace session is gone") do
        !session?(sess) && client_session == HOME
      end
      wait_until("the detached daemon finishes the removal (it survived the session kill)") do
        !Dir.exist?(wt) && Git.worktrees(@project).none? { |w| w[:path] == wt }
      end
      refute session?(sess), "the deleted workspace's session is gone"
      assert_equal HOME, client_session, "and we've fallen back to home"
      refute Dir.exist?(wt), "the daemon removed the worktree dir off-loop"
      wait_until("the daemon deletes the workspace's branches") do
        [started_on, "later-unmerged"].none? { |b| Git.rev_parse(@project, "refs/heads/#{b}") }
      end
    end

    # Value: protects=a delete prompt survives switching away and back with its answer
    # intact; fails_when=a real switch poke or focus report closes or answers the prompt;
    # why_new=the delete test above only sends a synthetic C-w while staying put; seam=none;
    # no_claim=focus reports (only the C-l was seen here), or a poke later than the watch window
    def test_a_delete_prompt_survives_switching_away_and_back
      sess = create_workspace(enter: true)
      leaf = sess.split("/").last
      wt = worktree_path(leaf)
      pane = sidebar_pane_ids(sess).first or flunk "no sidebar in the workspace to drive"
      open_delete_prompt(pane, leaf)

      switch_client(HOME)
      switch_client(sess)
      # The return poke lands about 100ms after the switch, invisibly, so sending `y` at once
      # beats it and proves nothing. Watch the prompt through that window instead. A slower
      # poke can only make this pass without testing it, never fail spuriously.
      deadline = monotonic + 1.5
      while monotonic < deadline
        assert_includes capture(pane), "delete #{leaf}?", "the prompt is still up after the round trip"
        sleep 0.05
      end
      tmux!("send-keys", "-t", pane, "y")

      wait_until("the session is gone") { !session?(sess) }
      wait_until("the worktree is gone") do
        !Dir.exist?(wt) && Git.worktrees(@project).none? { |w| w[:path] == wt }
      end
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

    # Value: protects=quit killing what it says it killed when switchboard runs under a C locale,
    # as a tmux pane without LANG does; fails_when=a tmux read loses -u, so tmux prints the format's
    # tab as "_" and the session name misparses (#92); why_new=the smoke layer only ran under the
    # developer's own locale; also fails_when=bin/switchboard stops forcing UTF-8, since -u now hands a
    # C-locale Ruby raw non-English bytes it would raise on, and the name test below sets that itself;
    # seam=none; no_claim=other locales' spellings of "not UTF-8"
    def test_quit_under_a_c_locale_kills_the_sb_sessions_and_spares_the_rest
      create_workspace
      tmux!("new-session", "-d", "-s", "mine")
      tmux!("new-session", "-d", "-s", "sb/é/x")
      refute_empty sb_sessions, "precondition: switchboard sessions exist"
      assert_isolated_socket!
      c_locale { run_bin("quit") }
      wait_until("every sb/ session is torn down") { sb_sessions.empty? }
      assert_includes tmux("list-sessions", "-F", '#{session_name}'), "mine", "quit only touches sb/ sessions"
    end

    # Value: protects=a non-English session name surviving the read under a C locale; fails_when=
    # Tmux.sessions loses -u, so tmux prints "é" as "_" and the name matches nothing; why_new=the
    # quit test above uses ASCII names; seam=none; no_claim=how a terminal renders the name
    def test_session_names_keep_their_characters_under_a_c_locale
      create_workspace
      tmux!("new-session", "-d", "-s", "sb/é/x")
      assert_isolated_socket!
      probe = 'Encoding.default_external = Encoding::UTF_8; require "switchboard"; puts Switchboard::Tmux.sessions.map { |s| s[:name] }'
      lib = File.join(REPO, "lib")
      names = c_locale { IO.popen([RbConfig.ruby, "-I#{lib}", "-e", probe], err: File::NULL, &:read) }.force_encoding("UTF-8")
      assert_includes names.lines.map(&:chomp), "sb/é/x"
    end

    # The whole key loop through a real PTY: nothing is hidden, n/N step, and Esc is what gives
    # n back. The bytes tmux actually delivers are what the stubbed suite can not reach.
    def test_search_highlights_steps_and_only_esc_gives_n_back
      2.times { create_workspace }
      pane = sidebar_pane_ids(HOME).first
      rows = capture(pane).lines.count { |l| l.include?("-") }

      tmux!("send-keys", "-t", pane, "/")
      tmux!("send-keys", "-t", pane, "-l", "-")
      wait_until("the live count") { capture(pane).include?("/- [1/2]") }
      tmux!("send-keys", "-t", pane, "Enter")
      wait_until("the committed footer") { capture(pane).include?("[1/2] · n/N") }
      assert_equal rows, capture(pane).lines.count { |l| l.include?("-") } - 1, "no row hidden (the footer adds a line with a -)"

      tmux!("send-keys", "-t", pane, "n")
      wait_until("n stepped") { capture(pane).include?("[2/2]") }
      tmux!("send-keys", "-t", pane, "N")
      wait_until("N stepped back") { capture(pane).include?("[1/2]") }
      tmux!("send-keys", "-t", pane, "j")
      wait_until("j moves, the search stays on") { capture(pane).include?("[2/2]") || capture(pane).include?("[-/2]") }
      assert_match(/\e\[(?:30;43|30m\e\[43)m-/, tmux("capture-pane", "-e", "-p", "-t", pane), "the match wears the search style")

      dispatched = Creation.all.size
      tmux!("send-keys", "-t", pane, "Escape")
      wait_until("Esc ended the search") { !capture(pane).include?("n/N") }
      tmux!("send-keys", "-t", pane, "n")
      wait_until("n is new workspace again") { capture(pane).include?("task ›") }
      tmux!("send-keys", "-t", pane, "Escape")
      wait_until("the prompt closed") { !capture(pane).include?("task ›") }
      assert_equal dispatched, Creation.all.size, "nothing was created along the way"
    end

    private

    def open_delete_prompt(pane, leaf)
      # Re-drive `g` `j` `d` until the DELETE prompt is up, as switch_client re-issues its
      # switch. One shot can lose to the background build (CI flake on #30): until the
      # sidebar reloads past it, the row can still be the synthetic dispatch row, where `d`
      # asks "cancel …?", or the keys can land before the tree is drawn (cursor on the
      # header, "remove …?"). A re-drive's first key answers any wrong prompt no (anything
      # but `y` is no), so nothing is canceled or removed.
      # Wait for the prompt before sending `y`: if `d` and `y` land in one read they
      # tokenize together and confirm's read_char blocks after `d`, never seeing the
      # buffered `y`. Waiting for [y/N] guarantees read_char is blocking on a fresh read.
      screen = ""
      driven = nil
      wait_until(-> { "the delete confirm prompt is up; the sidebar last showed:\n#{screen}" }) do
        screen = tmux("capture-pane", "-p", "-t", pane)
        next true if screen.include?("delete #{leaf}?")

        if driven.nil? || monotonic - driven > 1
          %w[g j d].each { |k| tmux!("send-keys", "-t", pane, k) } # top (proj header) → the ws row → delete
          driven = monotonic
        end
        false
      end
    end

    def c_locale
      saved = ENV.values_at("LC_ALL", "LANG")
      ENV["LC_ALL"] = ENV["LANG"] = "C"
      yield
    ensure
      ENV["LC_ALL"], ENV["LANG"] = saved
    end
  end
end
