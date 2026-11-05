# frozen_string_literal: true

require "yaml"
require "fileutils"
require "shellwords"
require_relative "paths"

module Switchboard
  # Command dispatch. The sidebar is the one navigator: the bare command (and
  # the tmux key bound to `toggle-sidebar`) shows/hides it; the rest is the
  # config/worktree management surface.
  module CLI
    module_function

    def run(argv)
      case argv.first
      when nil                 then start
      when "toggle-sidebar"    then toggle_sidebar
      when "home"              then Tmux.go_home
      when "install"           then exit(1) if install(argv.drop(1)) == false
      when "uninstall"         then exit(1) unless uninstall(argv.drop(1))
      when "upgrade"           then exit(1) unless Upgrade.run(argv.drop(1))
      when "init"              then init
      when "config", "edit"    then edit_config
      when "add"               then add_project(argv[1], argv[2], argv[3])
      when "remove", "rm"      then remove_project(argv[1])
      when "clone"             then clone_project(argv[1], argv[2])
      when "create"            then create_project(argv[1])
      when "refresh"           then refresh(*refresh_args(argv))
      when "reap-worktree"     then reap_worktree(argv[1], argv[2], argv[3], force_branch: argv[4] == "--force-branch",
                                                  branches: WorkspaceBranches.from_args(argv))
      when "new"               then exit(1) unless new_workspace(argv.drop(1))
      when "projects"          then exit(1) unless list_projects(argv.drop(1))
      when "create-workspace"  then create_workspace(argv[1])
      when "check-update"      then check_update
      when "launch"            then exit(launch(argv[1]))
      when "enable-hooks"      then exit(1) if enable_hooks(argv[1]) == false
      when "disable-hooks"     then exit(1) if disable_hooks(argv[1]) == false
      when "rename"            then exit(1) unless rename(argv[1])
      when "rename-nudge"      then HookCommands.rename_nudge(argv.drop(1))
      when "sync-session-name" then sync_session_name(argv[1], argv[2])
      when "monitoring"        then monitoring(argv[1], argv[2])
      when "monitoring-nudge"  then HookCommands.monitoring_nudge(argv.drop(1))
      when "sound"             then play_sound(argv[1])
      when "sidebar"           then argv[1] == "--check" ? exit(Sidebar.check ? 0 : 1) : Sidebar.run
      when "reload-sidebars"   then reload_sidebars
      when "poke-sidebar"      then Tmux.poke_current_sidebar
      when "reload-config"     then reload_config_poke(argv[1])
      when "sidebar-sync"      then Tmux.sidebar_sync(argv[1])
      when "poke-window"       then Tmux.poke_window(argv[1])
      when "tmux-bind"         then Installer.apply_keybindings
      when "prune"             then prune(argv.drop(1))
      when "sandbox"           then Sandbox.run
      when "quit"              then quit
      when "doctor"            then Doctor.run(config)
      when "version", "-v", "--version" then puts("switchboard #{VERSION}")
      when "help", "-h", "--help"       then help
      else
        warn "unknown command: #{argv.first}"
        help
        exit 1
      end
    end

    def config
      @config ||= Config.new
    end

    # Bare `switchboard` — the one command to start or reach switchboard from
    # anywhere. From a plain shell it bootstraps the home session and attaches
    # (go_home execs the attach when TMUX is unset), so launching is a single
    # command with no manual `tmux` first and no key to remember. Already inside
    # tmux it just toggles the sidebar (summon or dismiss, session-wide), like the key.
    def start
      ENV["TMUX"] ? Tmux.toggle_sidebar : Tmux.go_home
    end

    # Summon or dismiss the sidebar session-wide (direction read from the current
    # window) — the bound tmux key (`toggle-sidebar`) lands here. Outside tmux
    # there's no pane to toggle; run
    # bare `switchboard` to start one instead, rather than fail silently.
    def toggle_sidebar
      return warn("switchboard toggle-sidebar runs inside tmux — run `switchboard` to start a session") unless ENV["TMUX"]

      Tmux.toggle_sidebar
    end

    # Stand switchboard up from a fresh clone: PATH symlink + tmux wiring + an
    # empty config. `--no-tmux` skips the tmux.conf edit; `--print-tmux` prints
    # the line instead of writing it; `--tmux-conf PATH` targets a specific conf.
    def install(args)
      Installer.install(
        no_tmux: args.include?("--no-tmux"),
        print_tmux: args.include?("--print-tmux"),
        conf: flag_value(args, "--tmux-conf"),
        codex_hooks: codex_hooks_flag(args)
      )
    end

    # --codex-hooks ⇒ yes, --no-codex-hooks ⇒ skip, neither ⇒ prompt (Installer decides).
    # The opt-OUT wins if both are passed — never silently write global config on a
    # contradictory invocation.
    def codex_hooks_flag(args)
      return false if args.include?("--no-codex-hooks")
      return true if args.include?("--codex-hooks")

      nil
    end

    def uninstall(args)
      Installer.uninstall(conf: flag_value(args, "--tmux-conf"))
    end

    # Value following a `--flag` in args, or nil.
    def flag_value(args, name)
      i = args.index(name)
      i && args[i + 1]
    end

    # Re-fetch PR badges. With a name, just that project; otherwise all. After
    # fetching, redraw the sidebar (the sidebar passes its own pane via --poke; a
    # hand-run refresh inside tmux pokes the current window's sidebar). The
    # sidebar fires this detached, so the gh call stays off the UI thread.
    def refresh(name = nil, poke_pane = nil)
      projects = name ? config.projects.select { |p| p["name"] == name } : config.projects
      projects.each do |p|
        Pr.refresh(p["name"], p["path"]) if Dir.exist?(p["path"])
      end
      poke_after(poke_pane)
    end

    # Background worktree reaper (issue: delete hang). `Sidebar#delete` hides the row
    # via a PendingDelete marker and spawns this DETACHED so the slow `git worktree
    # remove` (an inline rm -rf of node_modules et al.) never blocks the input loop.
    # We daemonize FIRST — Process.daemon setsids into a new session with no
    # controlling terminal, the only thing that survives the pane-teardown SIGHUP when
    # the caller kills its own session (deleting the workspace you're in). Then the
    # removal core clears the marker and repaints every pane from git truth.
    def reap_worktree(repo, path, branch, force_branch: false, branches: nil)
      return unless repo && path

      Process.daemon(true, true) # new session, no ctty; keep the already-/dev/null'd stdio
      reap_worktree!(repo, path, branch, force_branch: force_branch, branches: branches)
    end

    # Background update check (#47; a visible sidebar spawns it when the cache is
    # stale). Daemonized FIRST, so it has no controlling terminal: nothing it runs (git,
    # ssh, a credential helper) can open /dev/tty and prompt into the sidebar pane.
    def check_update
      return if UpdateCheck.disabled_by_env?

      Process.daemon(true, true)
      UpdateCheck.run_child
    rescue StandardError
      nil
    end

    # Every running sidebar swaps in its own binary's current code (#48): what `upgrade`
    # does at the end, by hand — inside `switchboard sandbox`, after editing sidebar code.
    # Any binary may run it: each sidebar re-execs its OWN SWITCHBOARD_BIN, so this can't
    # repoint one at another checkout.
    def reload_sidebars
      counts = CodeReload.reload_all
      return puts("no tmux server running — no sidebars to reload") unless counts

      lines = CodeReload.describe(counts)
      puts(lines.empty? ? "no sidebars running" : lines.map(&:last))
    end

    # Background dispatch worker (Sidebar#create spawns it). Daemonized like the reaper:
    # setsid'd away from the sidebar's session, so closing that pane mid-build can't
    # SIGHUP it. TMUX stays in the env, which the worker needs to size the session.
    def create_workspace(id)
      return unless id

      Process.daemon(true, true)
      Creator.work(config, id)
    rescue StandardError
      nil
    end

    # Session-name worker (Rename.perform spawns it, inside tmux only). Daemonized like
    # the reaper so the pane that ran the rename can close under it; it may wait up to
    # SessionName::CEILING for a safe moment to type.
    def sync_session_name(dest, name)
      return unless dest && name
      # Typing into panes is only for a switchboard workspace — not a parent dir (which
      # would reach every Claude under it) or anything else this public verb is handed.
      wt = Model.workspace_at(config, dest)
      return unless wt && !wt.primary && Paths.real_or_nil(wt.path) == Paths.real_or_nil(dest)

      Process.daemon(true, true)
      SessionName.work(dest, name)
    rescue StandardError
      nil
    end

    # `switchboard new <project|.> ["task" | -]`: the sidebar's `n` from the command line,
    # so an agent can start another workspace (same project or another one) when the user
    # asks. Same pipeline: reserve + record, detached worker, broadcast; returns at once and
    # the sidebar chimes. Everything is checked BEFORE a record exists, and every doubt is a
    # refusal: nobody watches the pane this lands in. Never targets an existing workspace
    # (reserve only hands out fresh paths). True on dispatch.
    def new_workspace(args, stdin: $stdin)
      target, task_arg, err = DispatchArgs.parse(args)
      return warn(err) if err

      task = task_arg.to_s # never $SWITCHBOARD_TASK: a dispatched agent's shell carries its own
      if task_arg == "-"
        task, err = DispatchArgs.read_stdin(stdin)
        return warn(err) if err
      end
      err = DispatchArgs.task_error(task)
      return warn(err) if err

      task = task.dup.force_encoding(Encoding::UTF_8) # valid now; a C-locale ARGV is tagged binary

      return warn(config.load_error_message) if config.load_error
      here = Model.workspace_at(config)&.project
      project = dispatch_target(target, here) or return false
      # $TMUX names the server the record and the session belong to; without it the
      # worker would start a headless server nobody is attached to.
      return warn("run this inside tmux: switchboard dispatches onto the tmux server you're on") if ENV["TMUX"].to_s.empty?

      unless task.empty?
        _cmd, note = Creator.agent_command(config.session_command_for(project), task)
        return warn(note) if note # the launcher would drop the brief in a pane nobody's watching
      end

      rec = begin
        Creator.dispatch(config, project, task, brief_from: ("cli" unless task.empty?)) # no brief, nothing to label
      rescue SystemCallError, IOError
        nil
      end
      return warn("no free workspace name — try again") if rec == :no_name
      return warn("couldn't record the dispatch") unless rec.is_a?(Hash)
      return warn(Creator::SPAWN_FAILED) unless Creator.spawn_worker(rec["id"])

      Tmux.broadcast_warm
      announce_dispatch(rec, project, here)
      true
    end

    # `.` is the project the cwd is in; anything else is a registered name. Never guessed.
    def dispatch_target(target, here)
      names = config.projects.map { |p| p["name"] }
      if target == "."
        return here if here

        return warn("not inside a registered project — name one: #{names.join(', ')}")
      end
      return target if names.include?(target)

      warn(%(unknown project "#{target}" — registered: #{names.join(', ')}))
    end

    # Judged by where the caller IS, not how the target was spelled, so a same- vs
    # cross-project dispatch can't be misread.
    def announce_dispatch(rec, project, here)
      where = if here.nil? then "in #{project}"
              elsif here == project then "in this project (#{project})"
              else "in ANOTHER project (#{project}, you're in #{here})"
              end
      puts %(dispatched a new workspace #{where}: "#{rec['name']}" (◌ building))
      puts "  path: #{home_relative(rec['path'])}"
      puts "  id:   #{rec['id']}"
    end

    # `switchboard projects [--names]`: the registered names `new` accepts, `*` on the one
    # the cwd is in. `--names` is the script form (the marker shifts the table's columns).
    def list_projects(args)
      return warn(config.load_error_message) if config.load_error

      projects = config.projects
      if projects.empty?
        puts "no projects registered — `switchboard add <name> <path>`"
        return true
      end
      if args.include?("--names")
        puts(projects.map { |p| p["name"] })
        return true
      end

      here = Model.workspace_at(config)&.project
      name_w = projects.map { |p| p["name"].length }.max
      paths = projects.map { |p| home_relative(p["path"]) }
      path_w = paths.map(&:length).max
      projects.each_with_index do |p, i|
        mark = p["name"] == here ? "*" : " "
        puts "#{mark} #{p['name'].ljust(name_w)}  #{paths[i].ljust(path_w)}   (base #{p['base_ref']})"
      end
      true
    end

    def home_relative(path)
      home = Dir.home
      path.to_s == home || path.to_s.start_with?("#{home}/") ? "~#{path.to_s.delete_prefix(home)}" : path.to_s
    rescue ArgumentError
      path.to_s
    end

    # The one line the worker types into a dispatched workspace's pane.
    def launch(dest)
      return 0 unless dest

      Creator.launch(config, dest)
    end

    # The removal itself, split out so tests exercise it WITHOUT daemonizing (which
    # would detach the test process). `remove_worktree --force` owns all the
    # correctness git already enforces (dirty/submodule, a lock you set, freeing the
    # branch) — it forces past a lock only on our own un-set-up build (`unfinished_at?`).
    # `branches:` is what you confirmed deleting with the workspace; a failed removal keeps
    # them all. Without it (a canceled dispatch, an older caller) `delete_branch` is the
    # safe `-d` (git refuses a still-checked-out or unmerged branch, so it's a no-op when
    # the remove failed). The marker is cleared
    # UNCONDITIONALLY: on success the row is gone from git anyway; on failure the row
    # must REAPPEAR so a delete that didn't take isn't masked. broadcast_warm makes
    # every sidebar rebuild from git truth now instead of lagging to its next tick.
    # `force_branch:` is for a dispatched tree already proven untouched (nothing past its
    # base): a placeholder branch never reads as merged into your local base, so the
    # safe -d would leak one per canceled build.
    def reap_worktree!(repo, path, branch, force_branch: false, branches: nil)
      removed = Git.remove_worktree(repo, path, force: true, locked: Creation.unfinished_at?(path))
      if branches
        WorkspaceBranches.delete_and_report(repo, branches) if removed
      elsif branch && !branch.empty?
        Git.delete_branch(repo, branch, force: force_branch)
      end
      PendingDelete.clear(path)
      Tmux.broadcast_warm
    rescue StandardError
      PendingDelete.clear(path) # never leave the row stuck hidden on an unexpected fault
      nil
    end

    # Parse `refresh [name] [--poke PANE]`: the optional project name (first
    # non-flag arg after the subcommand) and the sidebar pane to redraw.
    def refresh_args(argv)
      name = argv[1] unless argv[1].to_s.start_with?("--")
      [name, flag_value(argv, "--poke")]
    end

    # Redraw after a refresh: the explicit pane the sidebar handed us
    # (deterministic, survives navigation) or, for a hand-run refresh inside
    # tmux, the current window's sidebar. A no-op outside tmux / with no sidebar.
    def poke_after(pane)
      if pane && !pane.empty?
        Tmux.poke(pane)
      elsif ENV["TMUX"]
        Tmux.poke_current_sidebar
      end
    end

    # Reconcile sb/ sessions against the worktrees git has, killing the orphans a
    # deleted/moved/crashed worktree left behind. `--dry-run`/`-n` only reports.
    # No tmux-guard: this talks to the tmux *server*, so cleaning stale sessions
    # from a plain shell (the usual recovery context) must work.
    def prune(args)
      dry = args.include?("--dry-run") || args.include?("-n")
      report = Reconcile.prune(config, dry_run: dry)
      reaped = Reconcile.reap_sidebars(dry_run: dry)
      puts prune_summary(report, reaped, dry)
    end

    # Format a reconcile report for a human. Distinguishes "couldn't reach tmux"
    # from "nothing orphaned" so a failed shell-out never reads as success, and
    # (dry run) ends with the next step. (doctor's orphan line reuses the same
    # Reconcile.prune Report, but formats its own row — not this method.) `reaped`
    # is the orphaned-sidebar-process pids prune also cleared — a separate axis from
    # the session orphans (process-with-no-pane vs session-with-no-worktree), so it
    # gets its own appended line and never suppresses the session summary.
    def prune_summary(report, reaped, dry)
      [session_prune_summary(report, dry), sidebar_reap_summary(reaped, dry)].compact.join("\n")
    end

    def session_prune_summary(report, dry)
      return "no tmux server — nothing to reconcile" unless report.reachable
      return "no sb/ sessions found" if report.sb_count.zero?
      return "#{report.sb_count} sb/ session(s), none orphaned" if report.orphans.empty?

      verb = dry ? "would kill" : "killed"
      lines = ["#{verb} #{report.orphans.size} orphaned session(s):", *report.orphans.map { |n| "  #{n}" }]
      lines << "run `switchboard prune` to remove these" if dry
      lines.join("\n")
    end

    # nil (no line) when nothing was orphaned, so a clean run reads as just the
    # session summary.
    def sidebar_reap_summary(reaped, dry)
      return if reaped.empty?

      "#{dry ? 'would reap' : 'reaped'} #{reaped.size} orphaned sidebar process(es)"
    end

    # Tear down switchboard: kill every sb/ session, the one you're in last (so
    # it never orphans the others). Like prune, works outside tmux.
    def quit
      Creation.cancel_all # BEFORE the kill: an in-flight build must not open a session after it
      AgentState.clear_all  # killing every agent makes their last hook state stale — drop it now
      Monitoring.clear_all  # ...and every monitoring declaration is now stale too
      Notify.clear_all      # ...and any pending "come look" alert is moot once the agents are gone
      OffstageHold.clear_all # ...and any held ◷ chime: the background work it waited on died with them
      PendingDelete.clear_all # ...and any in-flight delete's row-hide (the daemon still finishes the removal)
      killed = Tmux.kill_all
      puts(killed.empty? ? "no switchboard sessions to close" : "closed #{killed.size} switchboard session(s)")
    end

    # `monitoring on [ttl] | off` (bare = status): declare or clear that a background
    # monitor / recurring loop is running in THIS worktree, so the sidebar shows a steady
    # ∞ instead of reading as done/idle. Agent- or human-invoked; resolves the worktree
    # from cwd like the rename nudge. Re-running `on` re-affirms (refreshes the liveness
    # clock) — that's how a live monitor keeps its dot up across cycles; a stopped agent
    # that stops re-affirming lets the marker age out. The optional `ttl` (seconds) sizes
    # that liveness window: a loop slower than the ~10-min default passes its own cadence
    # (e.g. `monitoring on 2400` for a 30-min tick) so the dot doesn't go dark between ticks.
    def monitoring(sub, ttl_arg = nil)
      wt = Model.workspace_at(config)
      if wt.nil? || wt.primary
        puts "not inside a switchboard workspace — nothing to mark"
        return
      end

      leaf = File.basename(wt.path)
      case sub
      when "on"
        ttl = Monitoring.positive_int(ttl_arg) # nil => default window; garbage falls back too
        Monitoring.mark(wt.path, ttl: ttl)
        puts "monitoring on#{" (ttl #{ttl}s)" if ttl}: #{leaf}"
      when "off"
        Monitoring.clear(wt.path)
        puts "monitoring off: #{leaf}"
      when "notify"
        # Declared "come look — this cycle surfaced something." Gated to a monitored
        # workspace (the verb lives under `monitoring`, and it's the ONE exception to
        # monitoring's :done suppression). Writes both markers: Attention for the
        # persistent bold (direct, so an away user still gets it), Notify for the
        # announce-gated sound/sparkle the sidebar rings on its next scan. The direct
        # Attention.mark deliberately bypasses the edge's "don't bold the workspace you're
        # viewing" skip (the CLI can't cheaply know the focused pane) — so a notify fired
        # while you're sitting IN this workspace briefly bolds its own row; the viewing
        # sidebar's next reload runs locate and clears it, so it self-heals within a tick.
        if Monitoring.monitored([wt.path]).empty?
          puts "not monitoring — run `monitoring on` first: #{leaf}"
        else
          Attention.mark(wt.path)
          Notify.mark(wt.path)
          puts "monitoring notify: #{leaf}"
        end
      when nil, "status"
        puts "monitoring #{Monitoring.monitored([wt.path]).any? ? 'on' : 'off'}: #{leaf}"
      else
        puts "usage: switchboard monitoring on [ttl_seconds] | off | notify"
      end
    end

    # Create an empty config (no projects yet). Add your first project from the
    # sidebar (`a`) or `switchboard add`; `install` runs this for you.
    def init
      if Config.exist?
        puts "config already exists: #{Config.path}"
        return
      end

      Config.scaffold
      puts "wrote #{Config.path}"
      puts "add a project from the sidebar (`a`) or `switchboard add <name> <path>`."
    end

    # Open the config in $EDITOR in the current terminal. The sidebar's `e` opens
    # it in a dedicated pane beside the home tree instead (Sidebar#edit_config); a
    # shell invocation edits right where you typed it — the "edit in place" escape
    # hatch. Scaffolds a minimal stub first so there's always a real file to edit.
    def edit_config
      Config.scaffold
      warn("could not launch editor: #{Editor.command}") unless system("#{Editor.command} #{Shellwords.escape(Config.path)}")
      # DX1: if we're inside tmux, a changed tmux_keys takes effect right away.
      Installer.apply_keybindings(announce: true) if ENV["TMUX"]
    end

    # Run from `e`'s throwaway editor pane after :q (see Sidebar#edit_config):
    # switch the client back to the session `e` was pressed from (origin, if it's
    # still alive), then poke THAT sidebar to re-read config and redraw. Origin
    # blank/home ⇒ poke home in place. A dedicated path (the Ctrl-R poke), so the
    # cheap C-l session-switch poke never re-reads config. No-op outside tmux.
    def reload_config_poke(origin)
      return unless ENV["TMUX"]

      target = origin.to_s.empty? ? Tmux::HOME : origin
      Tmux.switch(target) if target != Tmux.session_of
      Tmux.poke_sidebar_of(target, reload_config: true) ||
        Tmux.poke_sidebar_of(Tmux::HOME, reload_config: true)
      # A `e` edit can add/remove a project too, so poke every OTHER sidebar to
      # re-read the changed config (their rebuild's refresh_config picks it up),
      # not just the origin session we C-r'd above — else the new project only
      # shows in the session you edited from until the others respawn.
      Tmux.broadcast_warm(except: Tmux.window_sidebar_pane(target))
      # DX1/DX2: re-apply tmux_keys so a changed toggle/home takes effect on save
      # (like every other knob), and announce the result so the user sees it.
      Installer.apply_keybindings(announce: true)
    end

    def add_project(name, path, base = nil)
      return warn("usage: switchboard add <name> <path> [base-ref]") if name.nil? || path.nil?

      entry, err = Registrar.register(config, path, name: name, base: base)
      return warn(err) if err

      puts "added #{entry['name']} -> #{entry['path']}"
    end

    # Drop a project from the registry — the CLI twin of the sidebar's `d` on a
    # project row, minus the tmux session teardown (a shell invocation isn't
    # inside a session, and `prune` cleans the leftovers). The repo on disk is
    # untouched; you can re-add it anytime.
    def remove_project(name)
      return warn("usage: switchboard remove <name>") if name.nil?

      _, err = Registrar.unregister(config, name)
      return warn(err) if err

      puts "removed #{name} (its repo on disk is untouched)"
    end

    # Clone a repo under `projects_root` and register it (realizes the v2
    # roadmap item). Name defaults to the URL's basename.
    def clone_project(url, name = nil)
      return warn("usage: switchboard clone <git-url> [name]") if url.nil?

      entry, err = Registrar.clone(config, url, name: name)
      return warn(err) if err

      puts "cloned + added #{entry['name']} -> #{entry['path']}"
    end

    # Create a brand-new empty repo under `projects_root` and register it — the
    # CLI twin of the sidebar's add → [n] new. The repo is born with an empty
    # initial commit so `n` (a worktree) works right away.
    def create_project(name)
      return warn("usage: switchboard create <name>") if name.nil?

      entry, err = Registrar.create(config, name)
      return warn(err) if err

      puts "created + added #{entry['name']} -> #{entry['path']}"
    end

    # Wire agent-state hooks into a single worktree's local agent settings
    # (scoped, never global). Defaults to the worktree you're standing in.
    def enable_hooks(path = nil)
      worktree = Git.toplevel(File.expand_path(path || ".")) or return warn("not inside a git worktree (pass a path)")

      AgentHooks.enable(worktree) # claude, per-worktree
      # current?, not enabled?: an older release's hooks would still read as enabled after a
      # rewrite that failed (an unparseable or unwritable file).
      unless ClaudeHook.current?(worktree)
        Installer.bad "claude hooks not enabled in #{worktree} — fix #{ClaudeHook.settings_path(worktree)}, then re-run"
        return false
      end
      unless HookFile.script_current? # ensure_script swallows a failed write
        Installer.bad Installer.reporter_unwritable
        return false
      end
      puts "enabled agent-state hooks in #{worktree}"
      puts "  reporter: #{HookFile.script_path}"
      puts "  claude: #{ClaudeHook.settings_path(worktree)} — a running claude picks it up on its own"
      # Codex is GLOBAL (one ~/.codex/config.toml block — codex can't see project hooks in
      # linked worktrees). Re-ensure it if already opted in (self-heal); else point at install.
      if CodexHook.installed?
        result = CodexHook.install_global
        if result == CodexHook.config_path
          puts "  codex:  #{CodexHook.config_path} (global) — run `/hooks` in codex to approve"
        else
          Installer.report_codex_install(result, reensure: true, verb: "enable-hooks") # a refusal must not read as success
          return false # …nor exit 0 (claude's hooks above are still wired)
        end
      else
        puts "  codex:  not enabled — `switchboard install --codex-hooks` adds the global block"
      end
    end

    # The per-worktree opt-out: every new worktree gets the hooks, so this is how one goes
    # without. False (exit 1) when they're still there, since disable swallows a failed write.
    def disable_hooks(path = nil)
      worktree = Git.toplevel(File.expand_path(path || ".")) or return warn("not inside a git worktree (pass a path)")

      AgentHooks.disable(worktree) # claude, per-worktree
      # disable leaves a file it can't parse or read untouched, and enabled? reads that as off:
      # not proof. Fail only while switchboard's hooks may still be there (a broken file of
      # your own, or a committed link to a file without them, has nothing of ours to remove).
      if ClaudeHook.enabled?(worktree) || ClaudeHook.corrupt?(worktree) || ClaudeHook.unreadable?(worktree)
        Installer.bad "couldn't remove claude hooks in #{worktree} — fix #{ClaudeHook.settings_path(worktree)}, then re-run"
        return false
      end
      puts "disabled switchboard's hooks in #{worktree} (this worktree only; new worktrees still get them)"
      puts "  (codex hooks are global — `switchboard uninstall` removes them)" if CodexHook.installed?
    end

    # Rename the workspace the cwd is in (issue #42) — the agent verb: a running
    # agent has the best context for a good name, so let it (re)name its own live
    # workspace. Resolves the workspace from cwd, refuses the primary checkout,
    # then runs the shared Rename core (dir move + bridge + session rename).
    # Returns true on success so `run` can exit non-zero on failure — an agent's
    # `switchboard rename x && cd …` must not proceed past a failed rename.
    def rename(newname)
      wt = Model.workspace_at(config)
      return warn("not inside a switchboard-managed worktree (cd into one first)") unless wt
      return warn("can't rename the primary checkout") if wt.primary

      # No-arg: nothing to rename to. Print usage + the current name (the agent/user
      # supplies the new name — switchboard no longer guesses one). Falsy ⇒ exit 1.
      return warn(%(usage: switchboard rename <newname> (this workspace is "#{File.basename(wt.path)}"))) if newname.nil?

      sub = subpath_in(wt.path) # capture before the move so the cd hint is subdir-aware
      report_rename(Rename.perform(config, wt.project, wt.path, newname), sub)
    end

    # Map a Rename::Result to output, returning true on success (false ⇒ `run`
    # exits non-zero). Both :ok and :partial moved the dir, so both announce the
    # new path; :partial adds the orphaned-session caveat and still fails.
    def report_rename(result, sub)
      case result.status
      when :ok
        announce_landing(result, sub)
        Tmux.poke_current_sidebar if ENV["TMUX"]
        true
      when :partial
        announce_landing(result, sub)
        warn "  the tmux session rename failed — run `switchboard prune` to clean the orphan"
        false
      when :unchanged
        puts "already named #{File.basename(result.dest)}"
        announce_session_sync(result)
        true
      when :invalid
        warn "invalid name — must be letters/digits/. - _ (no `/`) and a valid git branch name"
        false
      when :exists
        warn "already exists: #{result.dest}"
        false
      when :branch_exists
        warn "a branch named #{File.basename(result.dest)} already exists — choose another name"
        false
      when :building
        warn "this workspace is still being created; rename it once it's ready"
        false
      else # :failed
        warn "rename failed (git worktree move)"
        false
      end
    end

    # Point the user at the new path. The interactive shell's cwd is now stale
    # (the bridge keeps the OLD path resolvable, but `pwd` still reports it), so
    # cd into the new one — preserving any subdir they were standing in.
    def announce_landing(result, sub)
      target = sub.empty? ? result.dest : File.join(result.dest, sub)
      puts "renamed to #{result.dest}"
      puts "  cd into the new path: cd #{Shellwords.escape(target)}"
      announce_session_sync(result)
    end

    # Usually an agent ran the rename, and it's about to see Claude's "session renamed"
    # note appear as if the user typed /rename — say up front that it's switchboard's.
    def announce_session_sync(result)
      return unless result.spawned

      leaf = File.basename(result.dest)
      puts "  any live Claude session here will be renamed to #{leaf} too, #{SessionName::WHEN} — " \
           "a note that the session was named #{leaf} is switchboard syncing it, not a new request"
    end

    # cwd relative to a worktree root ("" when standing at the root), so the
    # rename cd hint can return the user to the same subdir under the new path.
    def subpath_in(root)
      cwd = Paths.real_or_nil(Dir.pwd)
      base = Paths.real_or_nil(root)
      return "" unless cwd && base && cwd.start_with?("#{base}/")

      cwd[(base.length + 1)..]
    end

    # Play a configured sound, for trying audio out / picking sounds (and showing
    # it off). `switchboard sound [done|waiting|alert]` — defaults to done. Uses the
    # GLOBAL sound config (no project context), blocks until it finishes, and
    # reports WHY nothing played (muted / no player / unresolvable spec) so a
    # silent run is never mistaken for success.
    def play_sound(state = nil)
      state = state || "done"
      return warn("usage: switchboard sound [done|waiting|alert|failed]") unless %w[done waiting alert failed].include?(state)

      spec = config.sound_for(nil, state.to_sym)
      return warn("sounds are muted for #{state} (set `sounds: { enabled: true }`)") if spec.nil?
      return warn("no audio player on PATH (need afplay, paplay, aplay, or ffplay)") unless Sound.player_argv

      case Sound.status(spec)
      when :ok then Sound.play(spec, wait: true)
      when :missing_file then warn("sound #{state}: file not found — #{spec}")
      when :macos_only then warn("sound #{state}: '#{spec}' is a macOS system-sound name, not available on this OS")
      when :missing_system_sound then warn("sound #{state}: no system sound named '#{spec}'")
      else warn("sound #{state}: couldn't resolve '#{spec}'")
      end
    end

    def help
      puts <<~HELP
        switchboard — keyboard-only worktree switcher + creator

        usage
          switchboard              start switchboard — attach the home session from a shell, or toggle the sidebar inside tmux
          sb                       alias for `switchboard` (installed on PATH)
          switchboard home         attach to the persistent home session (anchor + settings)
          switchboard install      symlink onto PATH + wire tmux bindings + empty config
                                     (--no-tmux | --print-tmux | --tmux-conf PATH)
          switchboard uninstall    reverse install (symlink + tmux bindings)
          switchboard upgrade      update to the newest release (Homebrew, or a fast-forward pull in a clone) and re-wire tmux + hooks
          switchboard init         create an empty config (no projects yet)
          switchboard config       edit config.yml in $EDITOR (per-project settings)
          switchboard add N P [B]  register an existing repo (name, path, base ref)
          switchboard remove N     unregister a project (its repo on disk stays; alias: rm)
          switchboard clone U [N]  clone a repo under projects_root, then register
          switchboard create N     create a brand-new empty repo under projects_root, then register
          switchboard new P [TASK|-]  dispatch a new workspace in project P (`.` = this one) with an agent on TASK (- reads it from stdin), like `n`
          switchboard projects     list registered projects (* = the one you're in; --names for names only)
          switchboard refresh      re-fetch PR badges from gh (normally automatic)
          switchboard enable-hooks [P]   wire agent-state dots in a worktree (default: cwd)
          switchboard disable-hooks [P]  remove them from that worktree
          switchboard rename NAME    rename the current workspace (dir + tmux session + Claude session name)
          switchboard monitoring on [secs]|off  flag this workspace as running a background monitor (∞; optional secs = liveness ttl for slow loops; bare = status)
          switchboard monitoring notify  (from a monitored workspace) surface this cycle's output — bold + a distinct alert sound, even though routine ticks stay silent
          switchboard sound [done|waiting|alert]  play a state's sound (try audio / pick sounds)
          switchboard prune        kill orphaned sb/ sessions + reap orphaned sidebar processes (--dry-run / -n previews)
          switchboard sandbox      dogfood THIS checkout's sidebar in a throwaway, isolated tmux (auto-torn-down on detach)
          switchboard reload-sidebars  every running sidebar swaps in its switchboard's current code, in place (upgrade does this itself)
          switchboard quit         close ALL switchboard sessions (full teardown — kills the one you're in too)
          switchboard doctor       check dependencies + config
          switchboard help         show this help

        in the sidebar
          ↑↓ ^N/^P move (projects, workspaces, and a workspace's branches)
          /        filter — type to jump to a workspace by name (↵ open, esc cancel)
          ↵        switch to the workspace's tmux session (or collapse a project)
          a        add a project (register a local repo, clone a URL, or create a new one)
          n        create a new worktree in the highlighted project
          o        open the highlighted PR in the browser (gh pr view --web)
          R        refresh PR badges now (catch a PR merged/closed on GitHub)
          r        rename a workspace
          d        remove the highlighted row — delete a workspace, or unregister a project (+ close its sessions)
          e        edit config (opens beside the home tree, returns you on quit)
          q        quit switchboard — tear down every sb/ session (confirms first)
          (prefix-s toggles the sidebar: summon + focus when hidden, dismiss when visible)
      HELP
    end
  end
end
