# frozen_string_literal: true

require "shellwords"

module Switchboard
  class Sidebar
    # Actions (#57): the verbs a keypress fires — create/add/clone, delete and
    # remove-project, rename, open PR/repo, the config editor round-trip, the
    # three shared-view-state toggles, the R badge refresh, switch, and quit.
    # A concern module on Sidebar (see CLAUDE.md conventions); the bottom-row
    # prompts these verbs lean on live in Prompt.
    module Actions
      # `gh browse` sub-args for a row, or nil if it has no openable path. Deep-link the
      # repo AT the row's branch (--branch) only when the row has an OPEN PR: GitHub
      # closes a PR the instant its head branch is deleted, so an open (or draft —
      # status is still "OPEN") PR guarantees the branch is on the remote and
      # /tree/<branch> resolves rather than 404s. A merged/closed PR keeps its badge
      # (Pr.fetch lists --state all) after the branch is gone, so it is NOT a deep-link
      # signal. No open PR — and the project header, which has neither pr nor branch —
      # opens the repo home / default branch. node.pr is already loaded for the badge,
      # so this costs no extra I/O; an open PR also implies a valid pushed branch name,
      # so no dash-led guard is needed.
      def self.browse_args(node)
        return nil unless node && node.path

        args = ["browse"]
        branch = node.branch.to_s
        args += ["--branch", branch] if node.pr.is_a?(Hash) && node.pr["status"].to_s.upcase == "OPEN" && !branch.empty?
        args
      end

      private

      # T4 — manual (R): force a refresh of every registered project's badges,
      # bypassing the staleness gates the automatic triggers use. A PR merged or
      # closed on GitHub fires no local signal, so this is the "I just did that, show
      # it now" escape hatch; the detached children poke us to redraw as gh returns.
      # Still debounced per project (maybe_refresh_prs), so a mashed R can't storm gh.
      # No wrapper (SWITCHBOARD_BIN unset) ⇒ maybe_refresh_prs can't spawn, so bail
      # before the notify rather than claim a refresh that can't happen. (A refresh
      # already in flight from a prior press still notifies — it's honest, one's running.)
      def refresh_prs_now
        # Diff counts are local, so heal them here too (R is the manual "show it now"
        # for the merged/base-moved staleness the mtime gate can't see) — independent
        # of the wrapper the PR refresh needs. Clear + recompute against the cached tree.
        @diffs.clear
        refresh_diffs
        return unless ENV["SWITCHBOARD_BIN"]

        @config.projects.map { |p| p["name"] }.each { |name| maybe_refresh_prs(name) }
        Tmux.notify("switchboard: refreshing #{@config.diff_counts? ? 'PRs + diffs' : 'PRs'}…")
      rescue StandardError
        nil
      end

      # q: full teardown — kill every sb/ session (Tmux.kill_all), our own last so
      # the sweep finishes before this process dies with it. Guarded by a y/N
      # confirm because q meant "hide" until recently — an unconfirmed q just stays
      # in the loop (returns true). Confirmed, we return false too, so a no-server
      # quit (nothing to kill) still drops out cleanly.
      def quit
        return true unless confirm("quit all switchboard sessions?")

        AgentState.clear_all # killing every agent makes their last hook state stale — drop it now
        Monitoring.clear_all # ...and every monitoring declaration is now stale too
        Notify.clear_all     # ...and any pending "come look" alert is moot once the agents are gone
        Tmux.kill_all
        false
      end

      # Flip a project's fold, writing through to the shared store so every other
      # window's sidebar picks it up on its next reload (a switch-in poke, or a
      # while-visible scan). The in-memory set is updated too for same-frame feedback.
      def toggle_collapse(project)
        if @collapsed.include?(project)
          @collapsed.delete(project)
          Collapse.expand(project)
        else
          @collapsed.add(project)
          Collapse.collapse(project)
        end
        recompute_rows
        Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # other sidebars repaint the fold now (no switch-in flash)
      end

      # H: flip the full header on/off for EVERY session. Like the project fold it
      # writes through to the shared store (FullHeader), so every other window's
      # sidebar picks it up on its next reload (a switch-in poke or a while-visible
      # scan); the in-memory flag flips too for same-frame feedback in this pane (the
      # next render reads it). No recompute — only the header lines change, not @rows.
      def toggle_full_header
        @full_header = !@full_header
        @full_header ? FullHeader.enable : FullHeader.disable
        Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # other sidebars repaint the header now
      end

      # z: fold/unfold EVERY workspace's branch-history rows tree-wide (issue #107).
      # Global, regardless of the cursor. Like the project fold and the full-header
      # toggle it writes through to the shared store (BranchFold) so every other
      # window's sidebar picks it up on its next reload, and flips the in-memory flag
      # for same-frame feedback. Unlike those it DOES recompute_rows — folding changes
      # which rows are visible. The cursor then re-anchors to the row it was on by path:
      # folding from a branch row lands you on that workspace's row (the branch rows it
      # shared a path with are gone), so `z` doesn't jump you somewhere unrelated.
      def toggle_branch_fold
        here = current&.path
        @fold_branches = !@fold_branches
        @fold_branches ? BranchFold.fold : BranchFold.unfold
        recompute_rows
        i = @rows.index { |n| n.path == here } if here
        @cursor = i if i
        Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # other sidebars repaint the fold now
      end

      def switch(node)
        Tmux.go(Worktree.new(project: node.project, path: node.path, branch: node.branch,
                             dirty: false, pr: node.pr, base: nil, primary: false),
                start: @config.session_command_for(node.project))
      end

      # Fire-and-forget a `gh` command that may hit the network, off the paint loop.
      # Detached, not `system`: gh resolves the PR/repo against the API before opening
      # the browser, so a slow network would otherwise freeze the loop. spawn raises
      # (unlike system) if the dir or `gh` is missing, so swallow that to keep the UI
      # alive — nothing opens on failure. Shared by open_pr and open_repo.
      def spawn_gh(*args, chdir:)
        Process.detach(Process.spawn("gh", *args, chdir: chdir, out: File::NULL, err: File::NULL))
      rescue SystemCallError
        nil
      end

      # o: open the highlighted workspace/branch's PR in the browser. Runs in the
      # worktree dir so `gh` infers the repo. No PR for the branch ⇒ gh exits quietly
      # and nothing opens.
      def open_pr
        node = current
        return unless node && node.kind != "proj"

        branch = node.branch.to_s
        return if branch.empty? || branch.start_with?("-") # never hand a dash-led name to gh as a flag

        spawn_gh("pr", "view", branch, "--web", chdir: node.path)
      end

      # O: open the highlighted row's repo in the browser (sibling to o/PR). Unlike o
      # this rides every kind — every worktree resolves to the same repo — so it works
      # on the project header too. browse_args picks repo-home vs the row's branch.
      def open_repo
        node = current
        args = Actions.browse_args(node)
        return unless args

        spawn_gh(*args, chdir: node.path)
      end

      # Create the worktree (quiet) and drop into it — no name prompt. `n` (and
      # filter-mode ↵-on-a-project, which passes that header in) always auto-names:
      # `Creator.create` with a blank name cuts a placeholder adjective-noun dir +
      # branch you start working in immediately, then rename once you know the work via
      # `r` / `switchboard rename` / the agent nudge (#114 — doubling down on the
      # deferred-naming #94 and agent self-naming #92). Defaults to the highlighted row.
      def create(node = current)
        return unless node

        rows, = winsize
        print "\e[#{rows};1H\e[K\e[?25lcreating…"
        $stdout.flush
        dest = Creator.create(@config, node.project, "")

        if dest
          Tmux.go(Worktree.new(project: node.project, path: dest, branch: nil,
                               dirty: false, pr: nil, base: nil, primary: false),
                  start: @config.session_command_for(node.project))
        end
        reload
      end

      # a: register a new project. n only makes worktrees *inside* a project, so
      # this is the keyboard path to the first project — switchboard can now stand
      # up from an empty sidebar with no CLI round-trip. Two modes: point at a repo
      # already on disk, or clone one from a URL.
      def add
        rows, cols = winsize
        print "\e[#{rows};1H\e[K\e[?25h#{trunc('add — [l] local repo · [c] clone url', cols)}"
        $stdout.flush
        choice = read_char
        print "\e[?25l"
        case choice&.downcase
        when "l" then add_local
        when "c" then add_clone
        else reload
        end
      end

      # Register an existing local repo by path. Name derives from its basename.
      def add_local
        path = prompt_line("path to an existing git repo")
        return reload if blank_input?(path)

        _, err = Registrar.register(@config, path)
        flash(err) if err
        reload_config
        reload
        # Every other window's sidebar caches its own @config; poke them to re-read
        # so the new project shows there too (their rebuild's refresh_config picks it
        # up), instead of only appearing after a sidebar respawn.
        Tmux.broadcast_warm(except: ENV["TMUX_PANE"])
      end

      # Clone a URL under projects_root, then register it. The clone blocks the
      # paint loop (like delete/rename do) — fine, it's a deliberate action.
      def add_clone
        url = prompt_line("git URL to clone")
        return reload if blank_input?(url)

        rows, cols = winsize
        print "\e[#{rows};1H\e[K#{trunc("cloning #{url}…", cols)}"
        $stdout.flush
        _, err = Registrar.clone(@config, url)
        flash(err) if err
        reload_config
        reload
        Tmux.broadcast_warm(except: ENV["TMUX_PANE"]) # peer sidebars re-read the grown config (see add_local)
      end

      # Re-read config from disk so a freshly added project shows on the next
      # rebuild (@config is otherwise cached for the session). Config.new no longer
      # raises on malformed YAML (it degrades to empty + records load_error), so keep
      # the last good @config on a parse error and return the error for the caller to
      # surface; nil on a clean reload. Stamp the file's mtime we're reading so the
      # mtime-gated refresh_config (in rebuild) doesn't immediately re-parse the same
      # file — the explicit force-read and the lazy change-gate share one baseline.
      def reload_config
        @config_mtime = config_mtime
        fresh = Config.new
        @config = fresh unless fresh.load_error
        fresh.load_error
      end

      # Re-read config from disk when the file changed since we last read it — so a
      # project added/removed in ANOTHER session (or a hand-edit outside the `e`
      # editor) lands on this sidebar's next reload/warm, not only when its process is
      # respawned (the cross-session "new project doesn't show" gap). Called from
      # rebuild, the one chokepoint every reload path funnels through (switch-in poke,
      # the ~15s tree-tick, the off-screen warm). mtime-gated: an unchanged config
      # costs a single stat, never a YAML parse, so the frequent C-l reload stays as
      # cheap as it was when it never re-read config at all. Adopts the new @config
      # only on a clean parse (keeps the last good one on a syntax slip, like
      # reload_config); the mtime is stamped either way so a known-broken file isn't
      # re-parsed every rebuild until it changes again.
      def refresh_config
        mtime = config_mtime
        return if mtime == @config_mtime

        @config_mtime = mtime
        fresh = Config.new
        @config = fresh unless fresh.load_error
      end

      # mtime of the config file (nil when there's none yet) — the change signal
      # shared by refresh_config's gate and warm_fingerprint's config entry.
      def config_mtime
        File.mtime(Config.path).to_f
      rescue SystemCallError
        nil
      end

      # e: edit config.yml in its own pane beside the home sidebar, then return to
      # wherever we are now. Scaffold first so there's always a real file to edit.
      # The editor owns its OWN throwaway pane (not this narrow strip, not the
      # shared home shell), so there's no raw-mode dance and we just stay a live
      # tree. The editor is left UNescaped (Editor::SHELL_COMMAND) so the spawned
      # shell expands $EDITOR at run time, not this sidebar process. The trailer —
      # run in that pane after :q — switches the client back to this session and
      # pokes its sidebar to re-read config (Ctrl-R), so a changed session_command /
      # new project shows the moment you quit.
      def edit_config
        Config.scaffold
        bin    = Shellwords.escape(ENV["SWITCHBOARD_BIN"] || "switchboard")
        path   = Shellwords.escape(Config.path)
        origin = Shellwords.escape(Tmux.session_of.to_s) # the session `e` was pressed from
        Tmux.edit_in_home("#{Editor::SHELL_COMMAND} #{path}; #{bin} reload-config #{origin}")
      end

      # Re-read the (possibly hand-edited) config and rebuild — driven by the
      # dedicated post-edit poke (Ctrl-R) after `e`'s editor exits. Guard the parse:
      # the whole point of `e` is editing raw YAML, so a syntax slip is expected.
      # reload_config keeps the last good @config on a parse error and hands back the
      # message; surface it on tmux's status line — visible even when focus isn't on
      # the tree — rather than tear the sidebar down.
      def reload_config_and_rebuild
        if (err = reload_config)
          return Tmux.notify("switchboard: config not reloaded — #{err}")
        end

        # Also a catch-up: `e` switches the client to home to edit, so this sidebar
        # was off-screen with a frozen baseline while the (visible) home sidebar
        # rang any completions. Reload silently on the Ctrl-R return — else those
        # already-heard completions re-ring here, the same duplicate this fix kills.
        # C-r is sent only after the client is switched back to us, so we're on screen:
        # mark visible (consume the off->on edge so tick won't reload again, ungate paint).
        set_visible(true)
        reload(announce_sounds: false)
      rescue StandardError => e
        Tmux.notify("switchboard: config not reloaded — #{e.message}")
      end

      # d: remove the highlighted thing. On a project header that's
      # remove_project (unregister + close its sessions); on a workspace it's
      # delete (drop the worktree). The legend's `d` label tracks the row kind.
      def remove
        node = current
        return unless node

        node.kind == "proj" ? remove_project(node) : delete
      end

      # Remove a project from the registry and close its sessions (the keyboard
      # path to what you'd otherwise do by hand-editing config.yml). Unregistering
      # is pure config surgery — the repo and its worktrees on disk are untouched —
      # but its sb/ sessions are torn down here: once the project is gone from the
      # registry, prune (which reconciles only against registered projects) can
      # never reach them, so they'd orphan for good.
      #
      # Removing the project you're standing in would kill the very session this
      # sidebar runs in. Like workspace delete, fall back to home first; the home
      # sidebar then drives. Home rebuilds from git, which won't show a config
      # change, so poke it to re-read the now-smaller config — BEFORE the kill, or
      # our own death aborts the poke.
      def remove_project(node)
        name = node.project
        return unless @config.project(name)
        return unless confirm("remove #{name}? (closes its sessions)")

        # Unregister first and bail on failure — never kill sessions while the
        # config still lists the project (a write error with the config stale
        # would otherwise leave a registered project with no sessions). The guard
        # above makes the error unreachable today, but it keeps the kill honest.
        _, err = Registrar.unregister(@config, name)
        return flash(err) if err

        # Every other window's sidebar caches its own @config; poke them all to
        # re-read so the removed project disappears there too (their rebuild's
        # refresh_config drops it). Fired before the kill/eject so our own imminent
        # death can't abort it — like the home C-r poke below.
        Tmux.broadcast_warm(except: ENV["TMUX_PANE"])

        ejecting = Tmux.session_of.to_s.start_with?(Tmux.session_prefix(name))
        Tmux.go_home if ejecting
        Tmux.poke_sidebar_of(Tmux::HOME, reload_config: true) if ejecting
        Tmux.kill_project_sessions(name)
        return if ejecting

        reload_config
        reload
      end

      # Delete a workspace: remove the worktree (force-confirm if dirty), drop the
      # branch if safely merged, and kill its tmux session.
      def delete
        node = current
        return unless node && node.kind == "ws"

        project = @config.project(node.project)
        return unless project

        repo = project["path"]
        label = File.basename(node.path)
        return unless confirm("delete #{label}?")

        unless Git.remove_worktree(repo, node.path)
          return unless confirm("#{label} has uncommitted changes — force?")

          Git.remove_worktree(repo, node.path, force: true)
        end
        Git.delete_branch(repo, node.branch) # safe -d; unmerged branches are kept

        worktree = Worktree.new(project: node.project, path: node.path, branch: node.branch,
                                dirty: false, pr: nil, base: nil, primary: false)
        # If we're deleting the very session we're attached to, killing it would
        # eject us from switchboard (this sidebar lives inside it). Fall back to
        # the persistent home session first, then kill — "the one you're in, last".
        # Our process dies with that session, so home's own sidebar drives from
        # here (it reloads to the post-deletion tree, which git already reflects).
        deleting_current = Tmux.session_of == Tmux.session_name(worktree)
        Tmux.go_home if deleting_current
        Tmux.kill(worktree)
        reload unless deleting_current
      end

      # Rename a workspace: move its worktree directory (the display name) + rename
      # its session in place. Shares the core with `switchboard rename` via Rename
      # (issue #42); the sidebar reloads on every outcome (silent on failure, as
      # before — the tree just re-reads git truth).
      def rename
        node = current
        return unless node && node.kind == "ws"
        project = @config.project(node.project)
        return unless project

        newname = prompt_line("rename #{File.basename(node.path)} to")
        return reload if blank_input?(newname)

        # The CLI warns these to stderr; the sidebar can't (stderr would paint over
        # the TUI), so flash on the bottom row — a silent reload would leave a failed
        # rename looking like nothing happened.
        msg = rename_error(Rename.perform(@config, node.project, node.path, newname))
        flash(msg) if msg
        reload
      end

      # Bottom-row message for a non-success rename, or nil when it succeeded (the
      # reloaded tree is feedback enough; :unchanged is not an error).
      def rename_error(result)
        case result.status
        when :exists  then "already exists: #{File.basename(result.dest)}"
        when :branch_exists then "branch #{File.basename(result.dest)} already exists — pick another name"
        when :invalid then "invalid name — letters/digits/. - _, no /, and a valid git branch"
        when :partial then "renamed the dir, but the tmux session rename failed — run prune"
        when :failed  then "rename failed (git worktree move)"
        end
      end
    end
    include Actions
  end
end
