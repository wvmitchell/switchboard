# frozen_string_literal: true

module Switchboard
  # Command dispatch. The `_`-prefixed commands are internal callbacks invoked
  # by fzf (preview + reload); the rest are the user-facing surface.
  module CLI
    module_function

    def run(argv)
      case argv.first
      when nil, "switch", "ls" then switch
      when "_rowpreview"       then row_preview(argv[1], argv[2], argv[3])
      when "_pr"               then pr_action(argv[1], argv[2], argv[3])
      when "_lines"            then lines
      when "doctor"            then doctor
      when "version", "-v", "--version" then puts("switchboard #{VERSION}")
      when "help", "-h", "--help"       then help
      else
        warn "unknown command: #{argv.first}"
        help
        exit 1
      end
    end

    def model
      @model ||= Model.new
    end

    # Absolute path to this binary, so fzf callbacks resolve regardless of cwd
    # or how the command was invoked (bin/switchboard sets SWITCHBOARD_BIN from
    # __FILE__; the $0 fallback only matters when loaded some other way).
    def bin
      ENV["SWITCHBOARD_BIN"] || File.expand_path($PROGRAM_NAME)
    end

    def switch
      ensure_fzf!
      selection = Picker.pick(model, bin)
      return unless selection
      return if selection[:kind] == "proj" # headers aren't switch targets (v1: create here)

      worktree = model.find(selection[:path])
      return warn("worktree not found: #{selection[:path]}") unless worktree

      Tmux.open(worktree)
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

    def doctor
      %w[fzf tmux git gh sqlite3].each do |tool|
        present = !`command -v #{tool} 2>/dev/null`.strip.empty?
        puts format("  %s %s", present ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m", tool)
      end
      db = Emdash.db_path
      puts(db ? "  \e[32m✓\e[0m emdash db: #{db}" : "  \e[31m✗\e[0m emdash db not found")
    end

    def ensure_fzf!
      return unless `command -v fzf 2>/dev/null`.strip.empty?

      warn "switchboard needs fzf — install it with: brew install fzf"
      exit 1
    end

    def help
      puts <<~HELP
        switchboard — keyboard-only worktree switcher

        usage
          switchboard           open the switcher (fzf)
          switchboard doctor    check dependencies
          switchboard help      show this help

        in the switcher
          ↑↓   move (workspaces, and a workspace's branches inline)
          ↵    switch to the highlighted worktree's tmux session
          ^o   open the highlighted branch's PR in the browser
          ^v   view the highlighted branch's PR in the terminal
          ^r   reload the list
          esc  cancel
      HELP
    end
  end
end
