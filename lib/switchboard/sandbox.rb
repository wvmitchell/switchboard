# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module Switchboard
  # `switchboard sandbox` (#126) — an isolated, interactive tmux session for
  # dogfooding THIS checkout's sidebar without touching your real sessions. "The
  # smoke harness, but you're the client": boots a throwaway server on its own
  # socket (IsolatedServer), seeds a hermetic repo with worktrees in varied visual
  # states, points the integration at this checkout, drops you into an attached home
  # session, and tears the whole server + state down on detach.
  #
  # Isolation (issue #126, hardened by the eng/codex/fable review): every switchboard
  # state path is redirected into the throwaway tree and git/gh are walled off, so
  # nothing switchboard writes escapes. HOME is kept real (so the pane shell/tmux/ruby
  # still work — safe because every state path is redirected). TMUX is cleared (else a
  # nested attach from inside your real tmux fails). SWITCHBOARD_SANDBOX stops the two
  # operations switchboard's OWN code would otherwise run against outside state: prune's
  # machine-global sidebar reap, and the background PR refresh that would clobber the
  # seeded badge. A third escape isn't switchboard's to gate with its own flag — Claude
  # Code's self-updater would repoint the global ~/.local/bin/claude symlink into the
  # throwaway tree — so sandbox_env passes claude its own opt-outs (DISABLE_UPDATES /
  # DISABLE_AUTOUPDATER, #145).
  module Sandbox
    module_function

    PREFIX  = "sbx"      # throwaway socket-dir prefix, distinct from smoke's "sbk"
    PROJECT = "sandbox"

    def run
      unless tmux?
        warn "switchboard sandbox needs tmux on PATH — install tmux to use it"
        return false
      end

      checkout = checkout_root
      puts "switchboard sandbox: dogfooding #{checkout}#{branch_note(checkout)}"

      IsolatedServer.sweep_stale(PREFIX)                 # reap dead-pid leftovers from earlier crashes
      sock_dir = IsolatedServer.make_socket_dir(PREFIX)

      # The ensure wraps EVERYTHING after the dir is created — a failure in seeding or
      # boot (e.g. a git error) would otherwise leak the /tmp/sbx dir + a booted server.
      # teardown is safe pre-boot: no server ⇒ empty socket ⇒ isolated_socket? false ⇒
      # skip kill, just remove the dir.
      begin
        state_dir = File.join(sock_dir, "state")         # co-located: one teardown/sweep reaps server + state
        FileUtils.mkdir_p(state_dir)
        apply_env(sandbox_env(sock_dir, state_dir, checkout))
        write_git_config                                 # identity + gpgsign off, so seed commits AND `n` work under the walled config
        seed_repo(state_dir)
        write_config(state_dir)
        boot(sock_dir, checkout)
        system("tmux", "attach", "-t", Tmux::HOME)       # BLOCKS until you detach; NOT exec, so teardown runs
      ensure
        teardown(sock_dir)
        puts "switchboard sandbox: torn down (#{checkout})"
      end
      true
    end

    # --- env: the full wall-off (F4/F10) -------------------------------------

    # Pure: { set:, unset: } — every switchboard/XDG/git/gh path redirected into
    # the throwaway tree, TMUX + GH_TOKEN cleared, plus a few non-path behavior guards
    # (SWITCHBOARD_SANDBOX, and claude's DISABLE_UPDATES/DISABLE_AUTOUPDATER — #145).
    # Reuses SandboxTest#setup's literal key set (the isolation reference). HOME is
    # deliberately absent — the pane shell/tmux/ruby must stay usable, and every state
    # path below is redirected, so nothing switchboard writes escapes. Split out pure so
    # a unit test can assert every state path lands in the throwaway tree, the guards are
    # set, and HOME is untouched.
    def sandbox_env(sock_dir, state_dir, checkout = checkout_root)
      {
        set: {
          "TMUX_TMPDIR"                     => sock_dir,
          "SWITCHBOARD_BIN"                 => File.join(checkout, "bin", "switchboard"),
          "SWITCHBOARD_SANDBOX"             => "1",
          "SWITCHBOARD_CONFIG"              => File.join(state_dir, "config.yml"),
          "SWITCHBOARD_BIN_DIR"             => File.join(state_dir, "bin"),
          "SWITCHBOARD_STATE_DIR"           => File.join(state_dir, "agent-state"),
          "SWITCHBOARD_ATTENTION_DIR"       => File.join(state_dir, "attention"),
          "SWITCHBOARD_MONITORING_DIR"      => File.join(state_dir, "monitoring"),
          "SWITCHBOARD_COLLAPSE_DIR"        => File.join(state_dir, "collapse"),
          "SWITCHBOARD_FULL_HEADER_FILE"    => File.join(state_dir, "full_header"),
          "SWITCHBOARD_BRANCH_FOLD_FILE"    => File.join(state_dir, "branch_fold"),
          "SWITCHBOARD_WIDTH_FILE"          => File.join(state_dir, "width"),
          "SWITCHBOARD_CACHE_DIR"           => File.join(state_dir, "cache"),
          "SWITCHBOARD_CLAUDE_PROJECTS_DIR" => File.join(state_dir, "claude-projects"),
          "XDG_STATE_HOME"                  => File.join(state_dir, "xdg-state"),
          "XDG_DATA_HOME"                   => File.join(state_dir, "xdg-data"),
          "XDG_CONFIG_HOME"                 => File.join(state_dir, "xdg-config"),
          "XDG_CACHE_HOME"                  => File.join(state_dir, "xdg-cache"),
          "GIT_CONFIG_GLOBAL"               => File.join(state_dir, "gitconfig"),
          "GIT_CONFIG_SYSTEM"               => File::NULL,
          "GH_CONFIG_DIR"                   => File.join(state_dir, "gh"),
          # Behavior guards, NOT throwaway paths: neuter Claude Code's self-updater. An
          # update (auto OR manual `claude update`) installs under the redirected
          # XDG_DATA_HOME but repoints the GLOBAL ~/.local/bin/claude symlink there, which
          # teardown then deletes — `command not found: claude` system-wide (#145). We
          # can't gate claude's internals with SWITCHBOARD_SANDBOX, so we pass claude its
          # own opt-outs. DISABLE_UPDATES is the documented superset of DISABLE_AUTOUPDATER;
          # both are set as belt-and-suspenders (the superset is a docs claim, and the
          # automatic path — the one that bit us — is what DISABLE_AUTOUPDATER names).
          # Recovery: ln -sf ~/.local/share/claude/versions/<latest> ~/.local/bin/claude
          "DISABLE_AUTOUPDATER"             => "1",
          "DISABLE_UPDATES"                 => "1"
        },
        # gh authenticates from GH_TOKEN OR GITHUB_TOKEN (and the *_ENTERPRISE_* twins),
        # so all four must go or a manual `o`/PR action could use real credentials even
        # with GH_CONFIG_DIR redirected. TMUX is cleared so a nested attach from inside
        # real tmux works (and helpers don't take the wrong "inside tmux" branch).
        unset: %w[TMUX GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN]
      }
    end

    # Keywise MERGE + delete — never ENV.replace (that would wipe PATH/TERM and
    # leave `tmux` unfindable, the attach dead).
    def apply_env(env)
      env[:set].each { |k, v| ENV[k] = v }
      env[:unset].each { |k| ENV.delete(k) }
    end

    # A throwaway global gitconfig so seed commits (and a live `n` inside the
    # sandbox) work under the walled GIT_CONFIG_GLOBAL: identity is present and
    # gpgsign/hooks from the real ~/.gitconfig can't stall or reshape them.
    def write_git_config
      path = ENV["GIT_CONFIG_GLOBAL"]
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~CONF)
        [user]
        \tname = Switchboard Sandbox
        \temail = sandbox@switchboard.local
        [init]
        \tdefaultBranch = main
        [commit]
        \tgpgsign = false
      CONF
    end

    # --- seeding (F2/F9 — varied visual state, correct fixtures) --------------

    # Materialize one project + four worktrees exercising the render paths the
    # sidebar UI is dogfooded for. NOT pure (it writes repos, worktrees, caches,
    # dots) — the caller supplies the throwaway root.
    def seed_repo(state_dir)
      repo    = File.join(state_dir, "projects", PROJECT)
      wt_root = File.join(state_dir, "worktrees", PROJECT)
      FileUtils.mkdir_p(repo)
      FileUtils.mkdir_p(wt_root)

      git(repo, "init", "-q", "-b", "main")
      File.write(File.join(repo, "README.md"), "switchboard sandbox seed\n")
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "seed")

      add_worktree(repo, wt_root, "auth-token-refresh", "sandbox/auth-token-refresh") # 1. open PR badge
      seed_big_diff(add_worktree(repo, wt_root, "bulk-import", "sandbox/bulk-import")) # 2. big +/- diff
      add_worktree(repo, wt_root, "quiet-cleanup", "sandbox/quiet-cleanup")            # 3. no-PR row
      seed_branch_history(add_worktree(repo, wt_root, "sidebar-polish", "sandbox/sidebar-polish")) # 4. multi-branch
      add_worktree(repo, wt_root, "watch-ci", "sandbox/watch-ci")                     # 5. background monitor (∞)

      seed_pr_cache("sandbox/auth-token-refresh")
      seed_dot(File.join(wt_root, "auth-token-refresh"), "thinking")
      seed_dot(File.join(wt_root, "quiet-cleanup"), "done")
      seed_dot(File.join(wt_root, "watch-ci"), "done")     # a resting agent...
      seed_monitor(File.join(wt_root, "watch-ci"))         # ...flagged monitoring -> renders ∞, not ●
    end

    def add_worktree(repo, wt_root, leaf, branch)
      dest = File.join(wt_root, leaf)
      git(repo, "worktree", "add", "-q", "-b", branch, dest, "main")
      dest
    end

    # A committed diff vs base main, big enough that +adds −dels reads as non-trivial.
    def seed_big_diff(dir)
      File.write(File.join(dir, "data.txt"), Array.new(400) { |i| "row #{i}" }.join("\n") + "\n")
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", "bulk import 400 rows")
    end

    # Each `checkout -b` writes a "checkout: moving from X to Y" reflog line that
    # Git.branch_history reads to expand the workspace into inline branch rows. Runs
    # INSIDE the linked worktree (branch_history reads that worktree's own logs/HEAD),
    # then returns to the leaf branch so the ws row sits on it.
    def seed_branch_history(dir)
      git(dir, "checkout", "-q", "-b", "sandbox/sidebar-polish-wip")
      git(dir, "checkout", "-q", "-b", "sandbox/sidebar-polish-fix")
      git(dir, "checkout", "-q", "sandbox/sidebar-polish")
    end

    # Seed a FRESH, correctly-shaped PR cache: the renderer reads "identifier" +
    # "status" (a missing identifier renders "#?"). Fresh mtime + SWITCHBOARD_SANDBOX
    # (which skips the background refresh) keeps it authoritative all session.
    def seed_pr_cache(branch)
      FileUtils.mkdir_p(Pr.cache_dir)
      File.write(Pr.cache_file(PROJECT),
                 JSON.dump(branch => { "identifier" => "#12", "status" => "OPEN", "is_draft" => 0 }))
    end

    # Drop a fresh agent-state hook file so a dot renders. Content is the reporter's
    # "<state>\t<cwd>\t<epoch>" (AgentState keys on the cwd IN the content, not the
    # filename); cwd is the worktree realpath so it matches the tree.
    def seed_dot(worktree, state)
      dir = AgentState.state_dir
      FileUtils.mkdir_p(dir)
      cwd = File.realpath(worktree)
      File.write(File.join(dir, "sandbox-#{File.basename(worktree)}"),
                 "#{state}\t#{cwd}\t#{Time.now.to_i}\n")
    rescue StandardError
      nil # a dot that fails to seed just doesn't render — never abort the sandbox
    end

    # Flag a worktree as running a background monitor so its row shows the ∞ dot. Reuses
    # the real Monitoring.mark (fresh mtime => live within TTL); render_state's precedence
    # then turns its resting dot into ∞ instead of ●.
    def seed_monitor(worktree)
      Monitoring.mark(File.realpath(worktree))
    rescue StandardError
      nil # a marker that fails to seed just doesn't render the ∞ — never abort the sandbox
    end

    # base: main + projects: are load-bearing (F2): without base the no-origin repo
    # defaults to origin/main and `n`/diff break; without projects the tree is empty.
    def write_config(state_dir)
      File.write(ENV["SWITCHBOARD_CONFIG"], <<~YAML)
        worktree_root: #{File.join(state_dir, 'worktrees')}
        projects_root: #{File.join(state_dir, 'projects')}
        base: main
        auto_rename: false
        agent_state_hooks: false
        projects:
          - name: #{PROJECT}
            path: #{File.join(state_dir, 'projects', PROJECT)}
      YAML
    end

    # --- server lifecycle ----------------------------------------------------

    # A detached home session: a work-pane shell + the sidebar split beside it (so
    # it's never a lone pane — no #64). Source the CHECKOUT's fragment (hooks/keys
    # point at this checkout, sourced last), then spawn the sidebar. The interactive
    # client attaches LAST (run's `system attach` blocks the terminal), so the sidebar
    # paints on the attach → client-session-changed poke; no pre-attach render poll (F5).
    def boot(sock_dir, checkout)
      home = Tmux::HOME
      system("tmux", "new-session", "-d", "-s", home, "-x", "220", "-y", "50", "-c", sock_dir,
             out: File::NULL, err: File::NULL)
      system("tmux", "set-option", "-t", home, "@sb_sidebar", "on", out: File::NULL, err: File::NULL)
      # run-shell execs its arg via `sh -c`, so a checkout path with a space would
      # word-split and silently drop every keybinding + hook — Shellwords.escape it.
      fragment = File.join(checkout, "switchboard.tmux")
      system("tmux", "run-shell", Shellwords.escape(fragment), out: File::NULL, err: File::NULL) if File.exist?(fragment)
      Tmux.spawn_sidebar(target: home)
    end

    # Kill the throwaway server and remove the whole dir (socket + co-located state).
    # The kill is CONFINED by IsolatedServer.kill_env (TMUX cleared + TMUX_TMPDIR pinned
    # to sock_dir), so it can only ever reach OUR server — even if teardown runs after
    # an early failure that never unset the caller's real $TMUX. Unconditional (no
    # readback gate): a flaky `display-message` must never skip the kill and then remove
    # the dir out from under a still-live daemon (orphaning it where sweep can't find it).
    # `kill-server` with no server is a harmless no-op. Best-effort.
    def teardown(sock_dir)
      return unless sock_dir

      system(IsolatedServer.kill_env(sock_dir), "tmux", "kill-server", out: File::NULL, err: File::NULL)
      FileUtils.remove_entry(sock_dir) if File.directory?(sock_dir)
    rescue StandardError
      nil
    end

    # --- helpers -------------------------------------------------------------

    # The WORKTREE this sandbox.rb lives in (lib/switchboard/ -> repo root), NOT
    # ENV["SWITCHBOARD_BIN"] — which bin/switchboard resolved through the installed
    # symlink, so a PATH `switchboard sandbox` would otherwise dogfood the canonical
    # checkout. The loaded code IS this checkout, so __dir__ is the truth (F6).
    def checkout_root
      File.expand_path("../..", __dir__)
    end

    def branch_note(dir)
      b = `git -C #{Shellwords.escape(dir)} rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      b.empty? ? "" : " (#{b})"
    end

    def tmux?
      system("command -v tmux >/dev/null 2>&1")
    end

    # Run git under `dir`, raising with output on failure so a broken seed fails
    # loudly instead of producing a silently-empty tree.
    def git(dir, *args)
      out = `git -C #{Shellwords.escape(dir)} #{args.map { |a| Shellwords.escape(a) }.join(' ')} 2>&1`
      raise "git #{args.join(' ')} failed: #{out}" unless $?.success?

      out
    end
  end
end
