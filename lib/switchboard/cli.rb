# frozen_string_literal: true

require "yaml"
require "fileutils"
require "shellwords"

module Switchboard
  # Command dispatch. The `_`-prefixed commands are internal callbacks invoked
  # by fzf (preview, reload, new); the rest are the user-facing surface.
  module CLI
    module_function

    def run(argv)
      case argv.first
      when nil, "switch", "ls" then switch
      when "init"              then init
      when "config", "edit"    then edit_config
      when "add"               then add_project(argv[1], argv[2], argv[3])
      when "clone"             then clone_project(argv[1], argv[2])
      when "refresh"           then refresh
      when "enable-hooks"      then enable_hooks(argv[1])
      when "disable-hooks"     then disable_hooks(argv[1])
      when "sidebar"           then Sidebar.run
      when "toggle-sidebar"    then Tmux.toggle_sidebar
      when "poke-sidebar"      then Tmux.poke_current_sidebar
      when "_rowpreview"       then row_preview(argv[1], argv[2], argv[3])
      when "_pr"               then pr_action(argv[1], argv[2], argv[3])
      when "_new"              then new_worktree(argv[1])
      when "_lines"            then lines
      when "_refresh"          then refresh_and_lines
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

    def model
      @model ||= Model.new(config)
    end

    # Absolute path to this binary, so fzf callbacks resolve regardless of cwd
    # or how the command was invoked (bin/switchboard sets SWITCHBOARD_BIN).
    def bin
      ENV["SWITCHBOARD_BIN"] || File.expand_path($PROGRAM_NAME)
    end

    def switch
      ensure_fzf!
      return unless ensure_config!

      selection = Picker.pick(model, bin)
      return unless selection
      return new_worktree(selection[:project]) if selection[:key] == "ctrl-n"
      return if selection[:kind] == "proj" # headers aren't switch targets

      worktree = model.find(selection[:path])
      return warn("worktree not found: #{selection[:path]}") unless worktree

      Tmux.go(worktree, start: config.session_command_for(worktree.project))
    end

    # Prompt for a name and create a worktree in the given project, then switch
    # into it. Invoked by fzf's `^n` (become), so it owns the terminal.
    def new_worktree(project_name)
      project = config.project(project_name)
      return warn("unknown project: #{project_name}") unless project

      print "\nnew workspace in #{project_name} › "
      name = $stdin.gets
      return if name.nil? || name.strip.empty?

      dest = Creator.create(config, project_name, name)
      return unless dest

      Tmux.go(Worktree.new(
                  project: project_name, path: dest, branch: Git.current_branch(dest),
                  dirty: false, pr: nil, base: project["base_ref"], primary: false
                ), start: config.session_command_for(project_name))
    end

    # Preview a row, by kind. Called per-line by fzf with (kind, path, branch).
    def row_preview(kind, path, branch)
      if kind == "proj"
        project = model.project_at(path)
        puts View.project_preview(project) if project
        return
      end

      worktree = model.find(path)
      return unless worktree

      puts(kind == "br" ? View.branch_preview(worktree, branch, model) : View.preview(worktree, model))
    end

    def pr_action(path, branch, mode)
      worktree = model.find(path)
      Picker.view_pr(worktree, branch, web: mode == "web") if worktree
    end

    def lines
      Tree.lines(model).each { |row| puts row }
    end

    # Re-fetch PR badges from gh (bound to ^r), then re-emit the list.
    def refresh_and_lines
      refresh
      lines
    end

    def refresh
      config.projects.each do |p|
        Pr.refresh(p["name"], p["path"]) if Dir.exist?(p["path"])
      end
    end

    # Seed the config once from emdash's DB (read-only) if present, then warm
    # the PR cache. After this, switchboard never reads emdash again.
    def init
      if Config.exist?
        puts "config already exists: #{Config.path}"
        return
      end

      projects = seed_projects
      FileUtils.mkdir_p(File.dirname(Config.path))
      File.write(Config.path, YAML.dump("worktree_root" => Config::DEFAULT_ROOT, "projects" => projects))
      puts "wrote #{Config.path} (#{projects.size} projects)"
      puts "edit it to taste, then run `switchboard` (prefix-s)."
      refresh unless projects.empty?
    end

    # Open the config in $EDITOR (also bound to `e` in the sidebar). Writes a
    # minimal stub first if there's no config yet, so there's always a real file
    # to edit — and a place to add `session_command` / per-project overrides.
    def edit_config
      unless Config.exist?
        FileUtils.mkdir_p(File.dirname(Config.path))
        File.write(Config.path, YAML.dump("worktree_root" => Config::DEFAULT_ROOT, "projects" => []))
      end
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
      %w[fzf tmux git gh sqlite3].each do |tool|
        present = !`command -v #{tool} 2>/dev/null`.strip.empty?
        puts format("  %s %s", present ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m", tool)
      end
      puts(Config.exist? ? "  \e[32m✓\e[0m config: #{Config.path}" : "  \e[31m✗\e[0m no config — run `switchboard init`")
      doctor_hooks
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

    def ensure_fzf!
      return unless `command -v fzf 2>/dev/null`.strip.empty?

      warn "switchboard needs fzf — install it with: brew install fzf"
      exit 1
    end

    def ensure_config!
      return true if Config.exist?

      warn "No config at #{Config.path}. Run `switchboard init` to import your projects."
      false
    end

    # Internal callback helper for seeding (uses the emdash reader once).
    def seed_projects
      emdash = Emdash.new
      return [] unless emdash.available?

      emdash.projects.map { |p| { "name" => p["name"], "path" => p["path"], "base" => p["base_ref"] } }
    end

    def help
      puts <<~HELP
        switchboard — keyboard-only worktree switcher + creator

        usage
          switchboard              open the switcher (fzf)
          switchboard init         create config (imports projects from emdash once)
          switchboard config       edit config.yml in $EDITOR (per-project settings)
          switchboard add N P [B]  register an existing repo (name, path, base ref)
          switchboard clone U [N]  clone a repo under projects_root, then register
          switchboard refresh      re-fetch PR badges from gh
          switchboard enable-hooks [P]   wire agent-state dots in a worktree (default: cwd)
          switchboard disable-hooks [P]  remove them from that worktree
          switchboard doctor       check dependencies + config
          switchboard help         show this help

        in the switcher
          ↑↓   move (projects, workspaces, and a workspace's branches)
          ↵    switch to the highlighted worktree's tmux session
          ^n   create a new worktree in the highlighted project
          ^o   open the highlighted branch's PR in the browser
          ^v   view the highlighted branch's PR in the terminal
          ^r   refresh PR badges + reload
          esc  cancel
      HELP
    end
  end
end
