# frozen_string_literal: true

require "io/console"
require "set"

module Switchboard
  # The persistent, rendered tree sidebar (no fzf). Lives in a narrow tmux
  # pane, repaints on a short interval to keep agent-activity dots live, and
  # navigates with j/k. ↵ switches to a workspace (keeping the sidebar beside
  # you); n creates a worktree inline and stays put.
  class Sidebar
    REFRESH = 3 # seconds between agent re-scans

    AGENT_ON = "\e[1;32m●\e[0m" # bright green: a live agent chat
    DOT_DIRTY = "\e[33m●\e[0m"
    DOT_CLEAN = "\e[32m○\e[0m"

    def self.run
      new.run
    end

    def initialize
      @config = Config.new
      @cursor = 0
      @offset = 0
      @nodes = []
      @agents = Set.new
    end

    def run
      return warn("no config — run `switchboard init`") unless Config.exist?

      setup
      render          # clear + show the pane instantly (empty)
      rebuild         # git work (~1-2s): worktrees, dirty, branches
      refresh_agents  # then the agent scan; dots fill in
      loop do
        render
        if IO.select([$stdin], nil, nil, REFRESH)
          break unless handle(read_key)
        else
          refresh_agents
        end
      end
    ensure
      teardown
    end

    private

    # Structure + dirty + PR. Cheap-ish; the slow agent scan is separate.
    def rebuild
      @model = Model.new(@config)
      @nodes = Tree.nodes(@model)
      @cursor = [@cursor, [@nodes.size - 1, 0].max].min
    end

    # Cheap: just re-scan which worktrees have a live agent.
    def refresh_agents
      @agents = Agents.active(@nodes.select { |n| n.kind == "ws" }.map(&:path))
    rescue StandardError
      @agents = Set.new
    end

    # --- input ---------------------------------------------------------------

    def read_key
      $stdin.read_nonblock(8)
    rescue IO::WaitReadable, EOFError
      nil
    end

    # A fast key-repeat (holding j) delivers several bytes in one read, so
    # process the buffer token by token (escape sequences are 3 bytes).
    # Returns false to exit the loop (hide the sidebar).
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
      when "\r", "\n"          then switch
      when "n"                 then create
      when "r"                 then reload
      when "g"                 then @cursor = 0
      when "G"                 then @cursor = @nodes.size - 1
      when "q", "\x03"         then return false # q / ^C: hide
      end
      true
    end

    def move(delta)
      return if @nodes.empty?

      @cursor = (@cursor + delta).clamp(0, @nodes.size - 1)
    end

    def reload
      rebuild
      refresh_agents
    end

    def switch
      node = @nodes[@cursor]
      return if node.nil? || node.kind == "proj"

      Tmux.go(Worktree.new(project: node.project, path: node.path, branch: node.branch,
                           dirty: false, pr: node.pr, base: nil, primary: false))
    end

    # Inline create: prompt in this pane, make the worktree, refresh — no jump.
    def create
      node = @nodes[@cursor]
      return unless node

      rows, = winsize
      $stdin.cooked!
      print "\e[#{rows};1H\e[K\e[?25hnew workspace in #{node.project} › "
      $stdout.flush
      name = $stdin.gets
      Creator.create(@config, node.project, name) if name && !name.strip.empty?
      $stdin.raw!
      reload
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
      height = rows - 1
      scroll(height)

      out = +"\e[H"
      @nodes[@offset, height].to_a.each_with_index do |node, i|
        absolute = @offset + i
        out << "\e[#{i + 1};1H\e[K" << line(node, absolute == @cursor, cols)
      end
      out << "\e[#{rows};1H\e[K\e[2m#{trunc('j/k ↵switch n new r↺ q hide', cols)}\e[0m"
      out << "\e[0J"
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

    # Plain (no color) form — used for the highlighted row and as the base text.
    def plain(node)
      case node.kind
      when "proj" then "▾ #{node.project}"
      when "ws"   then "  #{@agents.include?(node.path) ? '●' : ' '}#{node.dirty ? '●' : '○'} #{node.name}"
      else             "     #{node.last ? '└' : '├'}#{node.active ? '●' : ' '}#{node.branch}"
      end
    end

    def colored(node, text)
      case node.kind
      when "proj" then "\e[1m#{text}\e[0m"
      when "ws"
        agent = @agents.include?(node.path) ? AGENT_ON : " "
        dot = node.dirty ? DOT_DIRTY : DOT_CLEAN
        "  #{agent}#{dot} #{trunc(node.name.to_s, text.length)}"
      else "\e[90m#{text}\e[0m"
      end
    end

    def trunc(str, width)
      str = str.to_s
      return "" if width <= 0

      str.length > width ? "#{str[0, width - 1]}…" : str
    end
  end
end
