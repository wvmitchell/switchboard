# frozen_string_literal: true

require "shellwords"

module Switchboard
  # The switcher itself: feeds worktree lines to fzf, with a live preview that
  # calls back into this same binary. Returns the chosen worktree path.
  module Picker
    module_function

    def pick(model, bin)
      rows = Tree.lines(model)
      if rows.empty?
        warn "No worktrees found. Is emdash set up and are the project repos present on disk?"
        return nil
      end

      selected = IO.popen(fzf_command(bin), "r+") do |io|
        io.write(rows.join("\n"))
        io.close_write
        io.read
      end

      return nil if selected.nil? || selected.strip.empty?

      # fields: visible \t path \t branch \t kind \t project
      fields = selected.split("\t")
      { path: fields[1], branch: fields[2], kind: fields[3]&.strip }
    end

    def fzf_command(bin)
      escaped = Shellwords.escape(bin)
      [
        "fzf",
        "--ansi",
        # Render top-down so the project -> workspace -> branch tree reads in
        # input order; the default layout is bottom-up and inverts the nesting.
        "--layout=reverse",
        "--delimiter", "\t",
        "--with-nth", "1",
        "--no-multi",
        "--prompt", "switch › ",
        "--header", "↵ switch    ^o PR in browser    ^v PR in terminal    ^r reload    esc cancel",
        # preview args: kind, path, branch (hidden fields 4, 2, 3)
        "--preview", "#{escaped} _rowpreview {4} {2} {3}",
        "--preview-window", "right,55%,border-left,wrap",
        "--bind", "ctrl-r:reload(#{escaped} _lines)",
        "--bind", "ctrl-o:execute-silent(#{escaped} _pr {2} {3} web)",
        "--bind", "ctrl-v:execute(#{escaped} _pr {2} {3} term)",
        # preview scrolling on keys that pass through tmux reliably
        "--bind", "pgup:preview-page-up,pgdn:preview-page-down",
        "--bind", "shift-up:preview-up,shift-down:preview-down"
      ]
    end

    # Keyboard-native PR viewing: `gh pr view` renders in the terminal; --web
    # opens the browser. cwd = worktree so gh infers the right repo.
    def view_pr(worktree, branch, web:)
      return if branch.nil? || branch.strip.empty?

      args = ["gh", "pr", "view", branch]
      args << "--web" if web
      ok = system(*args, chdir: worktree.path)

      # In terminal mode (has a tty) pause so the result is readable; in --web
      # mode the bind is execute-silent, so never block.
      return if ok || web

      print "\nNo PR for #{branch} (or gh failed). Press enter… "
      $stdin.gets
    end
  end
end
