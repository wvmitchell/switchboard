# frozen_string_literal: true

require "io/console"
require "set"

module Switchboard
  # The persistent, rendered tree sidebar (no fzf). Lives in a narrow tmux
  # pane, repaints on a short interval to keep agent-activity dots live, and
  # navigates with j/k. ↵ switches to a workspace (keeping the sidebar beside
  # you); n creates a worktree inline then drops you into it.
  class Sidebar
    REFRESH = 3 # seconds between agent re-scans

    AGENT_ON = "\e[1;32m●\e[0m"    # bright green: a live agent chat
    IDLE = "\e[90m○\e[0m"          # dim: no agent
    BRANCH_FG = "\e[38;5;245m"     # readable medium gray for branch rows

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
      pin_width
      render          # clear + show the pane instantly (empty)
      rebuild         # structure only (no per-worktree git status) — fast
      refresh_agents  # agent dots
      loop do
        render
        if IO.select([$stdin], nil, nil, REFRESH)
          break unless handle(read_key)
        else
          refresh_agents
          pin_width # re-assert width against terminal/window resizes
        end
      end
    ensure
      teardown
    end

    # Keep our own pane at the fixed sidebar width.
    def pin_width
      Tmux.pin(ENV["TMUX_PANE"])
    end

    private

    # Structure + PR badges, NOT per-worktree dirty (that's 16 git-status calls
    # and would stall the paint / make switching flicker). Fast.
    def rebuild
      @model = Model.new(@config, with_dirty: false)
      @nodes = Tree.nodes(@model)
      @cursor = [@cursor, [@nodes.size - 1, 0].max].min
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

    def switch
      node = @nodes[@cursor]
      return if node.nil? || node.kind == "proj"

      Tmux.go(Worktree.new(project: node.project, path: node.path, branch: node.branch,
                           dirty: false, pr: node.pr, base: nil, primary: false))
    end

    # Prompt inline, create the worktree (quiet), then drop into it.
    def create
      node = @nodes[@cursor]
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

    # Plain (no color) — used for the highlighted row and as the base text.
    def plain(node)
      case node.kind
      when "proj" then "▾ #{node.project}"
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
