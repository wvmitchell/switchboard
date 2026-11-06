# frozen_string_literal: true

require "fileutils"
require "shellwords"
require_relative "../support/marker_block"
require_relative "../adapters/codex_hook"
require_relative "../support/stable_path"
require_relative "../root"
require_relative "../support/paths"

module Switchboard
  # Stands switchboard up from a fresh clone: a `switchboard` symlink on PATH
  # (plus a short `sb` alias beside it), a tmux.conf line that sources the
  # self-locating `switchboard.tmux` fragment, and an empty config — all
  # idempotent and reversible by `uninstall`. Every step is best-effort and
  # prints its own status; one failing step never aborts the rest (same
  # degrade-gracefully posture as the rest of the codebase).
  #
  #   install ──┬─ symlink  ~/.local/bin/{switchboard,sb} → <repo>/bin/switchboard
  #             ├─ tmux     marker block ⇒ run-shell '<repo>/switchboard.tmux'
  #             └─ init     Config.scaffold (empty config if none)
  #
  # The marker block carries the repo path, so a moved clone is healed by simply
  # re-running install (symlink repoints even when dangling; the block is rewritten
  # in place). Paths are escaped for the shell layer (Shellwords) and wrapped in
  # tmux single quotes so the eventual /bin/sh sees a correctly-quoted command —
  # verified against tmux for clone paths containing spaces.
  module Installer
    module_function

    BEGIN_MARK = "# >>> switchboard install >>>"
    NOTE_MARK  = "# managed by `switchboard install` — edits between the markers are overwritten"
    END_MARK   = "# <<< switchboard install <<<"

    # The indexed global hooks the switchboard.tmux fragment installs. Listed here
    # so teardown clears exactly these slots and `doctor` can check they're LIVE in
    # the running server (the fragment only re-applies them on a tmux config reload,
    # so a `git pull` upgrade leaves them stale until then). Keep in sync with
    # switchboard.tmux.
    HOOK_SLOTS = [
      "client-session-changed[99]", # poke the now-visible sidebar on a session switch
      "after-new-window[99]",       # give a new window its own sidebar
      "session-window-changed[99]"  # poke the sidebar on a same-session window switch
    ].freeze

    # --- paths ---------------------------------------------------------------

    # Repo root of the loaded code (Switchboard::ROOT). Works through a PATH symlink:
    # ROOT is the real lib dir's parent, which StablePath lifts out of a versioned keg.
    def repo_root
      StablePath.resolve(real_root)
    end

    # Installed by Homebrew, which already put `switchboard` on PATH — so install
    # skips the ~/.local/bin symlinks (and uninstall leaves PATH to `brew uninstall`).
    def homebrew?
      StablePath.homebrew?(real_root)
    end

    def real_root = ROOT

    def bin_path
      File.join(repo_root, "bin", "switchboard")
    end

    def fragment_path
      File.join(repo_root, "switchboard.tmux")
    end

    def bin_dir
      Paths.dir("SWITCHBOARD_BIN_DIR", "~/.local/bin")
    end

    # Names we put on PATH: the full command plus a short alias you can type
    # from any shell. `sb` is pure convenience — install/uninstall/doctor treat
    # both uniformly, but a name already owned by something else only blocks the
    # real command (a ✗ to fix); the shorthand just gets skipped (switchboard
    # still works, you just type the full name).
    COMMAND_NAME = "switchboard"
    SHORTHAND    = "sb"
    SYMLINK_NAMES = [COMMAND_NAME, SHORTHAND].freeze

    def symlink_path(name = COMMAND_NAME)
      File.join(bin_dir, name)
    end

    def symlink_paths
      symlink_targets.map(&:first)
    end

    # Each PATH symlink as [path, optional?]. The `sb` shorthand is optional, so
    # doctor can render a missing one as a soft note (–) instead of a hard ✗ —
    # matching install, which skips a collided shorthand rather than failing.
    def symlink_targets
      SYMLINK_NAMES.map { |name| [symlink_path(name), name != COMMAND_NAME] }
    end

    # The single tmux.conf line that sources the fragment. Single tmux quotes
    # around the shell-escaped path: tmux passes it through verbatim and /bin/sh
    # then de-escapes, so spaces in the repo path survive both layers.
    def marker_line
      "run-shell '#{Shellwords.escape(fragment_path)}'"
    end

    # The inverse of marker_line, kept beside it so writer and parser can't drift.
    MARKER_LINE = /\Arun-shell '(.+)'\z/

    # A quote in the repo path can't be nested safely in the two quoting contexts
    # we emit: a single quote closes the marker line's tmux '...' early, a double
    # quote closes the fragment's run-shell "'$BIN' ..." early, and a newline or
    # control char turns the marker line into multi-line garbage. All are
    # pathological in a real clone path; refuse rather than write a broken line.
    def tmux_safe_path?
      !fragment_path.match?(/['"\x00-\x1f]/)
    end

    # --- install -------------------------------------------------------------

    def install(no_tmux: false, print_tmux: false, conf: nil, codex_hooks: nil)
      puts "switchboard install"
      step_symlink
      wire_tmux(no_tmux: no_tmux, print_tmux: print_tmux, conf: conf)
      step_init
      codex_ok = step_codex_hooks(codex_hooks) != false # a declined prompt or no codex is fine
      hooks_ok = refresh_wiring
      warn_path
      warn_tmux_version
      broken = Config.new.load_error
      key = broken ? bound_toggle_key : Config.new.tmux_key("toggle") # a broken config keeps the bound key
      hooks_part = broken ? "the config" : "the agent-state hooks" # refresh_wiring fails on either
      failed = [("the codex hooks" unless codex_ok), (hooks_part unless hooks_ok)].compact
      done = failed.empty? ? "Done" : "Done, except #{failed.join(' and ')} (✗ above)"
      puts "\n#{done} — run `switchboard` (or `sb`) from any shell to start; press prefix-#{key} to toggle the sidebar inside tmux."
      puts "(If the key doesn't respond yet, reload tmux: `tmux source-file <your conf>`.)"
      codex_ok && hooks_ok # false ⇒ the CLI exits 1
    end

    # --- refresh (install and upgrade) ----------------------------------------

    # What a new version needs from an existing install, beyond the tmux and codex steps
    # (which each caller runs its own way): the current reporter script, and every
    # worktree that already carries switchboard's Claude hooks brought up to this version's
    # set — they're only written at worktree creation / enable-hooks, so they'd otherwise
    # stay on whatever release created them. False when a worktree couldn't be updated, the
    # reporter couldn't be written while something runs it, or the config didn't parse.
    def refresh_wiring
      reporter_ok = true
      if installed_bin? # every hooked worktree runs this one shared script
        HookFile.ensure_script
        unless HookFile.script_current?
          msg = reporter_unwritable
          # Only something that runs it makes that a failure; with nothing hooked it's a warning.
          (reporter_ok = !reporter_needed?) ? note("#{msg} (nothing is hooked yet)") : bad(msg)
        end
      end
      config_readable? && step_rewire_hooks && reporter_ok
    end

    # An unparseable config reads as no projects, so the hook refresh would skip every
    # worktree in silence (and upgrade would call itself current): say so and fail instead.
    def config_readable?
      err = Config.new.load_error_message or return true
      bad "#{err} — fix #{Config.path}, then re-run"
      false
    end

    def reporter_unwritable = "agent-state reporter: couldn't write #{HookFile.script_path} — check that directory's permissions"

    # The shared reporter matters once anything runs it: a hooked worktree, or the global
    # codex block (its commands call the same script). Upgrade, refresh and doctor all ask this.
    def reporter_needed? = !hooked_worktrees.empty? || CodexHook.installed?

    # Hooks call back into the binary that wrote them, so only the installed `switchboard`
    # may rewrite them: run from a dogfood checkout, this would point every worktree at a
    # path that disappears with it.
    def step_rewire_hooks
      hooked = hooked_worktrees
      return true if hooked.empty?
      unless installed_bin?
        note "worktree hooks: not refreshed — #{Switchboard.env('SWITCHBOARD_BIN')} isn't the `switchboard` on your PATH"
        return true
      end

      results = hooked.to_h { |wt| [wt, rewire(wt)] }
      report_rewire(results)
    end

    # One worktree's refresh, isolated: an unwritable file must not stop the others.
    def rewire(worktree)
      ClaudeHook.refresh(worktree)
    rescue StandardError
      :failed
    end

    def report_rewire(results)
      rewired = results.count { |_wt, r| r == :rewired }
      failed = results.count { |_wt, r| !%i[current rewired].include?(r) }
      line = "worktree hooks: #{rewired.zero? && failed.zero? ? 'all current' : "updated #{rewired}"} (#{results.size} hooked)"
      line += " — a running Claude picks the change up on its own" if rewired.positive?
      failed.zero? ? ok(line) : bad("#{line}, #{failed} not updated:")
      results.each do |wt, r|
        case r
        when :conflict then bad "worktree hooks: #{wt} changed while switchboard was updating it — re-run to retry"
        when :corrupt  then bad "worktree hooks: #{ClaudeHook.corrupt_reason(wt) || "#{ClaudeHook.settings_path(wt)} can't be parsed"} — left untouched"
        when :failed   then bad "worktree hooks: couldn't update #{wt}"
        end
      end
      results.values.all? { |r| %i[current rewired].include?(r) }
    end

    # Every worktree of every configured project (primaries too) whose Claude settings
    # already hold switchboard's hooks. A missing or non-git project path lists nothing.
    def hooked_worktrees
      configured_worktrees.select { |wt| ClaudeHook.enabled?(wt) || ClaudeHook.corrupt?(wt) }
    end

    # Every worktree of every configured project — all an upgrade or install refreshes.
    def configured_worktrees
      Config.new.projects.flat_map { |p| Git.worktrees(p["path"]) }
            .reject { |w| w[:bare] }.map { |w| w[:path] }.uniq
    end

    # Hooked worktrees an upgrade should rewrite. A corrupt one is left out: refresh reports
    # it but can't fix it, so counting it would make every up-to-date upgrade "finish" again.
    def stale_worktrees
      hooked_worktrees.reject { |wt| ClaudeHook.corrupt?(wt) || ClaudeHook.current?(wt) }
    end

    # Is the running binary the `switchboard` a shell would run?
    def installed_bin?
      found = `command -v #{COMMAND_NAME} 2>/dev/null`.strip
      !found.empty? && ENV["SWITCHBOARD_BIN"].to_s != "" && File.identical?(found, ENV["SWITCHBOARD_BIN"])
    end

    # Re-run the switchboard tmux fragment in the running server, from any shell — the
    # server keeps the bindings and hooks it loaded, so new ones are inert until then. Only
    # switchboard's file, not the whole tmux.conf. Separate from `reload` (the in-tmux,
    # whole-conf re-source install does). Only when tmux.conf sources THIS install's
    # fragment: never wire tmux for someone who installed with --no-tmux, nor bind the keys
    # to a dogfood checkout. :unwired / :no_server when skipped, else whether it ran.
    def reload_fragment
      return :unwired unless fragment_wired_here?
      return :no_server unless tmux_server?

      run_tmux("run-shell", Shellwords.escape(fragment_path))
    end

    # tmux.conf sources THIS install's fragment (and its path can be quoted safely).
    def fragment_wired_here?
      tmux_safe_path? && wired_fragment == fragment_path
    end

    def tmux_server?
      run_tmux("list-sessions")
    end

    # Codex can't discover project-local hooks in linked worktrees, so its agent-state
    # hooks ship as ONE block in the user's global `~/.codex/config.toml`. Writing the
    # user's global config is opt-in: ask (default no on a non-tty / `--no-codex-hooks`).
    # `consent`: nil ⇒ prompt, true ⇒ yes (`--codex-hooks`), false ⇒ skip.
    def step_codex_hooks(consent)
      return unless codex_present?
      return if consent == false # --no-codex-hooks: hands off, even a block that's already there

      # Already opted in → re-ensure the block (idempotent + byte-stable, so codex's
      # hash-keyed `/hooks` trust survives) so `install` doubles as a repair path: it
      # refreshes a block left stale by an upgrade or a moved reporter script. No re-prompt
      # — consent was given when it was first added.
      return report_codex_install(CodexHook.install_global, reensure: true) if CodexHook.installed?

      ok_to_write = consent || prompt_yes?("Install codex hooks globally for agent status monitoring? Writes a managed block to #{CodexHook.config_path}.")
      unless ok_to_write
        note "codex hooks skipped — re-run `install --codex-hooks` to opt in later"
        return
      end

      report_codex_install(CodexHook.install_global, reensure: false)
    end

    def report_codex_install(result, reensure:, verb: "install")
      case result
      when :collision then bad "codex hooks: #{CodexHook.config_path} already has its own [hooks] — left untouched"
      when :unsafe    then bad "codex hooks: left #{CodexHook.config_path} untouched, can't be rewritten safely — " \
                               "#{CodexHook::UNSAFE_ADVICE} `switchboard #{verb}`"
      when :conflict  then bad "codex hooks: #{CodexHook.config_path} changed while switchboard was writing it (codex wrote to it) — re-run `switchboard #{verb}`"
      when nil        then bad "codex hooks: couldn't write #{CodexHook.config_path}"
      else
        ok(reensure ? "codex hooks re-ensured (global): #{CodexHook.config_path}" : "codex hooks installed: #{CodexHook.config_path}")
        note "one-time: run `/hooks` in codex and trust the switchboard hooks (or start codex with --dangerously-bypass-hook-trust)" unless reensure
        return true
      end
      false
    end

    def codex_present?
      File.directory?(CodexHook.home) ||
        system("command -v codex >/dev/null 2>&1")
    end

    # Default NO on a non-tty (a scripted/CI install must never silently touch global
    # config); an explicit `--codex-hooks` flag bypasses this via `consent: true`.
    def prompt_yes?(question)
      return false unless $stdin.tty?

      print "#{question} [y/N] "
      $stdin.gets&.strip&.downcase&.start_with?("y") || false
    end

    def step_symlink
      return ok("on PATH via Homebrew: #{bin_path}") if homebrew?

      FileUtils.mkdir_p(bin_dir)
      SYMLINK_NAMES.each { |name| link_one(symlink_path(name), primary: name == COMMAND_NAME) }
    end

    # Symlink one name → our bin. A name already taken (a real file, or a symlink
    # into a live tree elsewhere) is left untouched. Per-name rescue so one bad
    # name never aborts the others.
    def link_one(link, primary:)
      if File.symlink?(link)
        return ok("symlink already points here: #{link}") if File.identical?(link, bin_path)
        return foreign(link, primary, "points elsewhere") unless ours_symlink?(link)

        File.delete(link) # ours but stale (e.g. repo moved) → repoint
      elsif File.exist?(link)
        return foreign(link, primary, "isn't ours")
      end
      File.symlink(bin_path, link)
      ok "symlink: #{link} → #{bin_path}"
    rescue StandardError => e
      bad "symlink: #{e.message}"
    end

    # A name we won't take over. The command failing to link is a problem to fix
    # (✗); the shorthand is optional, so a collision there is a soft note (–) —
    # switchboard works regardless, you just don't get the `sb` alias.
    def foreign(link, primary, why)
      if primary
        bad "#{link} #{why} — remove it and re-run"
      else
        note "shorthand `#{File.basename(link)}` skipped: #{link} #{why}"
      end
    end

    # All three tmux paths (write / print / skip) sit behind the path-safety
    # guard, so a quote/control char in the repo path never produces a broken
    # marker line anywhere — not just on the automatic write.
    def wire_tmux(no_tmux:, print_tmux:, conf:)
      return bad("tmux: not wired — the repo path contains a quote or control character that can't be safely quoted in a tmux.conf line. Move the clone to a path without it.") unless tmux_safe_path?

      if print_tmux
        note "tmux: add this to your tmux.conf (then reload):"
        puts "      #{marker_line}"
      elsif no_tmux
        note "tmux: skipped (--no-tmux) — add `#{marker_line}` yourself to wire the keys"
      else
        step_tmux(conf)
      end
    end

    def step_tmux(conf_override)
      conf = tmux_conf(conf_override)
      key = Config.new.tmux_key("toggle")
      prev = prefix_binding(key)
      body = File.exist?(conf) ? File.read(conf) : ""
      backup(conf) if File.exist?(conf)
      atomic_write(conf, with_block(strip_block(body)))
      reload(conf)
      dest = real_target(conf)
      ok(dest == conf ? "tmux: wired in #{conf}" : "tmux: wired in #{conf} → #{dest}")
      note "prefix-#{key} now toggles the sidebar (was: #{prev})" if prev && !prev.include?("switchboard")
    rescue StandardError => e
      bad "tmux: #{e.message}"
    end

    def step_init
      if Config.exist?
        note "config: #{Config.path} (exists — left as-is)"
      else
        Config.scaffold
        ok "config: wrote #{Config.path}"
      end
    end

    # --- uninstall -----------------------------------------------------------

    def uninstall(conf: nil)
      puts "switchboard uninstall"
      # Codex first, and stop on a refusal: its advice is "re-run uninstall", so nothing else
      # (the PATH command included) may be removed before the user can follow it.
      unless (codex = step_codex_unhooks)
        puts "\nStopped before removing anything else — fix the codex block above, then re-run `switchboard uninstall`."
        return false # nothing was removed: the CLI exits 1
      end
      unlink_symlink
      unwire_tmux(conf)
      teardown_live
      done = codex == :failed ? "Done, except the codex hooks (✗ above)" : "Done"
      puts "\n#{done}. Your config (#{Config.path}) and agent state were left untouched."
      codex != :failed # the CLI exits 1, as install does for the same failure
    end

    # Remove the global codex [hooks] block (the one place codex delivery is global). The
    # per-worktree disable-hooks deliberately leaves it; full teardown removes it. Returns
    # true (removed or none), false (a refusal the user can fix and re-run: :unsafe/:conflict
    # — the caller stops there) or :failed (a write that failed — reported, not stopped on).
    def step_codex_unhooks
      return true unless CodexHook.installed?

      # Never advise deleting the block by hand: codex appends its own tables inside it,
      # and removing the region would take them too.
      case CodexHook.remove_global
      when true
        ok "removed global codex hooks from #{CodexHook.config_path}"
        true
      when :unsafe
        bad "left the codex hooks block in #{CodexHook.config_path} in place, can't be removed safely — " \
            "#{CodexHook::UNSAFE_ADVICE} uninstall"
        false # a refusal the user can fix and re-run: stop uninstall
      when :conflict
        bad "#{CodexHook.config_path} changed while uninstalling (codex wrote to it) — re-run uninstall"
        false
      else
        # remove_global's false also means "nothing to remove" (the block went meanwhile) —
        # but installed? reads false for an unreadable file too, so check that it IS readable.
        path = CodexHook.config_path
        still_there = File.exist?(path) && (!File.readable?(path) || CodexHook.installed?)
        return true unless still_there

        # A write that FAILED (read-only/symlinked config) would fail again on a re-run, so
        # stopping here would wedge uninstall forever: report it and let the rest proceed.
        bad "couldn't read or write #{CodexHook.config_path}, so its codex hooks block is still there and " \
            "codex will keep running its state reporter — make #{File.dirname(MarkerBlock.real_target(CodexHook.config_path))} " \
            "(and the file) writable, then run " \
            "`#{bin_path} uninstall` again"
        :failed
      end
    end

    def unlink_symlink
      return note("PATH: installed by Homebrew — `brew uninstall switchboard` removes the command") if homebrew?

      symlink_paths.each { |link| unlink_one(link) }
    end

    def unlink_one(link)
      if File.symlink?(link) && ours_symlink?(link)
        File.delete(link)
        ok "removed symlink: #{link}"
      elsif File.symlink?(link)
        note "left foreign symlink at #{link} (not ours)"
      else
        note "no symlink at #{link}"
      end
    rescue StandardError => e
      bad "symlink: #{e.message}"
    end

    def unwire_tmux(conf_override)
      conf = tmux_conf(conf_override)
      if File.exist?(conf) && File.read(conf).include?(BEGIN_MARK)
        body = File.read(conf)
        stripped = strip_block(body)
        if stripped == body
          return bad("couldn't remove the switchboard block from #{conf} — delete it by hand (between its # >>> / # <<< markers)")
        end

        backup(conf)
        atomic_write(conf, stripped)
        reload(conf)
        ok "removed tmux block from #{conf}"
      else
        note "no switchboard block in #{conf}"
      end
    rescue StandardError => e
      bad "tmux: #{e.message}"
    end

    # source-file re-runs the (now clean) config but doesn't drop a binding/hook
    # already live in the server — undo those explicitly. These are server ops (no
    # client needed), so DON'T gate on ENV["TMUX"]: uninstall from a plain shell is a
    # real recovery path, and leaving the global session-window-changed hook live
    # would keep firing poke-window at the now-removed install on every window switch.
    # No server ⇒ the tmux calls no-op (errors swallowed), and they never start one.
    def teardown_live
      raw = list_prefix_keys
      restored = []
      %w[toggle home].each do |role|
        recorded = tmux_option("@switchboard-#{role}-key")
        restore = restorable(role, recorded, raw)
        restored << recorded if restore
        run_op(restore ? [:restore, recorded, restore] : [:unbind, recorded]) if recorded && !kept_key?(recorded, raw)
        run_tmux("set-option", "-gu", "@switchboard-#{role}-key")
        run_tmux("set-option", "-gu", "@switchboard-#{role}-clobbered")
        run_tmux("set-option", "-gu", "@switchboard-#{role}-displaced")
        run_tmux("set-option", "-gu", "@switchboard-#{role}-rejected")
      end
      run_tmux("set-option", "-gu", "@switchboard-config-path")
      # Legacy default: covers installs predating the @option record, so only if it's still ours.
      run_tmux("unbind-key", "s") if !restored.include?("s") && switchboard_binding?(binding_on(raw, "s"))
      HOOK_SLOTS.each { |slot| run_tmux("set-hook", "-gu", slot) }
    end

    # --- doctor support (read-only predicates; cli renders the rows) ----------

    def linked?(link = symlink_path)
      File.symlink?(link) && File.exist?(link) && File.identical?(link, bin_path)
    rescue StandardError
      false
    end

    def tmux_wired?(conf = nil)
      c = tmux_conf(conf)
      File.exist?(c) && File.read(c).include?(BEGIN_MARK)
    rescue StandardError
      false
    end

    # The fragment path our marker block sources, or nil when not wired. Lets doctor
    # tell "wired to THIS install" from "wired to another one" — e.g. a clone left
    # behind after moving to brew, which keeps running until `install` re-wires.
    def wired_fragment(conf = nil)
      c = tmux_conf(conf)
      return nil unless File.exist?(c)

      block = File.read(c)[/#{Regexp.escape(BEGIN_MARK)}(.*?)#{Regexp.escape(END_MARK)}/m, 1]
      escaped = block&.lines&.map(&:strip)&.filter_map { |l| l[MARKER_LINE, 1] }&.first
      escaped && Shellwords.split(escaped).first
    rescue StandardError
      nil
    end

    # Major.minor as a Float (e.g. "3.6a" → 3.6); nil if tmux is absent.
    def tmux_version
      parse_version(`tmux -u -V 2>/dev/null`)
    end

    # Pull major.minor out of a `tmux -V` string as a Float, or nil. Split out
    # from the shell-out so it's unit-testable without tmux.
    def parse_version(str)
      v = str.to_s[/(\d+\.\d+)/, 1]
      v&.to_f
    end

    # --- internals -----------------------------------------------------------

    # A symlink at our PATH spot is "ours" if it resolves into this repo, or if
    # it dangles (the repo moved out from under it) — both are safe to repoint.
    # A real file, or a symlink into another live tree, is foreign.
    def ours_symlink?(link)
      return false unless File.symlink?(link)

      target = File.absolute_path(File.readlink(link), File.dirname(link))
      !File.exist?(target) || File.identical?(target, bin_path)
    rescue StandardError
      false
    end

    # The marked-region file surgery lives in MarkerBlock (shared with CodexHook); here
    # we only supply the tmux marks + the inner content (the note + the run-shell line).
    def with_block(body)
      MarkerBlock.build(body, BEGIN_MARK, END_MARK, "#{NOTE_MARK}\n#{marker_line}")
    end

    def strip_block(body)      = MarkerBlock.strip(body, BEGIN_MARK, END_MARK)
    def backup(conf)           = MarkerBlock.backup(conf)
    def atomic_write(p, c)     = MarkerBlock.atomic_write(p, c)
    def real_target(path)      = MarkerBlock.real_target(path)

    def reload(conf)
      system("tmux", "-u", "source-file", conf, out: File::NULL, err: File::NULL) if ENV["TMUX"]
    end

    # The tmux.conf to edit: an explicit override, else the conf the running server loaded
    # (a standard location first, else the first file under $HOME — skipping system files
    # like /opt/homebrew/etc/tmux.conf), else the first standard location that exists, else
    # ~/.tmux.conf.
    def tmux_conf(override = nil)
      return File.expand_path(override) if override && !override.to_s.empty?

      loaded_user_conf || default_confs.find { |p| File.exist?(p) } || File.expand_path("~/.tmux.conf")
    end

    # Where tmux itself looks, in its order (3.2+ also reads $XDG_CONFIG_HOME/tmux).
    def default_confs
      xdg = Switchboard.env("XDG_CONFIG_HOME").to_s
      [File.expand_path("~/.tmux.conf"), (File.join(xdg, "tmux", "tmux.conf") unless xdg.empty?),
       File.expand_path("~/.config/tmux/tmux.conf")].compact.uniq
    end

    # The conf the running server loaded. Asked from outside tmux too (display-message works
    # against a server with no attached client), so a plain-shell upgrade finds a conf tmux
    # loaded from anywhere; nil with no server running.
    # The server lists every file it loaded, sourced ones included (a theme, a plugin), so a
    # standard location wins; else the first under $HOME (a --tmux-conf file).
    def loaded_user_conf
      home = File.expand_path("~")
      return nil if home == "/" # every path would read as "under $HOME"

      files = `tmux -u display-message -p '#\{config_files}' 2>/dev/null`.strip
              .split(",").map(&:strip).select { |f| File.exist?(f) }
      files.find { |f| default_confs.include?(f) } || files.find { |f| f.start_with?(File.join(home, "")) }
    end

    # What prefix-<key> is currently bound to (for the "we're taking it" note), or
    # nil. Best-effort: only meaningful inside a running server.
    def prefix_binding(key)
      return nil unless ENV["TMUX"]

      prefix_binding_from(`tmux -u list-keys -T prefix 2>/dev/null`, key)
    end

    # Pure: the command `key` is bound to in `tmux list-keys -T prefix` output, or
    # nil. Split from the shell-out so the clobber/"was:" lookups are unit-testable.
    def prefix_binding_from(raw, key)
      raw.to_s.lines.each do |line|
        m = line.match(/-T\s+prefix\s+(\S+)\s+(.*)$/)
        return m[2].strip if m && m[1] == key
      end
      nil
    end

    def warn_path
      return if homebrew?
      return if Switchboard.env("PATH").to_s.scrub.split(File::PATH_SEPARATOR).map { |p| File.expand_path(p) }.include?(bin_dir)

      note "#{bin_dir} isn't on your PATH — add this to your shell profile:"
      puts "      export PATH=\"#{bin_dir}:$PATH\""
    end

    # Popup is gone, so there's no hard floor; indexed session hooks want >= 3.0.
    def warn_tmux_version
      v = tmux_version
      return if v.nil? || v >= 3.0

      note "tmux #{v} is old — the session-switch sidebar refresh needs tmux >= 3.0 (toggle still works)"
    end

    def ok(msg)
      puts "  \e[32m✓\e[0m #{msg}"
    end

    def bad(msg)
      puts "  \e[31m✗\e[0m #{msg}"
    end

    def note(msg)
      puts "  \e[33m–\e[0m #{msg}"
    end
  end
end

require_relative "installer/keybindings"
