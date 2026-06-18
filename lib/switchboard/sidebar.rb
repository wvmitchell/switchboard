# frozen_string_literal: true

require "io/console"
require "set"

module Switchboard
  # The persistent, rendered tree sidebar (no fzf). Lives in a narrow tmux
  # pane, repaints on a short interval to keep agent-activity dots live, and
  # navigates with j/k. ↵ switches to a workspace (or collapses a project);
  # n creates a worktree inline then drops you in; d deletes a workspace.
  class Sidebar
    REFRESH = 3    # seconds between agent re-scans
    TREE_TICKS = 5 # rebuild the whole tree every Nth tick (~15s) while visible

    AGENT_ON = "\e[1;32m●\e[0m"  # bright green: a live agent chat
    IDLE = "\e[90m○\e[0m"        # dim: no agent
    BRANCH_FG = "\e[38;5;245m"   # readable medium gray for branch rows

    # Key hints, spread over two readable lines. Reload isn't shown — it's
    # automatic; Ctrl-L triggers it internally (the session-switch hook poke).
    FOOTER = ["j/k move · ↵ open/collapse", "n new · r rename · d delete · q hide"].freeze

    def self.run
      new.run
    end

    def initialize
      @config = Config.new
      @cursor = 0
      @offset = 0
      @nodes = []          # full tree
      @rows = []           # visible rows (collapsed projects hide their children)
      @agents = Set.new
      @collapsed = Set.new # project names that are collapsed
      @ticks = 0
      @was_visible = false
    end

    def run
      return warn("no config — run `switchboard init`") unless Config.exist?

      setup
      pin_width
      render          # clear + show the pane instantly (empty)
      rebuild         # structure only (no per-worktree git status) — fast
      refresh_agents
      cursor_to_current # highlight the workspace this session is in
      @was_visible = true
      loop do
        render
        if IO.select([$stdin], nil, nil, REFRESH)
          break unless handle(read_key)
        else
          tick
        end
      end
    ensure
      teardown
    end

    # Idle tick. The moment this sidebar comes back on screen (visibility goes
    # false -> true, i.e. you navigated back), refresh + snap to the current
    # workspace. While it stays on screen, keep agent dots live and rebuild the
    # whole tree every TREE_TICKS. Off screen: do nothing.
    def tick
      visible = Tmux.visible?(ENV["TMUX_PANE"])
      if visible && !@was_visible
        reload_and_locate
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
      @agents = Agents.active(@nodes.select { |n| n.kind == "ws" }.map(&:path))
    rescue StandardError
      @agents = Set.new
    end

    def reload
      rebuild
      refresh_agents
    end

    # Refresh, then re-center on the workspace we're in. Called on arrival
    # (visibility transition) and by the hook poke; marks us visible so the
    # next tick doesn't treat it as a fresh arrival and re-snap.
    def reload_and_locate
      reload
      cursor_to_current
      @was_visible = true
    end

    # Snap the cursor to the workspace this session is in — matched by the
    # sidebar's working directory, so it works for any session sitting in a
    # worktree (switchboard, emdash, conductor), not just sb/* session names.
    def cursor_to_current
      here = Tmux.pane_path(ENV["TMUX_PANE"])
      return unless here

      idx = @rows.index do |n|
        n.kind == "ws" && (n.path == here || here.start_with?("#{n.path}/"))
      end
      @cursor = idx if idx
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
      when "n"                 then create
      when "d"                 then delete
      when "r"                 then rename
      when "\f"                then reload_and_locate # Ctrl-L (hook poke on switch)
      when "g"                 then @cursor = 0
      when "G"                 then @cursor = @rows.size - 1
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
                           dirty: false, pr: node.pr, base: nil, primary: false))
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
                             dirty: false, pr: nil, base: nil, primary: false))
      end
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
      Tmux.kill(Worktree.new(project: node.project, path: node.path, branch: node.branch,
                             dirty: false, pr: nil, base: nil, primary: false))
      reload
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
      answer = begin
        $stdin.getc
      rescue StandardError
        nil
      end
      print "\e[?25l"
      answer.to_s.downcase == "y"
    end

    # --- rendering -----------------------------------------------------------

    def setup
      $stdin.raw!
      print "\e[?25l\e[2J" # hide cursor, clear
    end

    def teardown
      $stdin.cooked!
      print "\e[?25h" # show cursor
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
      height = rows - FOOTER.size
      scroll(height)

      visible = @rows[@offset, height].to_a
      out = +"\e[H"
      visible.each_with_index do |node, i|
        out << "\e[#{i + 1};1H\e[K" << line(node, @offset + i == @cursor, cols)
      end
      # Erase rows left over from a previous, longer state (e.g. after a
      # collapse), then draw the footer hints on the bottom rows.
      out << "\e[#{visible.size + 1};1H\e[0J"
      FOOTER.each_with_index do |text, i|
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
      text = trunc(plain(node), cols)
      active ? "\e[7m#{text.ljust(cols)}\e[0m" : colored(node, text)
    end

    # Plain (no color) — used for the highlighted row and as the base text.
    def plain(node)
      case node.kind
      when "proj" then "#{@collapsed.include?(node.project) ? '▸' : '▾'} #{node.project}"
      when "ws"   then "  #{@agents.include?(node.path) ? '●' : '○'} #{node.name}"
      else             "     #{node.last ? '└' : '├'}#{node.active ? '●' : ' '}#{node.branch}"
      end
    end

    def colored(node, text)
      case node.kind
      when "proj" then "\e[1m#{text}\e[0m"
      when "ws"
        dot = @agents.include?(node.path) ? AGENT_ON : IDLE
        "  #{dot} #{trunc(node.name.to_s, [text.length - 4, 1].max)}"
      else "#{BRANCH_FG}#{text}\e[0m"
      end
    end

    def trunc(str, width)
      str = str.to_s
      return "" if width <= 0

      str.length > width ? "#{str[0, width - 1]}…" : str
    end
  end
end
