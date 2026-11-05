# frozen_string_literal: true

require "shellwords"

module Switchboard
  # `switchboard doctor`: read-only checks of the dependencies, config, install wiring, hooks
  # and running state, one row each. The config comes in as an argument, and the cwd's git
  # root comes from Git.toplevel, registered or not, so a repo that isn't a project still
  # gets its hook rows.
  module Doctor
    module_function

    # Present AND parseable (#14): a broken file reads as no projects, so a green row here
    # would vouch for the very thing that emptied the tree.
    def doctor_config(config)
      return puts(row(false, "no config — run `switchboard install`")) unless Config.exist?

      err = config.load_error_message
      puts row(err.nil?, err ? "config: #{Config.path} — #{err}" : "config: #{Config.path}")
    end

    def run(config)
      %w[tmux git gh].each do |tool|
        puts row(!`command -v #{tool} 2>/dev/null`.strip.empty?, tool)
      end
      doctor_version
      doctor_config(config)
      doctor_unknown_keys(config)
      doctor_install(config)
      doctor_sidebar_keys(config)
      doctor_hooks(config)
      doctor_prs(config)
      doctor_sounds(config)
      doctor_sessions(config)
      doctor_remote_links
      doctor_session_names
      doctor_orphan_sidebars
      doctor_reload_failures
    end

    # A sidebar whose code reload failed keeps running its old code (#48); it flags its
    # pane. Silent when none did.
    def doctor_reload_failures
      failed = Tmux.sidebar_reload_targets.to_a.select(&:failed)
      return if failed.empty?

      puts row(false, "#{failed.size} sidebar(s) still on old code after a failed reload (pane #{failed.map(&:pane).join(', ')}) — " \
                      "run `switchboard reload-sidebars`, or press your toggle key twice in that session")
    end

    # Session-name sync types into Claude's pane, so it reports what it couldn't do
    # (SessionName::Outcome) and canaries the session-file fields it relies on: `status`
    # (it gates on it) and `name` (it confirms by it). Silent when there's nothing to say.
    def doctor_session_names
      SessionName::Outcome.all.each do |o|
        retry_hint = "retry with `switchboard rename #{o[:name]}` from inside it"
        retry_hint = "clear that prompt, then #{retry_hint}" if o[:kind] == SessionName::Outcome::FAILED_SEND
        puts "  \e[33m–\e[0m session name: #{o[:path]} — #{SessionName::Outcome::MESSAGES.fetch(o[:kind], o[:kind])}; #{retry_hint}"
      end
      h = RemoteLink.health
      if h[:matched].positive? && h[:unknown_kind] == h[:matched]
        return puts row(false, "session names: no live Claude session reports a kind switchboard knows " \
                               "(#{ClaudeSessions::KINDS.join('/')}) — Claude changed the format; renames won't reach the session")
      end
      return unless h[:verified].positive?

      if h[:odd_status] == h[:verified]
        puts row(false, "session names: no live Claude session reports a status switchboard knows " \
                        "(#{RemoteLink::STATUSES.join('/')}) — Claude changed the format; renames won't reach the session")
      end
      return unless h[:unnamed] == h[:verified]

      puts row(false, "session names: no live Claude session records a name — Claude changed the format; " \
                      "renames can't be confirmed")
    end

    # The ⇅ glyph reads Claude's UNDOCUMENTED per-session files, and degrades to "no
    # glyph" on anything it doesn't recognize — so doctor is the canary for a Claude
    # update that moved or reshaped them. It can catch a moved dir (0 files while Claude
    # runs — 0 with nothing open is normal, Claude removes its file on exit), a changed
    # shape (files, none parse), and a drifted start-time format (EVERY live Claude pid
    # failing the match; one is a recycled pid). A RENAMED bridge key can't be told from "nothing linked".
    # Silent for someone without Claude Code installed.
    def doctor_remote_links
      doctor_remote_link_status
      doctor_claude_config_dir # on every path: a mismatch is the likely CAUSE of the failures above
    end

    def doctor_remote_link_status
      h = RemoteLink.health
      if h[:files].zero?
        return if `command -v claude 2>/dev/null`.strip.empty?
        # Claude removes its file on exit, so no files with nothing open is the normal state
        return puts row(true, "remote links (⇅): no live Claude sessions") unless RemoteLink.claude_running?

        return puts "  \e[33m–\e[0m remote links (⇅): Claude is running but there are no session files in #{h[:dir]} — a Claude update may have moved them"
      end
      if h[:shaped].zero?
        return puts row(false, "remote links (⇅): #{h[:files]} session files in #{h[:dir]}, none in the shape switchboard reads — Claude changed the format; the ⇅ won't show")
      end
      if h[:alive].positive? && h[:drift] == h[:alive] # every live one: a format change, not a recycled pid
        return puts row(false, "remote links (⇅): #{h[:drift]} live session(s) fail the start-time check — Claude changed procStart; the ⇅ won't show")
      end

      puts row(true, "remote links (⇅): #{h[:linked]} linked (#{h[:files]} Claude sessions in #{h[:dir]})")
    end

    # Sidebars are spawned by tmux, which never reads your shell rc — so a
    # CLAUDE_CONFIG_DIR exported only in .zshrc points Claude (started from that shell)
    # at one dir while every sidebar reads ~/.claude: no ⇅, ever, and the row above
    # (read from THIS shell) looks fine. Only checkable from inside tmux.
    def doctor_claude_config_dir
      return unless ENV["TMUX"]

      mine = ENV["CLAUDE_CONFIG_DIR"].to_s
      theirs = tmux_global_env("CLAUDE_CONFIG_DIR").to_s
      # Resolved dirs, not raw strings: unset vs ~/.claude (or a trailing /) is the same dir
      return if File.expand_path(ClaudeHistory.claude_root(mine)) == File.expand_path(ClaudeHistory.claude_root(theirs))

      puts "  \e[33m–\e[0m remote links (⇅): CLAUDE_CONFIG_DIR is #{mine.empty? ? 'unset' : mine.inspect} here but " \
           "#{theirs.empty? ? 'unset' : theirs.inspect} in tmux, where sidebars run — export it in .zshenv " \
           "or `tmux set-environment -g CLAUDE_CONFIG_DIR …` so the ⇅ reads the right dir"
    end

    # A tmux global environment value, or nil when unset (`-NAME` / unknown variable).
    def tmux_global_env(name)
      out = IO.popen(["tmux", "show-environment", "-g", name], err: File::NULL, &:read).to_s.strip
      out.start_with?("#{name}=") ? out.delete_prefix("#{name}=") : nil
    rescue StandardError
      nil
    end

    # Flag top-level config keys switchboard doesn't recognize. The cause this catches
    # for new users: a nested key uncommented from the scaffold that lost its
    # parent/indent (e.g. `new_workspace: w` at the margin instead of under
    # `sidebar_keys:`). It parses fine but is never read, so the setting silently does
    # nothing — the exact trap that motivated this check. A stray key that's actually a
    # sidebar action gets the precise fix; anything else gets the generic hint. Silent
    # for a clean/default config.
    def doctor_unknown_keys(config)
      unknown = config.unknown_keys
      return if unknown.empty?

      actions = Keymap::ACTIONS.map { |a| a.name.to_s }
      unknown.each do |key|
        hint = if Config::RETIRED_KEYS.key?(key)
                 Config::RETIRED_KEYS[key]
               elsif actions.include?(key)
                 "a sidebar key — nest it under `sidebar_keys:`, indented two spaces"
               else
                 "unrecognized — a typo, or a nested key that lost its parent/indent"
               end
        puts "  \e[33m–\e[0m config key #{key.inspect} at the top level does nothing: #{hint}"
      end
    end

    # Surface a bad `sidebar_keys` remap (issue #108) so a binding that didn't take
    # isn't a silent mystery — the sidebar degrades to defaults rather than erroring,
    # so doctor is where it shows. Two cases: a value that isn't a single printable
    # key (fell back to the default), and an action whose key clashes with another's
    # (the loser is left unbound — its arrow/ctrl aliases still fire). Silent for the
    # default layout (nothing remapped); a clean customization gets one confirming row.
    def doctor_sidebar_keys(config)
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
        action = Keymap::ACTIONS.find { |a| a.name == c[:action] }
        what = if config.valid_sidebar_key?(config.raw_sidebar_key(c[:action]))
                 "(#{c[:key].inspect}) clashes with #{c[:winner]} — left unbound"
               else # no remap took (none set, or an invalid one): its default lost
                 "its default #{c[:key].inspect} is taken by #{c[:winner]} — left unbound; set sidebar_keys.#{c[:action]} to reach it"
               end
        what += "; its arrow/ctrl aliases still work" if action && !action.aliases.empty?
        puts "  \e[33m–\e[0m sidebar_keys.#{c[:action]} #{what}"
      end
      puts row(true, "sidebar_keys: #{overridden.size} remapped, no clashes") if ok
    end

    # PR badges come from gh and are cached on disk; the sidebar degrades SILENTLY if
    # that path breaks (gh auth lapses → badges just freeze, no error). doctor is
    # where that surfaces: whether gh is authenticated, and how stale each project's
    # cached badge set is — so "why are my badges old?" has an answer instead of a
    # shrug. Skipped when gh isn't installed (already flagged above).
    def doctor_prs(config)
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
    def doctor_sounds(config)
      player = Sound.player_argv
      puts row(!player.nil?, player ? "audio player: #{player.first}" : "no audio player (afplay/paplay/aplay/ffplay) — sounds stay silent")
      %w[done waiting alert].each do |state|
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
    def doctor_sessions(config)
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
                        "stale sidebars whose pane is gone; a recycled pane id can make one double-ring — " \
                        "run `switchboard prune` to reap them")
      end
    end

    # Pure: how many sidebar processes have no pane. Clamped at 0 — more panes than
    # processes is a transient (a pane mid-spawn, or a dead-but-displayed pane), not
    # an orphan. Split out so the arithmetic is unit-testable without pgrep/tmux.
    def orphan_sidebar_count(procs, panes)
      [procs - panes, 0].max
    end

    # Report install wiring: the PATH entry (symlinks, or brew's bin under Homebrew),
    # which install tmux.conf is wired to, and a tmux new enough for the
    # session-switch refresh. Read-only; logic lives in Installer.
    def doctor_install(config)
      doctor_symlinks
      doctor_tmux_wired
      doctor_binding_live(config)
      doctor_hooks_live
      v = Installer.tmux_version
      puts row(!v.nil? && v >= 3.0, v ? "tmux #{v} (>= 3.0 for the session-switch refresh)" : "tmux not found")
    end

    # Wired to this install ✓; to another install that still exists, a note (a dev
    # running a worktree's bin, or a clone left behind after moving to brew); to one
    # that's gone, ✗ — the toggle and hooks would fail silently.
    def doctor_tmux_wired
      return puts(row(false, "tmux bindings wired (switchboard.tmux)")) unless Installer.tmux_wired?

      wired = Installer.wired_fragment
      if !wired
        puts row(false, "tmux.conf has a switchboard block but no line it recognizes — re-run `switchboard install`")
      elsif File.identical?(wired, Installer.fragment_path)
        puts row(true, "tmux bindings wired (switchboard.tmux)")
      elsif File.exist?(wired)
        puts "  \e[33m–\e[0m tmux is wired to another install (#{wired}) — `switchboard install` re-wires it to this one"
      else
        puts row(false, "tmux is wired to a missing install (#{wired}) — re-run `switchboard install`")
      end
    end

    # Is the toggle key actually bound to toggle-sidebar in the running server? The sibling
    # of doctor_hooks_live for the BINDING: an upgrade that hasn't re-sourced the
    # fragment can leave the toggle key unbound (or on an ancient binding) while the config
    # still looks wired — the "toggle key stopped working after a pull" case. Skipped
    # when there's no server to ask.
    def doctor_binding_live(config)
      doctor_key_config(config)
      toggle = Installer.bound_toggle_key # the key actually bound, as upgrade checks it (a rejected one fell back)
      live = Installer.toggle_key_live?(toggle)
      unless live.nil?
        puts row(live, live ? "prefix-#{toggle} bound (toggle-sidebar)" : "prefix-#{toggle} NOT bound — running tmux is stale; run `switchboard upgrade` (or reload tmux)")
      end
      doctor_key_drift(config, skip_toggle: live == false) # the NOT-bound row above already covers it
      doctor_clobber(config)
    end

    # A tmux_keys edit made in config.yml by hand (not via `e` / `switchboard config`, which
    # rebind at once) stays unapplied until tmux reloads; the bound key still works, so the
    # row above reads green.
    def doctor_key_drift(config, skip_toggle: false)
      return unless Installer.tmux_wired? # unwired (--no-tmux): switchboard manages no keys to drift
      %w[toggle home].each do |role|
        next if role == "toggle" && skip_toggle
        if (refused = Installer.refused_key(role, config: config))
          why = role == "home" ? "tmux refused it, or the toggle fell back onto it" : "tmux refused it"
          puts "  \e[33m–\e[0m tmux_keys.#{role} is #{refused} in config, but it isn't bound (#{why}) — pick another key"
          next
        end
        next unless Installer.key_drift?(role, config: config)

        bound = Installer.tmux_option("@switchboard-#{role}-key")
        puts "  \e[33m–\e[0m tmux_keys.#{role} is #{config.tmux_key(role) || 'unbound'} in config, but tmux has " \
             "#{bound ? "prefix-#{bound}" : 'nothing'} bound — run `switchboard upgrade` (or reload tmux) to apply it"
      end
    end

    # Surface a bad `tmux_keys` config so it isn't silently ignored: a config that
    # failed to parse (the bound keys stay; defaults only if none were), a value that isn't
    # a usable key, and a home key that collides with the toggle (so home was left unbound).
    def doctor_key_config(config)
      if config.load_error
        kept = %w[toggle home].any? { |role| Installer.tmux_option("@switchboard-#{role}-key") }
        puts "  \e[33m–\e[0m tmux_keys: #{kept ? 'keeping the keys already bound' : 'using the default keys'} " \
             "(config.yml didn't parse — see above)"
      end
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
    def doctor_clobber(config)
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
        puts row(false, "tmux hooks not live: #{missing.join(', ')} — run `switchboard upgrade` (or reload tmux)")
      end
    end

    # The `switchboard` command symlink is required (✓/✗); the `sb` shorthand is
    # optional, so a missing one reads as a soft note (–), not a ✗ that would
    # imply switchboard is broken — matching install, which skips a collided
    # shorthand rather than failing.
    def doctor_symlinks
      return doctor_homebrew_path if Installer.homebrew?

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

    # Homebrew owns PATH: `switchboard` must resolve to brew's copy, `sb` should. A clone's
    # leftover link ahead of brew's is reported with an rm for just that link (the clone's
    # `uninstall` would also strip the tmux/codex wiring brew now owns). Some other program
    # named `sb` is left alone: the shorthand is optional, as in clone mode.
    def doctor_homebrew_path
      Installer::SYMLINK_NAMES.each do |name|
        found = `command -v #{name} 2>/dev/null`.strip
        required = name == Installer::COMMAND_NAME
        if found.empty?
          puts(required ? row(false, "Homebrew install, but `switchboard` isn't on PATH — run `brew link switchboard`")
                        : "  \e[33m–\e[0m `#{name}` isn't on PATH (optional shorthand)")
        elsif File.identical?(found, Installer.bin_path)
          puts row(true, "on PATH via Homebrew: #{found}")
        elsif switchboard_bin?(found) && File.symlink?(found)
          puts row(false, "`#{name}` on PATH is #{found}, which shadows Homebrew's — delete that link (`rm #{Shellwords.escape(found)}`)")
        elsif switchboard_bin?(found) # a clone's own launcher: deleting it would break the clone
          puts row(false, "`#{name}` on PATH is #{found}, which shadows Homebrew's — take #{File.dirname(found)} off your PATH")
        elsif required
          puts row(false, "`switchboard` on PATH is #{found}, another program — put Homebrew's bin earlier on PATH")
        else
          puts "  \e[33m–\e[0m `#{name}` on PATH is #{found} (another program; optional shorthand)"
        end
      end
    end

    # A switchboard launcher (a clone's bin/switchboard, or a link to one): its checkout
    # sits beside it with lib/switchboard.rb.
    def switchboard_bin?(path)
      real = File.realpath(path)
      File.basename(real) == "switchboard" && File.file?(File.expand_path("../lib/switchboard.rb", File.dirname(real)))
    rescue SystemCallError
      false
    end

    # The running version against what `upgrade` would fetch: release tags for Homebrew
    # (bounded, LatestRelease::DEADLINE, so offline it says so), else the branch followed.
    def doctor_version
      # Only a Homebrew install follows release tags; a clone and --HEAD follow a branch.
      unless (method = Upgrade.install_method) == :brew
        follows = method == :clone ? "your clone's branch" : "main (--HEAD)"
        puts row(true, "switchboard #{VERSION} — follows #{follows}; `switchboard upgrade` pulls it")
        return
      end

      latest = LatestRelease.latest
      if latest.nil?
        puts "  \e[33m–\e[0m switchboard #{VERSION} — couldn't check for a newer release (offline?)"
      elsif LatestRelease.compare(latest, VERSION).positive?
        puts "  \e[33m–\e[0m switchboard #{latest} is available (you have #{VERSION}) — `switchboard upgrade`"
      else
        puts row(true, "switchboard #{VERSION} (latest)")
      end
    end

    # The shared reporter script, read the way `upgrade` reads it (HookFile.script_state).
    def doctor_reporter
      script = HookFile.script_path
      case HookFile.script_state
      when :current then puts row(true, "agent-state reporter: #{script}")
      when :stale
        # Another binary's SCRIPT may differ from the installed one's; only that one can judge.
        puts(Installer.installed_bin? ? "  \e[33m–\e[0m agent-state reporter is from another release — `switchboard upgrade`" : "  \e[33m–\e[0m agent-state reporter: #{script}")
      else
        if Installer.reporter_needed?
          puts row(false, "agent-state reporter missing (#{script}) — hooked agents can't report; `switchboard upgrade`")
        else
          puts "  \e[33m–\e[0m agent-state reporter not materialized yet (created on first worktree/enable-hooks)"
        end
      end
    end

    # ✓/✗ status line shared by the doctor checks.
    def row(ok, msg)
      format("  %s %s", ok ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m", msg)
    end

    # Some setups launch codex with the trust bypass in their session_command, never
    # approving in /hooks — for them N/M < total is expected, not dead dots. Only when EVERY
    # codex-launching command (global or a project's) bypasses: one bypassing project must
    # not hide the warning for the others.
    def codex_bypasses_trust?(config)
      cmds = ([config.session_command] + config.projects.map { |p| p["session_command"] }).map(&:to_s)
      codex = cmds.select { |cmd| cmd.match?(/(?:\A|[\s\/;&|])codex(?:\s|\z)/) }
      codex.any? && codex.all? { |cmd| cmd.include?("--dangerously-bypass-hook-trust") }
    end

    # Report the materialized reporter, then claude (per-worktree) and codex (global)
    # status. A present hook file/block isn't proof the agent runs it — Codex needs a
    # one-time `/hooks` trust — so a bare "enabled" line would be false confidence.
    def doctor_hooks(config)
      doctor_reporter
      here = Git.toplevel(Dir.pwd)
      AgentHooks::ADAPTERS.each do |adapter| # claude, per-worktree
        next unless here # the codex block below is global, so it reports from any shell

        # Present isn't enough: hooks written by an older release miss its new entries. Only
        # the installed binary can judge that: hooks call back into the binary that wrote them.
        if adapter.unreadable?(here)
          puts row(false, "#{adapter.label} hooks here: can't read #{adapter.settings_path(here)}")
        elsif adapter.unparseable?(here) # ours or not: enable-hooks refuses either
          puts row(false, "#{adapter.label} hooks here: #{adapter.corrupt_reason(here)} — fix it, then `switchboard enable-hooks`")
        elsif !adapter.enabled?(here)
          puts "  \e[33m–\e[0m #{adapter.label} hooks off here — `switchboard enable-hooks`"
        elsif !Installer.installed_bin?
          puts "  \e[33m–\e[0m #{adapter.label} hooks here: #{adapter.settings_path(here)} (run the installed `switchboard doctor` to check they're current)"
        elsif adapter.current?(here)
          puts "  \e[32m✓\e[0m #{adapter.label} hooks here: #{adapter.settings_path(here)}"
        elsif Installer.configured_worktrees.any? { |wt| File.identical?(wt, here) }
          puts "  \e[33m–\e[0m #{adapter.label} hooks here are out of date — `switchboard upgrade` (or `switchboard enable-hooks`)"
        else # upgrade only refreshes configured projects
          puts "  \e[33m–\e[0m #{adapter.label} hooks here are out of date — `switchboard enable-hooks` (not a configured project, so `upgrade` skips it)"
        end
      end

      if CodexHook.installed? # codex, global
        trusted, total = CodexHook.trust_status
        state = CodexHook.block_state
        if state == :collision
          puts "  \e[33m!\e[0m codex hooks (global): #{CodexHook.config_path} already has its own [hooks] config " \
               "outside switchboard's block — two [hooks] tables are invalid TOML; merge yours into one place"
        elsif state == :unsafe
          puts "  \e[33m!\e[0m codex hooks (global): #{CodexHook.config_path} — can't be rewritten safely: " \
               "#{CodexHook::UNSAFE_ADVICE} `switchboard install`"
        elsif state == :stale
          puts "  \e[33m!\e[0m codex hooks (global): #{CodexHook.config_path} — the block doesn't match what this " \
               "switchboard (#{CodexHook.bin}) writes — re-run `switchboard install` " \
               "from the install you use, then trust the hooks in codex `/hooks`"
        elsif trusted == total
          puts "  \e[32m✓\e[0m codex hooks (global): #{CodexHook.config_path} — #{trusted}/#{total} trusted"
        elsif codex_bypasses_trust?(config)
          puts "  \e[32m✓\e[0m codex hooks (global): #{CodexHook.config_path} — #{trusted}/#{total} trusted, " \
               "but your session_command runs codex with --dangerously-bypass-hook-trust, so they run anyway"
        else
          puts "  \e[33m!\e[0m codex hooks (global): #{CodexHook.config_path} — #{trusted}/#{total} trusted"
          puts "      codex never runs an untrusted hook, so its dots won't move — run `/hooks` in codex and trust " \
               "the switchboard hooks (or start codex with --dangerously-bypass-hook-trust)"
        end
      else
        # From a home shell this would nag everyone who declined it at install.
        puts "  \e[33m–\e[0m codex hooks (global) not installed — `switchboard install --codex-hooks`" if here
      end
    end
  end
end
