# frozen_string_literal: true

require "yaml"
require "fileutils"
require "shellwords"

module Switchboard
  # Command dispatch. The sidebar is the one navigator: the bare command (and
  # the tmux key bound to `toggle-sidebar`) shows/hides it; the rest is the
  # config/worktree management surface.
  module CLI
    module_function

    def run(argv)
      case argv.first
      when nil, "toggle-sidebar" then toggle_sidebar
      when "home"              then Tmux.go_home
      when "install"           then install(argv.drop(1))
      when "uninstall"         then uninstall(argv.drop(1))
      when "init"              then init
      when "config", "edit"    then edit_config
      when "add"               then add_project(argv[1], argv[2], argv[3])
      when "clone"             then clone_project(argv[1], argv[2])
      when "refresh"           then refresh(*refresh_args(argv))
      when "enable-hooks"      then enable_hooks(argv[1])
      when "disable-hooks"     then disable_hooks(argv[1])
      when "sidebar"           then Sidebar.run
      when "poke-sidebar"      then Tmux.poke_current_sidebar
      when "prune"             then prune(argv.drop(1))
      when "quit"              then quit
      when "doctor"            then doctor
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

    # Show/hide the sidebar in the current tmux window — the bare command and
    # the bound tmux key both land here. Outside tmux there's no pane to toggle,
    # so say so rather than fail silently.
    def toggle_sidebar
      return warn("switchboard lives in tmux — start a tmux session first") unless ENV["TMUX"]

      Tmux.toggle_sidebar
    end

    # Stand switchboard up from a fresh clone: PATH symlink + tmux wiring + an
    # empty config. `--no-tmux` skips the tmux.conf edit; `--print-tmux` prints
    # the line instead of writing it; `--tmux-conf PATH` targets a specific conf.
    def install(args)
      Installer.install(
        no_tmux: args.include?("--no-tmux"),
        print_tmux: args.include?("--print-tmux"),
        conf: flag_value(args, "--tmux-conf")
      )
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
      puts prune_summary(Reconcile.prune(config, dry_run: dry), dry)
    end

    # Format a reconcile report for a human. Distinguishes "couldn't reach tmux"
    # from "nothing orphaned" so a failed shell-out never reads as success, and
    # (dry run) ends with the next step. (doctor's orphan line reuses the same
    # Reconcile.prune Report, but formats its own row — not this method.)
    def prune_summary(report, dry)
      return "no tmux server — nothing to reconcile" unless report.reachable
      return "no sb/ sessions found" if report.sb_count.zero?
      return "#{report.sb_count} sb/ session(s), none orphaned" if report.orphans.empty?

      verb = dry ? "would kill" : "killed"
      lines = ["#{verb} #{report.orphans.size} orphaned session(s):", *report.orphans.map { |n| "  #{n}" }]
      lines << "run `switchboard prune` to remove these" if dry
      lines.join("\n")
    end

    # Tear down switchboard: kill every sb/ session, the one you're in last (so
    # it never orphans the others). Like prune, works outside tmux.
    def quit
      killed = Tmux.kill_all
      puts(killed.empty? ? "no switchboard sessions to close" : "closed #{killed.size} switchboard session(s)")
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

    # Open the config in $EDITOR (also bound to `e` in the sidebar). Scaffolds a
    # minimal stub first if there's no config yet, so there's always a real file
    # to edit — and a place to add `session_command` / per-project overrides.
    def edit_config
      Config.scaffold
      warn("could not launch editor: #{editor_command}") unless system("#{editor_command} #{Shellwords.escape(Config.path)}")
    end

    # $VISUAL/$EDITOR, treating an exported-but-empty value as unset — an empty
    # string is truthy in Ruby, so a bare `||` chain would pick it and try to
    # exec the config file itself. Falls back to vi.
    def editor_command
      [ENV["VISUAL"], ENV["EDITOR"]].find { |e| e && !e.empty? } || "vi"
    end

    def add_project(name, path, base = nil)
      return warn("usage: switchboard add <name> <path> [base-ref]") if name.nil? || path.nil?

      entry, err = Registrar.register(config, path, name: name, base: base)
      return warn(err) if err

      puts "added #{entry['name']} -> #{entry['path']}"
    end

    # Clone a repo under `projects_root` and register it (realizes the v2
    # roadmap item). Name defaults to the URL's basename.
    def clone_project(url, name = nil)
      return warn("usage: switchboard clone <git-url> [name]") if url.nil?

      entry, err = Registrar.clone(config, url, name: name)
      return warn(err) if err

      puts "cloned + added #{entry['name']} -> #{entry['path']}"
    end

    # Wire agent-state hooks into a single worktree's local settings (scoped,
    # never global). Defaults to the worktree you're standing in.
    def enable_hooks(path = nil)
      worktree = worktree_at(path) or return warn("not inside a git worktree (pass a path)")

      Hook.enable(worktree)
      puts "enabled agent-state hooks in #{worktree}"
      puts "  reporter: #{Hook.script_path}"
      puts "  restart `claude` here (or /hooks) to pick them up."
    end

    def disable_hooks(path = nil)
      worktree = worktree_at(path) or return warn("not inside a git worktree (pass a path)")

      Hook.disable(worktree)
      puts "disabled agent-state hooks in #{worktree}"
    end

    # The worktree root for a path (or cwd) — what Claude treats as the project.
    def worktree_at(path)
      dir = path ? File.expand_path(path) : Dir.pwd
      top = `git -C #{Shellwords.escape(dir)} rev-parse --show-toplevel 2>/dev/null`.strip
      top.empty? ? nil : top
    end

    def doctor
      %w[tmux git gh].each do |tool|
        puts row(!`command -v #{tool} 2>/dev/null`.strip.empty?, tool)
      end
      exists = Config.exist?
      puts row(exists, exists ? "config: #{Config.path}" : "no config — run `switchboard install`")
      doctor_install
      doctor_hooks
      doctor_sessions
    end

    # Surface orphaned sessions where the problem is detected, with the fix
    # inline (the sidebar tree is git-worktree-based, so orphan sessions never
    # show there — doctor is the discovery surface). Silent outside tmux / with
    # no server: nothing to assert.
    def doctor_sessions
      report = Reconcile.prune(config, dry_run: true)
      return unless report.reachable

      if report.orphans.empty?
        puts row(true, "no orphaned sb/ sessions")
      else
        puts row(false, "#{report.orphans.size} orphaned sb/ session(s) — run `switchboard prune` (--dry-run to preview)")
      end
    end

    # Report install wiring: PATH symlink, the tmux marker block, and a tmux new
    # enough for the session-switch refresh. Read-only; logic lives in Installer.
    def doctor_install
      puts row(Installer.linked?, "PATH symlink: #{Installer.symlink_path}")
      puts row(Installer.tmux_wired?, "tmux bindings wired (switchboard.tmux)")
      v = Installer.tmux_version
      puts row(!v.nil? && v >= 3.0, v ? "tmux #{v} (>= 3.0 for the session-switch refresh)" : "tmux not found")
    end

    # ✓/✗ status line shared by the doctor checks.
    def row(ok, msg)
      format("  %s %s", ok ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m", msg)
    end

    # Agent-state hooks are per-worktree, so report the materialized reporter and
    # whether the worktree you're standing in is wired up.
    def doctor_hooks
      script = Hook.script_path
      puts(File.exist?(script) ? "  \e[32m✓\e[0m agent-state reporter: #{script}" : "  \e[33m–\e[0m agent-state reporter not materialized yet (created on first worktree/enable-hooks)")
      here = worktree_at(nil)
      return unless here

      on = Hook.enabled?(here)
      puts(on ? "  \e[32m✓\e[0m hooks enabled here: #{here}" : "  \e[33m–\e[0m hooks off here (observation fallback) — `switchboard enable-hooks`")
    end

    def help
      puts <<~HELP
        switchboard — keyboard-only worktree switcher + creator

        usage
          switchboard              toggle the sidebar in the current tmux window
          switchboard home         attach to the persistent home session (anchor + settings)
          switchboard install      symlink onto PATH + wire tmux bindings + empty config
                                     (--no-tmux | --print-tmux | --tmux-conf PATH)
          switchboard uninstall    reverse install (symlink + tmux bindings)
          switchboard init         create an empty config (no projects yet)
          switchboard config       edit config.yml in $EDITOR (per-project settings)
          switchboard add N P [B]  register an existing repo (name, path, base ref)
          switchboard clone U [N]  clone a repo under projects_root, then register
          switchboard refresh      re-fetch PR badges from gh (normally automatic)
          switchboard enable-hooks [P]   wire agent-state dots in a worktree (default: cwd)
          switchboard disable-hooks [P]  remove them from that worktree
          switchboard prune        kill orphaned sb/ sessions (--dry-run / -n previews)
          switchboard quit         close ALL switchboard sessions (full teardown — kills the one you're in too)
          switchboard doctor       check dependencies + config
          switchboard help         show this help

        in the sidebar
          j/k ↑↓   move (projects, workspaces, and a workspace's branches)
          ↵        switch to the workspace's tmux session (or collapse a project)
          a        add a project (register a local repo or clone a URL)
          n        create a new worktree in the highlighted project
          o        open the highlighted PR in the browser (gh pr view --web)
          r        rename a workspace
          d        delete a workspace
          e        edit config.yml in $EDITOR
          q        hide the sidebar
      HELP
    end
  end
end
