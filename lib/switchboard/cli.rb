# frozen_string_literal: true

require "yaml"
require "fileutils"
require "shellwords"
require "json"

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
      when "install"           then install(argv.drop(1))
      when "uninstall"         then uninstall(argv.drop(1))
      when "init"              then init
      when "config", "edit"    then edit_config
      when "add"               then add_project(argv[1], argv[2], argv[3])
      when "remove", "rm"      then remove_project(argv[1])
      when "clone"             then clone_project(argv[1], argv[2])
      when "refresh"           then refresh(*refresh_args(argv))
      when "enable-hooks"      then enable_hooks(argv[1])
      when "disable-hooks"     then disable_hooks(argv[1])
      when "rename"            then exit(1) unless rename(argv[1])
      when "rename-nudge"      then rename_nudge(argv.drop(1))
      when "sound"             then play_sound(argv[1])
      when "sidebar"           then Sidebar.run
      when "poke-sidebar"      then Tmux.poke_current_sidebar
      when "reload-config"     then reload_config_poke(argv[1])
      when "sidebar-sync"      then Tmux.sidebar_sync(argv[1])
      when "poke-window"       then Tmux.poke_window(argv[1])
      when "tmux-bind"         then Installer.apply_keybindings
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
      AgentState.clear_all # killing every agent makes their last hook state stale — drop it now
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

    # Wire agent-state hooks into a single worktree's local agent settings
    # (scoped, never global). Defaults to the worktree you're standing in.
    def enable_hooks(path = nil)
      worktree = worktree_at(path) or return warn("not inside a git worktree (pass a path)")

      AgentHooks.enable(worktree) # claude, per-worktree
      puts "enabled agent-state hooks in #{worktree}"
      puts "  reporter: #{HookFile.script_path}"
      puts "  claude: #{ClaudeHook.settings_path(worktree)} — restart `claude` here (or /hooks) to pick it up"
      # Codex is GLOBAL (one ~/.codex/config.toml block — codex can't see project hooks in
      # linked worktrees). Re-ensure it if already opted in (self-heal); else point at install.
      if CodexHook.installed?
        CodexHook.install_global
        puts "  codex:  #{CodexHook.config_path} (global) — run `/hooks` in codex to approve"
      else
        puts "  codex:  not enabled — `switchboard install --codex-hooks` adds the global block"
      end
    end

    def disable_hooks(path = nil)
      worktree = worktree_at(path) or return warn("not inside a git worktree (pass a path)")

      AgentHooks.disable(worktree) # claude, per-worktree
      puts "disabled agent-state hooks in #{worktree}"
      puts "  (codex hooks are global — `switchboard uninstall` removes them)" if CodexHook.installed?
    end

    # The worktree root for a path (or cwd) — what agent hooks treat as the project.
    def worktree_at(path)
      dir = path ? File.expand_path(path) : Dir.pwd
      top = `git -C #{Shellwords.escape(dir)} rev-parse --show-toplevel 2>/dev/null`.strip
      top.empty? ? nil : top
    end

    # Rename the workspace the cwd is in (issue #42) — the agent verb: a running
    # agent has the best context for a good name, so let it (re)name its own live
    # workspace. Resolves the workspace from cwd, refuses the primary checkout,
    # then runs the shared Rename core (dir move + bridge + session rename).
    # Returns true on success so `run` can exit non-zero on failure — an agent's
    # `switchboard rename x && cd …` must not proceed past a failed rename.
    def rename(newname)
      wt = current_worktree
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
    end

    # Agent hook entry (#92): nudge the agent to `switchboard rename` while this
    # workspace still has a generated placeholder name and `auto_rename` is on. Two events
    # dispatch here, selected by `--stop`:
    #   • SessionStart (no flag) — print an `additionalContext` instruction (the soft
    #     plant), gated on the event source. Rides alongside the sh state reporter.
    #   • Stop (`--stop`) — see rename_nudge_stop: this command IS the Stop state reporter
    #     AND the backstop (the sh reporter is off the Stop event, hook.rb), so it can
    #     report `thinking` when it blocks instead of a racing `done`.
    # The worktree is resolved from the hook's cwd (via `git rev-parse --show-toplevel`,
    # so a subdir/bridge/moved path resolves) — NOT Dir.pwd, which the hook process
    # doesn't reliably inherit.
    #
    # Two hard contracts (a hook runs on the critical path of a session boundary):
    # ALWAYS exit 0, and print ONLY the JSON or nothing. A stray byte on stdout — a
    # warning, a partial object, a backtrace — can poison an agent even at exit 0, so the
    # whole body is rescued to silence and nothing else writes stdout.
    def rename_nudge(args = [])
      payload = parse_hook_stdin
      cwd = payload["cwd"]
      cwd = Dir.pwd unless cwd.is_a?(String) && !cwd.strip.empty?

      return rename_nudge_stop(payload, cwd) if args.include?("--stop")

      wt = current_worktree(cwd)
      return if wt.nil? || wt.primary # not a managed worktree, or the trunk checkout

      leaf = File.basename(wt.path)
      return unless RenameNudge.decide(auto_rename: config.auto_rename_for(wt.project),
                                       placeholder: Placeholder.generated?(leaf),
                                       source: payload["source"])

      puts RenameNudge.context_json(leaf)
    rescue StandardError
      nil # a hook must never error a session boundary; emit nothing on any fault
    end

    # The Stop event, unified: report the agent state ourselves (the job the sh reporter
    # does on every OTHER event) AND, when gated, block. Stop hooks run in parallel with
    # no ordering, so we can't have a sibling sh reporter writing `done` while we block —
    # it could record a forced-to-continue agent as finished and ring a false completion.
    # So we report `thinking` when blocking (accurate — the agent IS about to keep going)
    # and `done` otherwise. State is ALWAYS reported (every hooked worktree, even when not
    # a placeholder / auto_rename off), since the dot depends on it. `stop_block_leaf` is
    # fully rescued ⇒ any fault degrades to a plain `done`, never trapping the agent.
    def rename_nudge_stop(payload, cwd)
      leaf = stop_block_leaf(payload, cwd)
      report_stop_state(leaf ? "thinking" : "done")
      puts RenameNudge.stop_json(leaf) if leaf
    end

    # The placeholder leaf this Stop should block on, or nil if it should NOT block (the
    # common case — and the safe default on any fault, so a glitch never blocks).
    def stop_block_leaf(payload, cwd)
      wt = current_worktree(cwd)
      return nil if wt.nil? || wt.primary

      leaf = File.basename(wt.path)
      return nil unless RenameNudge.decide_stop(auto_rename: config.auto_rename_for(wt.project),
                                                placeholder: Placeholder.generated?(leaf),
                                                stop_hook_active: payload["stop_hook_active"])

      leaf
    rescue StandardError
      nil
    end

    # Report agent state by running the SAME sh reporter every other event uses. The
    # child inherits our cwd (the hook's invocation dir), so its `pwd -P`/cksum key
    # matches the file the other events write — no Ruby-side key reproduction, and its
    # stdout is suppressed so only our block JSON (if any) reaches the agent.
    def report_stop_state(state)
      system(HookFile.script_path, state, out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    # The SessionStart event JSON from stdin, or {} on anything empty/unreadable.
    def parse_hook_stdin
      raw = $stdin.read
      raw.to_s.strip.empty? ? {} : (JSON.parse(raw) || {})
    rescue StandardError
      {}
    end

    # The workspace the cwd is in, as a Worktree (project, path, primary), or nil
    # if cwd isn't inside any registered project's worktree. Reuses Model (same
    # tree the sidebar navigates). Both sides are realpath-normalized so a match
    # holds across macOS symlinked roots (/tmp, symlinked HOME); `primary` is
    # re-derived from realpath too, not trusted from Model's raw string compare.
    def current_worktree(at = nil)
      top = worktree_at(at)
      real = top && real_path(top)
      return nil unless real

      Model.new(config, with_dirty: false).projects.each do |project|
        project.worktrees.each do |w|
          wp = real_path(w.path)
          next unless wp == real

          w.primary = wp == real_path(project.path)
          return w
        end
      end
      nil
    end

    # File.realpath, degrading to nil (not the raw path, unlike the realpath
    # helpers in reconcile/attention/agent_state) on a vanished path: a cwd that
    # no longer resolves must match NO worktree, so `current_worktree` returns nil
    # rather than risk a bogus match against an unresolved string.
    def real_path(path)
      File.realpath(path)
    rescue StandardError
      nil
    end

    # cwd relative to a worktree root ("" when standing at the root), so the
    # rename cd hint can return the user to the same subdir under the new path.
    def subpath_in(root)
      cwd = real_path(Dir.pwd)
      base = real_path(root)
      return "" unless cwd && base && cwd.start_with?("#{base}/")

      cwd[(base.length + 1)..]
    end

    # Play a configured sound, for trying audio out / picking sounds (and showing
    # it off). `switchboard sound [done|waiting]` — defaults to done. Uses the
    # GLOBAL sound config (no project context), blocks until it finishes, and
    # reports WHY nothing played (muted / no player / unresolvable spec) so a
    # silent run is never mistaken for success.
    def play_sound(state = nil)
      state = state || "done"
      return warn("usage: switchboard sound [done|waiting]") unless %w[done waiting].include?(state)

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

    def doctor
      %w[tmux git gh].each do |tool|
        puts row(!`command -v #{tool} 2>/dev/null`.strip.empty?, tool)
      end
      exists = Config.exist?
      puts row(exists, exists ? "config: #{Config.path}" : "no config — run `switchboard install`")
      doctor_install
      doctor_sidebar_keys
      doctor_hooks
      doctor_prs
      doctor_sounds
      doctor_sessions
      doctor_orphan_sidebars
    end

    # Surface a bad `sidebar_keys` remap (issue #108) so a binding that didn't take
    # isn't a silent mystery — the sidebar degrades to defaults rather than erroring,
    # so doctor is where it shows. Two cases: a value that isn't a single printable
    # key (fell back to the default), and an action whose key clashes with another's
    # (the loser is left unbound — its arrow/ctrl aliases still fire). Silent for the
    # default layout (nothing remapped); a clean customization gets one confirming row.
    def doctor_sidebar_keys
      # Capture [action, raw] pairs in one lookup each, skipping unset actions.
      overridden = Keymap::ACTIONS.filter_map do |a|
        raw = config.raw_sidebar_key(a.name)
        [a, raw] unless raw.nil?
      end
      return if overridden.empty?

      ok = true
      overridden.each do |a, raw|
        next if config.valid_sidebar_key?(raw)

        ok = false
        puts "  \e[33m–\e[0m sidebar_keys.#{a.name} #{raw.inspect} isn't a single printable key — using #{a.default.inspect}"
      end
      Keymap.collisions(config).each do |c|
        ok = false
        puts "  \e[33m–\e[0m sidebar_keys.#{c[:action]} (#{c[:key].inspect}) clashes with #{c[:winner]} — left unbound; its arrow/ctrl aliases still work"
      end
      puts row(true, "sidebar_keys: #{overridden.size} remapped, no clashes") if ok
    end

    # PR badges come from gh and are cached on disk; the sidebar degrades SILENTLY if
    # that path breaks (gh auth lapses → badges just freeze, no error). doctor is
    # where that surfaces: whether gh is authenticated, and how stale each project's
    # cached badge set is — so "why are my badges old?" has an answer instead of a
    # shrug. Skipped when gh isn't installed (already flagged above).
    def doctor_prs
      return if `command -v gh 2>/dev/null`.strip.empty?

      authed = Pr.authenticated?
      puts row(authed, authed ? "gh authenticated" : "gh not authenticated — PR badges silently stop updating; run `gh auth login`")
      config.projects.each do |project|
        age = Pr.cache_age(project["name"])
        if age.nil?
          puts "  \e[33m–\e[0m PR badges #{project['name']}: never fetched (auto-refreshes on switch/idle)"
        else
          puts row(true, "PR badges #{project['name']}: refreshed #{humanize_age(age)} ago")
        end
      end
    end

    # Compact age for a doctor line: 45s / 2m / 3h / 5d.
    def humanize_age(seconds)
      s = seconds.to_i
      return "#{s}s" if s < 60
      return "#{s / 60}m" if s < 3600
      return "#{s / 3600}h" if s < 86_400

      "#{s / 86_400}d"
    end

    # Report sound wiring: an audio player on PATH, and whether each state's
    # configured (or default) spec resolves to something playable.
    def doctor_sounds
      player = Sound.player_argv
      puts row(!player.nil?, player ? "audio player: #{player.first}" : "no audio player (afplay/paplay/aplay/ffplay) — sounds stay silent")
      %w[done waiting].each do |state|
        spec = config.sound_for(nil, state.to_sym)
        if spec.nil?
          puts "  \e[33m–\e[0m sound #{state}: muted"
          next
        end

        st = Sound.status(spec)
        puts row(st == :ok, "sound #{state}: #{spec}#{sound_note(st)}")
      end
    end

    # Trailing clause explaining a non-:ok sound status (empty when :ok).
    def sound_note(status)
      case status
      when :missing_file then " (file not found)"
      when :macos_only then " (macOS-only name, not on this OS)"
      when :missing_system_sound then " (no such system sound)"
      when :ok then ""
      else " (unresolved)"
      end
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

    # Surface orphaned sidebar *processes* — a `switchboard sidebar` that outlived
    # its pane (tmux closed the pane but the process didn't exit). They're harmless
    # to the UI but, because tmux recycles pane ids, a straggler can end up reading
    # a different live pane and double-fire completion sounds — so it's worth
    # seeing. Detection is a count diff: how many sidebar processes are running vs
    # how many sidebar panes tmux actually has. Skipped silently when pgrep is
    # absent or tmux is unreachable (no count to compare).
    def doctor_orphan_sidebars
      return if `command -v pgrep 2>/dev/null`.strip.empty?

      panes = Tmux.sidebar_pane_count
      return if panes.nil?

      procs = `pgrep -f 'switchboard sidebar' 2>/dev/null`.lines.size
      orphans = orphan_sidebar_count(procs, panes)
      if orphans.zero?
        puts row(true, "no orphaned sidebars (#{procs} process(es), #{panes} pane(s))")
      else
        puts row(false, "#{orphans} orphaned sidebar process(es) (#{procs} running vs #{panes} pane(s)) — " \
                        "stale sidebars whose pane is gone; a recycled pane id can make one double-ring")
      end
    end

    # Pure: how many sidebar processes have no pane. Clamped at 0 — more panes than
    # processes is a transient (a pane mid-spawn, or a dead-but-displayed pane), not
    # an orphan. Split out so the arithmetic is unit-testable without pgrep/tmux.
    def orphan_sidebar_count(procs, panes)
      [procs - panes, 0].max
    end

    # Report install wiring: PATH symlink, the tmux marker block, and a tmux new
    # enough for the session-switch refresh. Read-only; logic lives in Installer.
    def doctor_install
      doctor_symlinks
      puts row(Installer.tmux_wired?, "tmux bindings wired (switchboard.tmux)")
      doctor_binding_live
      doctor_hooks_live
      v = Installer.tmux_version
      puts row(!v.nil? && v >= 3.0, v ? "tmux #{v} (>= 3.0 for the session-switch refresh)" : "tmux not found")
    end

    # Is prefix-s actually bound to toggle-sidebar in the running server? The sibling
    # of doctor_hooks_live for the BINDING: an upgrade that hasn't re-sourced the
    # fragment can leave prefix-s unbound (or on an ancient binding) while the config
    # still looks wired — the "prefix-s stopped working after a pull" case. Skipped
    # when there's no server to ask.
    def doctor_binding_live
      doctor_key_config
      live = Installer.toggle_key_live?
      unless live.nil?
        key = config.tmux_key("toggle")
        puts row(live, live ? "prefix-#{key} bound (toggle-sidebar)" : "prefix-#{key} NOT bound — running tmux is stale; reload tmux or re-run `switchboard install`")
      end
      doctor_clobber
    end

    # Surface a bad `tmux_keys` config so it isn't silently ignored: a config that
    # failed to parse (fell back to defaults), a value that isn't a usable key, and a
    # home key that collides with the toggle (so home was left unbound).
    def doctor_key_config
      puts row(false, "config failed to parse (#{config.load_error}) — using defaults; fix #{Config.path}") if config.load_error
      %w[toggle home].each do |role|
        raw = config.raw_tmux_key(role)
        next if raw.nil? || config.valid_tmux_key?(raw)

        puts "  \e[33m–\e[0m tmux_keys.#{role} #{raw.inspect} isn't a usable key — using #{config.tmux_key(role) || 'unbound'}"
      end
      home_raw = config.raw_tmux_key("home")
      return unless config.valid_tmux_key?(home_raw) && config.tmux_key("home").nil?

      puts "  \e[33m–\e[0m tmux_keys.home #{home_raw.inspect} collides with the toggle key — home left unbound"
    end

    # If tmux-bind clobbered a prior non-switchboard binding on the chosen key (it
    # records the displaced binding in @switchboard-<role>-clobbered), say so — the
    # interactive install prints a "was:" note, but a live reload is otherwise silent.
    def doctor_clobber
      %w[toggle home].each do |role|
        prev = Installer.tmux_option("@switchboard-#{role}-clobbered")
        next unless prev

        puts "  \e[33m–\e[0m prefix-#{config.tmux_key(role)} (#{role}) replaced a prior binding: #{prev}"
      end
    end

    # tmux_wired? checks the config FRAGMENT is sourced; this checks the hooks are
    # actually LIVE in the running server. They diverge right after a `git pull`
    # upgrade: the new fragment is on disk but the running tmux still has the old
    # hooks until it reloads its config — so a freshly-added hook (e.g. the
    # window-switch poke) is silently inert until then. Surface that with the fix.
    # nil = no server to ask (doctor from a plain shell, no tmux running): skip.
    def doctor_hooks_live
      live = Installer.live_hooks
      return if live.nil?

      missing = live.reject { |_slot, on| on }.keys
      if missing.empty?
        puts row(true, "tmux hooks live (#{live.size} slots)")
      else
        puts row(false, "tmux hooks not live: #{missing.join(', ')} — reload tmux or re-run `switchboard install`")
      end
    end

    # The `switchboard` command symlink is required (✓/✗); the `sb` shorthand is
    # optional, so a missing one reads as a soft note (–), not a ✗ that would
    # imply switchboard is broken — matching install, which skips a collided
    # shorthand rather than failing.
    def doctor_symlinks
      Installer.symlink_targets.each do |link, optional|
        if Installer.linked?(link)
          puts row(true, "PATH symlink: #{link}")
        elsif optional
          puts "  \e[33m–\e[0m PATH symlink: #{link} (optional shorthand, not linked)"
        else
          puts row(false, "PATH symlink: #{link}")
        end
      end
    end

    # ✓/✗ status line shared by the doctor checks.
    def row(ok, msg)
      format("  %s %s", ok ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m", msg)
    end

    # Report the materialized reporter, then claude (per-worktree) and codex (global)
    # status. A present hook file/block isn't proof the agent runs it — Codex needs a
    # one-time `/hooks` trust — so a bare "enabled" line would be false confidence.
    def doctor_hooks
      script = HookFile.script_path
      puts(File.exist?(script) ? "  \e[32m✓\e[0m agent-state reporter: #{script}" : "  \e[33m–\e[0m agent-state reporter not materialized yet (created on first worktree/enable-hooks)")
      here = worktree_at(nil)
      return unless here

      AgentHooks::ADAPTERS.each do |adapter| # claude, per-worktree
        on = adapter.enabled?(here)
        puts(on ? "  \e[32m✓\e[0m #{adapter.label} hooks here: #{adapter.settings_path(here)}"
                : "  \e[33m–\e[0m #{adapter.label} hooks off here — `switchboard enable-hooks`")
      end

      if CodexHook.installed? # codex, global
        puts "  \e[32m✓\e[0m codex hooks (global): #{CodexHook.config_path}"
        puts "      \e[33mnote\e[0m codex runs them only once trusted — run `/hooks` in codex (or start with --dangerously-bypass-hook-trust) if dots don't show"
      else
        puts "  \e[33m–\e[0m codex hooks (global) not installed — `switchboard install --codex-hooks`"
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
          switchboard init         create an empty config (no projects yet)
          switchboard config       edit config.yml in $EDITOR (per-project settings)
          switchboard add N P [B]  register an existing repo (name, path, base ref)
          switchboard remove N     unregister a project (its repo on disk stays; alias: rm)
          switchboard clone U [N]  clone a repo under projects_root, then register
          switchboard refresh      re-fetch PR badges from gh (normally automatic)
          switchboard enable-hooks [P]   wire agent-state dots in a worktree (default: cwd)
          switchboard disable-hooks [P]  remove them from that worktree
          switchboard rename NAME    rename the current workspace (dir + tmux session)
          switchboard sound [done|waiting]  play a state's sound (try audio / pick sounds)
          switchboard prune        kill orphaned sb/ sessions (--dry-run / -n previews)
          switchboard quit         close ALL switchboard sessions (full teardown — kills the one you're in too)
          switchboard doctor       check dependencies + config
          switchboard help         show this help

        in the sidebar
          ↑↓ ^N/^P move (projects, workspaces, and a workspace's branches)
          /        filter — type to jump to a workspace by name (↵ open, esc cancel)
          ↵        switch to the workspace's tmux session (or collapse a project)
          a        add a project (register a local repo or clone a URL)
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
