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
    PULSE = 0.12   # animation frame cadence while a dot is on screen (drives the spinner/blink)
    POKE_TTL = 2   # min seconds between full reloads a session-switch poke triggers
                   # (rapid switching used to fire a git+capture-pane scan per
                   #  switch — a burst that froze the animation and hammered tmux)

    # Background PR-badge refresh (issue #19): event-driven, never blocks the UI.
    PR_DEBOUNCE = 5          # min seconds between background refreshes per project
    NAV_TTL = 45             # refresh-on-switch only if the cache is older than this
    BACKSTOP_TTL = 600       # idle fallback: refresh a project staler than this
    MAX_SPAWN_PER_RELOAD = 3 # cap backstop spawns per reload (cold-home fan-out)

    # Agent-state icons. Idle (no agent) draws a blank slot, so the column only
    # lights up when something's there. Motion lives in the GLYPH (the spinner
    # cycles, the diamond blinks) — driven by @pulse on the PULSE repaint — so
    # each state needs only a single palette ANSI color that follows the
    # terminal's light/dark theme for free. No 256-color ramp, no bg detection.
    #
    # Two forms per animated state: a bare glyph (`glyph_for`, used on the
    # reverse-video selected row where color is stripped but shape survives) and
    # a pre-built colored string (`dot_for`, normal rows — built once, no
    # per-frame allocation). Thinking cycles a braille spinner; waiting blinks a
    # filled/hollow diamond; done is a steady dot.
    SPIN_FRAMES  = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze              # thinking: bare spinner glyphs
    SPIN_COLORED = SPIN_FRAMES.map { |g| "\e[1;34m#{g}\e[0m" }.freeze # ...pre-built in blue
    WANTS_ON  = "\e[1;35m◆\e[0m"  # input needed: magenta diamond, lit
    WANTS_OFF = "\e[1;35m◇\e[0m"  # ...and hollow, the blink's off-beat
    DONE      = "\e[1;32m●\e[0m"  # green: replied, ready for you (not blocked)
    BLINK_PERIOD = 4             # @pulse ticks per blink half-cycle (~0.5s at PULSE)
    BRANCH_FG = "\e[90m"         # branch rows: bright-black, a theme-relative dim (#23)
    RELOAD_CONFIG_BYTE = "\x12"  # C-r: the dedicated post-edit "re-read config" poke (Tmux.poke_sidebar_of)

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

    # Paths whose agent state newly entered a resting state (:done/:waiting) since
    # the previous scan — i.e. a hooked agent just finished a turn. A path we've
    # never seen before (prev has no key for it) is the agent *announcing
    # presence*, not completing: SessionStart reports :done the instant a
    # freshly-created workspace's Claude is ready, and that must NOT ring the
    # completion sound (or spawn a PR refresh for a branch that has no PR yet). So
    # a first appearance only seeds the baseline; the next real Stop is the edge.
    # The caller keeps `prev` sticky across scans (on_agent_edges merges), so
    # "first appearance" means truly never-seen this process — a worktree that
    # merely aged out of the live scan keeps its baseline and still fires on
    # completion. Steady resting states and transitions back to :thinking don't
    # count either. Pure, so the edge logic is unit-testable. (Drives the sound +
    # PR-refresh triggers; issue #19.)
    def self.completion_edges(prev, now)
      now.keys.select do |path|
        %i[done waiting].include?(now[path]) && prev.key?(path) && prev[path] != now[path]
      end
    end

    # Debounce predicate: may we spawn a refresh for this project now? Yes if we
    # never have, or the last spawn is at least `window` seconds old. Pure so the
    # window logic is unit-testable without launching a process.
    def self.spawn_due?(last, now, window = PR_DEBOUNCE)
      last.nil? || now - last >= window
    end

    def initialize
      @config = Config.new
      @cursor = 0
      @offset = 0
      @nodes = []          # full tree
      @rows = []           # visible rows (collapsed projects hide their children)
      @visible_rows = []   # the on-screen slice of @rows (set in render; gates pulsing?)
      @agents = {}         # worktree path => :thinking | :done | :waiting
      @agent_state = AgentState.new
      @collapsed = Set.new # project names that are collapsed
      @ticks = 0
      @pulse = 0           # animation frame counter (spinner cycle + blink phase)
      @last_scan = nil     # monotonic time of the last agent re-scan
      @last_reload = nil   # monotonic of the last full reload (throttles switch pokes)
      @was_visible = false
      @focused = false     # is the sidebar the active pane? (cursor bar only then)
      @current_path = nil # worktree this sidebar's session is in (shown bold)
      @home = false        # is this the persistent home session? (settings base)
      @pr_spawned = {}     # project => monotonic of its last background PR refresh
      @prev_hook_states = nil # last scan's hook states; nil until the first scan
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
      reconcile_on_launch if @home && @config.prune_on_launch?
      @was_visible = true
      @last_scan = monotonic
      loop do
        render
        # Wake often enough to animate the spinner/blink, but only while a dot is
        # on screen; otherwise sit on the slow REFRESH interval. State scans stay
        # gated to REFRESH (scan_due?) so the fast frames don't hammer tmux.
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

    # A thinking/waiting dot is actually on screen and worth animating. Gated on
    # the rendered slice (not all @agents) so a collapsed or scrolled-off agent
    # never drives repaints; :done is steady and never pulses.
    def pulsing?
      return false unless @was_visible

      @visible_rows.any? { |n| %i[thinking waiting].include?(@agents[n.path]) }
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
      on_agent_edges
    rescue StandardError
      @agents = {}
    end

    def reload
      rebuild
      refresh_agents
      locate
      refresh_stale_prs
      @last_reload = monotonic
    end

    # May a session-switch poke run a full (git + capture-pane) reload now? Only
    # if we haven't within POKE_TTL — so resuming several sessions at once
    # coalesces into one rescan instead of a per-switch shell-out storm. Any
    # reload (run/tick/poke) stamps @last_reload, so a poke right after a tick
    # rebuild is suppressed too.
    def reload_due?
      @last_reload.nil? || monotonic - @last_reload >= POKE_TTL
    end

    # Once, when the HOME sidebar starts (the relaunch anchor): prune orphaned
    # sb/ sessions a deleted/moved/crashed worktree left behind, so they don't
    # silently survive a relaunch. Home is always valid, so this can't kill our
    # own pane; orphans don't affect the git-built tree, so no re-render needed.
    # Best-effort and silent — we're mid-render, and a tmux/git hiccup must never
    # stop the sidebar from drawing.
    def reconcile_on_launch
      Reconcile.prune(@config)
    rescue StandardError
      nil
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

    # --- PR badge refresh (issue #19) ----------------------------------------
    #
    # Badges are cached on disk and read instantly; these triggers keep that
    # cache fresh in the background, never blocking the paint loop. Three triggers
    # funnel into maybe_refresh_prs, which debounces per project then detaches a
    # `switchboard refresh` child that rewrites the cache and pokes us to redraw.

    # T2 — the session-change poke (\f). "You are here" stays correct on every
    # switch (cheap locate), but the heavy git+agent rescan is throttled: rapid
    # switching — resuming several sessions at once — used to fire a full reload
    # per switch, a burst of git/capture-pane shell-outs that froze the animation
    # and pounded the tmux server. The throttled switches just relocate; the next
    # tick (<= REFRESH) brings the tree current. PR refresh only when reloaded and
    # the cache is older than NAV_TTL, catching changes no local agent made.
    def reload_and_refresh
      return locate unless reload_due?

      reload
      project = @current_path && project_for_path(@current_path)
      maybe_refresh_prs(project) if project && Pr.stale?(project, NAV_TTL)
    end

    # T1 — a hooked agent just reached a resting state (finished a turn / asked
    # for input). Two consumers ride the same edge: a background PR refresh (it
    # may have pushed a branch / opened a PR) and a completion sound (the audible
    # twin of the dot). Uses the hook-only states (never the activity fallback,
    # which flips every 3s and would fire on noise). Skips the first scan — no
    # baseline to diff.
    #
    # Ordering + isolation are load-bearing: PR refresh runs first, the sound is
    # fully rescued (play_sounds_for) so a sound fault can't starve it, and
    # @prev_hook_states ALWAYS advances (ensure) so a raise here can't corrupt the
    # next edge diff — or trip refresh_agents' broad rescue into blanking the dots.
    def on_agent_edges
      now = @agent_state.last_hook_states
      if @prev_hook_states
        edges = self.class.completion_edges(@prev_hook_states, now)
        refresh_prs_for(edges)
        play_sounds_for(edges, now)
      end
    ensure
      # Merge, not replace: keep a STICKY baseline. A worktree whose hook report
      # ages out of `now` (a span longer than PRESENCE_TTL with no hook event —
      # e.g. one tool that runs longer than the TTL) must retain its last-known
      # state, or its eventual completion would read as a brand-new first
      # appearance (prev.key? false) and be silently swallowed. Stickiness also
      # keeps a restarted session quiet: SessionStart's :done matches the
      # remembered :done, so it's a non-change, not an edge. Bounded by worktrees
      # seen this process — tiny; never pruned.
      @prev_hook_states = (@prev_hook_states || {}).merge(now)
    end

    # Edge paths -> owning projects -> debounced PR refresh (deduped per project).
    def refresh_prs_for(edges)
      edges.filter_map { |path| project_for_path(path) }.uniq
           .each { |project| maybe_refresh_prs(project) }
    end

    # Edge paths -> a completion sound each. completion_edges returns distinct
    # paths, so this is one sound per [worktree, state]: every worktree's
    # completion is heard, but a worktree can't double-fire in one scan. Fully
    # rescued — a sound fault never disturbs the scan or the PR refresh above.
    def play_sounds_for(edges, now)
      edges.each { |path| Sound.play(@config.sound_for(project_for_path(path), now[path])) }
    rescue StandardError
      nil
    end

    # T3 — idle backstop: refresh any project whose badges have gone stale past
    # BACKSTOP_TTL, the safety net that stops the cache rotting for days when
    # nothing else fires. Capped at MAX_SPAWN_PER_RELOAD so opening home on a cold
    # cache doesn't launch one gh per project at once; the rest catch up later.
    def refresh_stale_prs
      @config.projects
             .map { |p| p["name"] }
             .select { |name| Pr.stale?(name, BACKSTOP_TTL) }
             .first(MAX_SPAWN_PER_RELOAD)
             .each { |name| maybe_refresh_prs(name) }
    rescue StandardError
      nil
    end

    # Fire a non-blocking PR refresh for a project, debounced per project.
    # Detaches `switchboard refresh <project> --poke <our pane>` (mirrors
    # open_pr): the gh call stays off this paint loop, and the child redraws THIS
    # sidebar — the explicit pane id survives us navigating away before gh
    # returns, where a "current pane" lookup would drift. No SWITCHBOARD_BIN
    # (launched without the wrapper) ⇒ skip; cached badges still show.
    def maybe_refresh_prs(project)
      bin = ENV["SWITCHBOARD_BIN"]
      return unless bin && project

      now = monotonic
      return unless self.class.spawn_due?(@pr_spawned[project], now)

      @pr_spawned[project] = now
      pid = Process.spawn(bin, "refresh", project, "--poke", ENV["TMUX_PANE"].to_s,
                          out: File::NULL, err: File::NULL)
      Process.detach(pid)
    rescue SystemCallError
      nil
    end

    # The project owning a worktree path (over the ws nodes), or nil.
    def project_for_path(path)
      @nodes.find { |n| n.kind == "ws" && n.path == path }&.project
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
      when "\f"                then reload_and_refresh # Ctrl-L (hook poke on switch)
      when RELOAD_CONFIG_BYTE  then reload_config_and_rebuild # Ctrl-R (post-edit reload)
      when "g"                 then @cursor = 0
      when "G"                 then @cursor = [@rows.size - 1, 0].max # clamp: empty tree → 0, not -1
      when "\e[I"              then @focused = true  # tmux focus-in: light the cursor bar
      when "\e[O"              then @focused = false # tmux focus-out: drop it
      when "q", "\x03"         then return hide # q / ^C: hide (session-wide)
      end
      true
    end

    # q/^C hides the sidebar for the WHOLE session, like prefix-s: persist the
    # intent (@sb_sidebar off) and kill every sibling window's sidebar. We spare
    # our own pane (except:) and drop out of the loop instead — letting the run
    # loop close this pane, so killing it can't abort the sweep early. Returns
    # false to signal "stop the loop." A no-op outside a session (defensive).
    def hide
      session = Tmux.session_of
      if session
        Tmux.set_sidebar_flag(session, "off")
        Tmux.reconcile_sidebars(session, false, except: ENV["TMUX_PANE"])
      end
      false
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

    # e: edit config.yml in its own pane beside the home sidebar, then return to
    # wherever we are now. Scaffold first so there's always a real file to edit.
    # The editor owns its OWN throwaway pane (not this narrow strip, not the
    # shared home shell), so there's no raw-mode dance and we just stay a live
    # tree. The editor is left UNescaped (Editor::SHELL_COMMAND) so the spawned
    # shell expands $EDITOR at run time, not this sidebar process. The trailer —
    # run in that pane after :q — switches the client back to this session and
    # pokes its sidebar to re-read config (Ctrl-R), so a changed session_command /
    # new project shows the moment you quit.
    def edit_config
      Config.scaffold
      bin    = Shellwords.escape(ENV["SWITCHBOARD_BIN"] || "switchboard")
      path   = Shellwords.escape(Config.path)
      origin = Shellwords.escape(Tmux.session_of.to_s) # the session `e` was pressed from
      Tmux.edit_in_home("#{Editor::SHELL_COMMAND} #{path}; #{bin} reload-config #{origin}")
    end

    # Re-read the (possibly hand-edited) config and rebuild — driven by the
    # dedicated post-edit poke (Ctrl-R) after `e`'s editor exits. Guard the parse:
    # the whole point of `e` is editing raw YAML, so a syntax slip is expected.
    # Keep the last good config (Config.new raises *before* the @config assignment
    # completes) and surface the error on tmux's status line — visible even when
    # focus isn't on the tree — rather than tear the sidebar down.
    def reload_config_and_rebuild
      reload_config
      reload
    rescue StandardError => e
      Tmux.notify("switchboard: config not reloaded — #{e.message}")
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
      @visible_rows = visible # the on-screen slice — pulsing? animates only for these
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
    # ws prefix is always 4 cols ("  X ") so names line up whether or not a dot is
    # present; idle leaves the dot slot blank. The dot carries the live, uncolored
    # state glyph (`glyph_for`): under the reverse-video cursor bar color is
    # stripped but the spinner/diamond/dot SHAPE survives, so the selected row
    # still shows what its agent is doing.
    def plain(node)
      case node.kind
      when "proj" then "#{@collapsed.include?(node.project) ? '▸' : '▾'} #{node.project}"
      when "ws"   then "  #{glyph_for(@agents[node.path])} #{node.name}"
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

    # Bare state glyph (no color), the single source for both render paths. The
    # spinner cycles through SPIN_FRAMES on @pulse; the diamond blinks filled/
    # hollow every BLINK_PERIOD ticks; done is steady; idle is a blank slot.
    def glyph_for(state)
      case state
      when :thinking then SPIN_FRAMES[@pulse % SPIN_FRAMES.size]
      when :waiting  then (@pulse / BLINK_PERIOD).even? ? "◆" : "◇"
      when :done     then "●"
      else " "
      end
    end

    # Colored state glyph for a normal (non-selected) row. Mirrors glyph_for in
    # palette ANSI; thinking indexes the pre-built SPIN_COLORED so there's no
    # per-frame string allocation.
    def dot_for(state)
      case state
      when :thinking then SPIN_COLORED[@pulse % SPIN_COLORED.size]
      when :waiting  then (@pulse / BLINK_PERIOD).even? ? WANTS_ON : WANTS_OFF
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
