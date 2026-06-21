# frozen_string_literal: true

require "io/console"
require "set"
require "shellwords"

module Switchboard
  # The persistent, rendered tree sidebar (no fzf). Lives in a narrow tmux
  # pane, repaints on a short interval to keep agent-activity dots live, and
  # navigates with j/k. ↵ switches to a workspace (or collapses a project);
  # a adds a project (register a local repo, or clone one); n creates a worktree
  # inline then drops you in; d deletes a workspace.
  class Sidebar
    REFRESH = 3    # seconds between agent re-scans
    TREE_TICKS = 5 # rebuild the whole tree every Nth tick (~15s) while visible
    PULSE = 0.45   # repaint cadence while an agent is thinking (drives the breathe)

    # Agent-state dots. Idle (no agent) draws nothing — just a blank slot — so
    # the column only lights up when something's actually there.
    DONE = "\e[1;32m●\e[0m"  # green: replied, ready for you (not blocked)
    WANTS = "\e[1;35m●\e[0m" # magenta: blocked, wants your input
    # Thinking breathes through a blue ramp (dim->bright->dim). We drive it
    # ourselves on the PULSE repaint so it works on any terminal — no reliance
    # on the blink attribute, which tmux passes through but many terminals drop.
    THINK_FRAMES = %w[19 20 27 33 27 20].map { |c| "\e[1;38;5;#{c}m●\e[0m" }.freeze
    BRANCH_FG = "\e[38;5;245m"   # readable medium gray for branch rows

    # Key hints, spread over readable lines (kept within the pin width). Reload
    # isn't shown — it's automatic; Ctrl-L triggers it internally (the
    # session-switch hook poke).
    FOOTER = ["j/k move · ↵ open/collapse",
              "a add · n new · o PR · r rename",
              "d delete · e edit · q hide"].freeze

    # In the home session the sidebar is the switchboard base, not a workspace's
    # strip — label it as such and foreground the management keys. Same line
    # count as FOOTER so the render geometry is unchanged.
    HOME_FOOTER = ["switchboard · home",
                   "a add project · e settings",
                   "j/k move · ↵ open · q hide"].freeze

    def self.run
      new.run
    end

    def initialize
      @config = Config.new
      @cursor = 0
      @offset = 0
      @nodes = []          # full tree
      @rows = []           # visible rows (collapsed projects hide their children)
      @agents = {}         # worktree path => :thinking | :done | :waiting
      @agent_state = AgentState.new
      @collapsed = Set.new # project names that are collapsed
      @ticks = 0
      @pulse = 0           # animation frame counter for the thinking breathe
      @last_scan = nil     # monotonic time of the last agent re-scan
      @was_visible = false
      @focused = false     # is the sidebar the active pane? (cursor bar only then)
      @current_path = nil # worktree this sidebar's session is in (shown bold)
      @home = false        # is this the persistent home session? (settings base)
    end

    def run
      return warn("no config — run `switchboard init`") unless Config.exist?

      setup
      Tmux.enable_focus_events # so focus in/out reaches us for an instant dim
      @home = Tmux.session_of == Tmux::HOME # stable for this pane's lifetime
      @focused = Tmux.focused?(ENV["TMUX_PANE"])
      pin_width
      render  # clear + show the pane instantly (empty)
      reload  # rebuild + agents + locate "you are here"
      @was_visible = true
      @last_scan = monotonic
      loop do
        render
        # Wake often enough to animate the thinking breathe, but only while one
        # is on screen; otherwise sit on the slow REFRESH interval. State scans
        # stay gated to REFRESH (scan_due?) so the fast frames don't hammer tmux.
        if IO.select([$stdin], nil, nil, frame_timeout)
          break unless handle(read_key)
        else
          @pulse += 1
          tick if scan_due?
        end
      end
    ensure
      teardown
    end

    def frame_timeout
      pulsing? ? PULSE : REFRESH
    end

    # A thinking dot is on screen and worth animating.
    def pulsing?
      @was_visible && @agents.value?(:thinking)
    end

    # True at most once per REFRESH seconds — throttles the actual agent scan
    # even when the loop is spinning fast to drive the pulse.
    def scan_due?
      now = monotonic
      return false if @last_scan && now - @last_scan < REFRESH

      @last_scan = now
      true
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Idle tick. When this sidebar comes back on screen (visibility false ->
    # true, i.e. you navigated back) refresh the tree. While it stays on screen,
    # keep agent dots live and rebuild every TREE_TICKS. Off screen: nothing.
    def tick
      @focused = Tmux.focused?(ENV["TMUX_PANE"]) # authoritative if focus-events are off
      visible = Tmux.visible?(ENV["TMUX_PANE"])
      if visible && !@was_visible
        reload
      elsif visible
        pin_width
        @ticks += 1
        if @ticks >= TREE_TICKS
          @ticks = 0
          reload
        else
          refresh_agents
        end
      end
      @was_visible = visible
    end

    private

    def pin_width
      Tmux.pin(ENV["TMUX_PANE"])
    end

    # Structure + PR badges, NOT per-worktree dirty (16 git-status calls would
    # stall the paint). Fast.
    def rebuild
      @model = Model.new(@config, with_dirty: false)
      @nodes = Tree.nodes(@model)
      recompute_rows
    end

    # Visible rows = all nodes, minus the children of collapsed projects.
    def recompute_rows
      @rows = @nodes.reject { |n| n.kind != "proj" && @collapsed.include?(n.project) }
      @cursor = @cursor.clamp(0, [@rows.size - 1, 0].max)
    end

    def refresh_agents
      @agents = @agent_state.scan(@nodes.select { |n| n.kind == "ws" }.map(&:path))
    rescue StandardError
      @agents = {}
    end

    def reload
      rebuild
      refresh_agents
      locate
    end

    # Which workspace is this sidebar's session in? Matched by the sidebar's
    # working directory, so it covers any session in a worktree (switchboard,
    # emdash, conductor). Shown in bold; independent of the navigation cursor.
    def locate
      here = Tmux.pane_path(ENV["TMUX_PANE"])
      @current_path = here && @nodes.select { |n| n.kind == "ws" }
                                    .map(&:path)
                                    .select { |p| here == p || here.start_with?("#{p}/") }
                                    .max_by(&:length)
    end

    def current
      @rows[@cursor]
    end

    # --- input ---------------------------------------------------------------

    def read_key
      $stdin.read_nonblock(8)
    rescue IO::WaitReadable, EOFError
      nil
    end

    # A fast key-repeat (holding j) delivers several bytes in one read, so
    # process the buffer token by token (escape sequences are 3 bytes).
    def handle(buf)
      return true if buf.nil? || buf.empty?

      keep = true
      buf = buf.dup
      until buf.empty?
        token = buf.start_with?("\e") ? buf.slice!(0, 3) : buf.slice!(0, 1)
        keep = false unless dispatch(token)
      end
      keep
    end

    def dispatch(key)
      case key
      when "j", "\e[B", "\x0E" then move(1)   # down (j / ↓ / ^N)
      when "k", "\e[A", "\x10" then move(-1)  # up   (k / ↑ / ^P)
      when "\r", "\n"          then enter
      when "a"                 then add
      when "n"                 then create
      when "o", "\x0F"         then open_pr # open the PR in the browser (o / ^O)
      when "d"                 then delete
      when "r"                 then rename
      when "e"                 then edit_config
      when "\f"                then reload # Ctrl-L (hook poke on switch)
      when "g"                 then @cursor = 0
      when "G"                 then @cursor = @rows.size - 1
      when "\e[I"              then @focused = true  # tmux focus-in: light the cursor bar
      when "\e[O"              then @focused = false # tmux focus-out: drop it
      when "q", "\x03"         then return false # q / ^C: hide
      end
      true
    end

    def move(delta)
      return if @rows.empty?

      @cursor = (@cursor + delta).clamp(0, @rows.size - 1)
    end

    # ↵: collapse/expand a project header, or switch to a workspace/branch.
    def enter
      node = current
      return unless node

      node.kind == "proj" ? toggle_collapse(node.project) : switch(node)
    end

    def toggle_collapse(project)
      @collapsed.include?(project) ? @collapsed.delete(project) : @collapsed.add(project)
      recompute_rows
    end

    def switch(node)
      Tmux.go(Worktree.new(project: node.project, path: node.path, branch: node.branch,
                           dirty: false, pr: node.pr, base: nil, primary: false),
              start: @config.session_command_for(node.project))
    end

    # o: open the highlighted workspace/branch's PR in the browser. Runs in the
    # worktree dir so `gh` infers the repo. Detached, not `system`: `gh pr view
    # --web` hits the API to resolve the PR before opening the browser, so a slow
    # network would otherwise freeze the paint loop. spawn raises (unlike system)
    # if the dir or `gh` is missing, so swallow that to keep the UI alive. No PR
    # for the branch ⇒ gh exits quietly and nothing opens.
    def open_pr
      node = current
      return unless node && node.kind != "proj"

      branch = node.branch.to_s
      return if branch.empty? || branch.start_with?("-") # never hand a dash-led name to gh as a flag

      pid = Process.spawn("gh", "pr", "view", branch, "--web", chdir: node.path, out: File::NULL, err: File::NULL)
      Process.detach(pid)
    rescue SystemCallError
      nil
    end

    # Prompt inline, create the worktree (quiet), then drop into it.
    def create
      node = current
      return unless node

      rows, = winsize
      $stdin.cooked!
      print "\e[#{rows};1H\e[K\e[?25hnew workspace in #{node.project} › "
      $stdout.flush
      name = $stdin.gets
      if name && !name.strip.empty?
        print "\r\ncreating…"
        $stdout.flush
        dest = Creator.create(@config, node.project, name)
      end
      $stdin.raw!

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
    end

    # Re-read config from disk so a freshly added project shows on the next
    # rebuild (@config is otherwise cached for the session).
    def reload_config
      @config = Config.new
    end

    # e: edit config.yml in $EDITOR, then reload — a changed session_command or
    # a newly added project shows on the next paint. The editor takes over the
    # pane, so drop raw mode and hand it a clean screen; the ensure restores raw
    # mode and our cursor even if the editor dies, so we can't strand the pane.
    def edit_config
      # $VISUAL/$EDITOR, treating exported-but-empty as unset ("" is truthy in
      # Ruby, so a bare `||` chain would pick it and exec the config file).
      editor = [ENV["VISUAL"], ENV["EDITOR"]].find { |e| e && !e.empty? } || "vi"
      $stdin.cooked!
      print "\e[?25h\e[2J\e[H" # show cursor, clear, home
      $stdout.flush
      system("#{editor} #{Shellwords.escape(Config.path)}")
    ensure
      $stdin.raw!
      print "\e[?25l\e[?1004h\e[2J" # hide cursor, re-arm focus events (editor cleared them), clear
      reload_after_edit
    end

    # Re-read the (possibly hand-edited) config and rebuild. Guard the parse:
    # the whole point of `e` is editing raw YAML, so a syntax slip is expected —
    # keep the last good config and flash the error rather than let an unrescued
    # Config.new (YAML.safe_load_file raises on bad YAML) tear down the sidebar.
    def reload_after_edit
      reload_config
      reload
    rescue StandardError => e
      flash("config not reloaded: #{e.message}")
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

    # Rename a workspace: move its worktree directory (the display name). The
    # branch is left as-is so its PR link and git identity stay intact.
    def rename
      node = current
      return unless node && node.kind == "ws"

      project = @config.project(node.project)
      return unless project

      rows, = winsize
      $stdin.cooked!
      print "\e[#{rows};1H\e[K\e[?25hrename #{File.basename(node.path)} to › "
      $stdout.flush
      newname = $stdin.gets
      $stdin.raw!
      return reload if newname.nil? || newname.strip.empty?

      dest = File.join(File.dirname(node.path), Creator.sanitize(newname))
      return reload unless Git.move_worktree(project["path"], node.path, dest)

      # Rename the session in place (don't kill it) so a running agent and its
      # conversation survive. The moved dir keeps its inode, so cwd follows.
      old_name = Tmux.session_name(Worktree.new(project: node.project, path: node.path))
      new_name = Tmux.session_name(Worktree.new(project: node.project, path: dest))
      Tmux.rename_session(old_name, new_name)
      reload
    end

    # Single-key y/N confirmation on the bottom row.
    def confirm(message)
      rows, = winsize
      print "\e[#{rows};1H\e[K\e[?25h#{message} [y/N] "
      $stdout.flush
      answer = read_char
      print "\e[?25l"
      answer.to_s.downcase == "y"
    end

    # Cooked-mode line prompt on the bottom row. Returns the entered text
    # (stripped) or nil. Raw mode and the hidden cursor are restored in an
    # ensure, so a read that raises can't strand the sidebar in cooked mode.
    def prompt_line(label)
      rows, = winsize
      $stdin.cooked!
      print "\e[#{rows};1H\e[K\e[?25h#{label} › "
      $stdout.flush
      $stdin.gets&.strip
    rescue StandardError
      nil
    ensure
      $stdin.raw!
      print "\e[?25l"
    end

    # An empty prompt result — nil (read failed) or "" (bare enter) — means cancel.
    def blank_input?(text)
      text.nil? || text.empty?
    end

    # Surface an error on the bottom row and wait for a keypress, so it's
    # readable before the next repaint wipes it.
    def flash(message)
      rows, cols = winsize
      print "\e[#{rows};1H\e[K\e[31m#{trunc(message, cols - 11)}\e[0m — any key "
      $stdout.flush
      read_char
    end

    # One key in raw mode (nil if the read fails).
    def read_char
      $stdin.getc
    rescue StandardError
      nil
    end

    # --- rendering -----------------------------------------------------------

    def setup
      $stdin.raw!
      # ?1004h opts this pane into focus reporting — without it tmux won't send
      # the focus in/out escapes (\e[I / \e[O) we use to dim instantly.
      print "\e[?25l\e[?1004h\e[2J" # hide cursor, request focus events, clear
    end

    def teardown
      $stdin.cooked!
      print "\e[?1004l\e[?25h" # stop focus events, show cursor
    rescue StandardError
      nil
    end

    def winsize
      $stdout.winsize
    rescue StandardError
      [40, 40]
    end

    def render
      rows, cols = winsize
      foot = @home ? HOME_FOOTER : FOOTER
      height = rows - foot.size
      scroll(height)

      visible = @rows[@offset, height].to_a
      out = +"\e[H"
      visible.each_with_index do |node, i|
        out << "\e[#{i + 1};1H\e[K" << line(node, @offset + i == @cursor, cols)
      end
      # Erase rows left over from a previous, longer state (e.g. after a
      # collapse), then draw the footer hints on the bottom rows.
      out << "\e[#{visible.size + 1};1H\e[0J"
      foot.each_with_index do |text, i|
        out << "\e[#{height + 1 + i};1H\e[K\e[2m#{trunc(text, cols)}\e[0m"
      end
      $stdout.write(out)
    end

    def scroll(height)
      @offset = @cursor if @cursor < @offset
      @offset = @cursor - height + 1 if @cursor >= @offset + height
      @offset = 0 if @offset.negative?
    end

    def line(node, active, cols)
      # PR identifier ("#12") rendered flush right; reserve its width (plus a
      # gap) so the name truncates to fit rather than overrunning the badge.
      # Projects carry no PR, so they get the full width.
      id = node.kind == "proj" ? "" : View.pr_identifier(node.pr)
      left_cols = id.empty? ? cols : [cols - id.length - 1, 1].max
      text = trunc(plain(node), left_cols)

      # The reverse-video cursor bar only when the sidebar is the focused pane;
      # off-focus the cursor row renders like any other, so the bright bar never
      # tugs at your eye while you're working in the pane beside it. The badge
      # goes plain here so it reads under the inverted bar.
      if active && @focused
        bar = id.empty? ? text : "#{text.ljust(left_cols)} #{id}"
        return "\e[7m#{bar.ljust(cols)}\e[0m"
      end

      body = colored(node, text, current: node.kind == "ws" && node.path == @current_path)
      return body if id.empty?

      # `colored` preserves `text`'s visible width, so pad off the plain length.
      pad = [cols - text.length - id.length, 1].max
      "#{body}#{' ' * pad}#{View.pr_tag(node.pr)}"
    end

    # Plain (no color) — used for the highlighted row and as the base text. The
    # ws prefix is always 4 cols ("  ● ") so names line up whether or not a dot
    # is present; idle just leaves the dot slot blank.
    def plain(node)
      case node.kind
      when "proj" then "#{@collapsed.include?(node.project) ? '▸' : '▾'} #{node.project}"
      when "ws"   then "  #{@agents.key?(node.path) ? '●' : ' '} #{node.name}"
      else             "     #{node.last ? '└' : '├'}#{node.active ? '●' : ' '}#{node.branch}"
      end
    end

    def colored(node, text, current: false)
      case node.kind
      when "proj" then "\e[1m#{text}\e[0m"
      when "ws"
        dot = dot_for(@agents[node.path])
        name = trunc(node.name.to_s, [text.length - 4, 1].max)
        name = "\e[36m#{name}\e[0m" if current # "you are here" — cyan, matching the prompt's directory color
        "  #{dot} #{name}"
      else "#{BRANCH_FG}#{text}\e[0m"
      end
    end

    # State -> dot. Idle (nil) is a blank slot; thinking breathes via @pulse.
    def dot_for(state)
      case state
      when :thinking then THINK_FRAMES[@pulse % THINK_FRAMES.size]
      when :waiting  then WANTS
      when :done     then DONE
      else " "
      end
    end

    def trunc(str, width)
      str = str.to_s
      return "" if width <= 0

      str.length > width ? "#{str[0, width - 1]}…" : str
    end
  end
end
