# frozen_string_literal: true

require "fileutils"
require "shellwords"
require_relative "marker_block"
require_relative "codex_hook"

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

    # Repo root from this file (lib/switchboard/installer.rb → ../..). Works
    # through a PATH symlink: require resolves to the real file, so __dir__ is
    # the real lib dir — which StablePath lifts out of a versioned Homebrew keg.
    def repo_root
      StablePath.resolve(real_root)
    end

    # Installed by Homebrew, which already put `switchboard` on PATH — so install
    # skips the ~/.local/bin symlinks (and uninstall leaves PATH to `brew uninstall`).
    def homebrew?
      StablePath.homebrew?(real_root)
    end

    def real_root
      File.expand_path("../..", __dir__)
    end

    def bin_path
      File.join(repo_root, "bin", "switchboard")
    end

    def fragment_path
      File.join(repo_root, "switchboard.tmux")
    end

    def bin_dir
      File.expand_path(ENV["SWITCHBOARD_BIN_DIR"] || "~/.local/bin")
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
      step_codex_hooks(codex_hooks)
      warn_path
      warn_tmux_version
      key = Config.new.tmux_key("toggle")
      puts "\nDone — run `switchboard` (or `sb`) from any shell to start; press prefix-#{key} to toggle the sidebar inside tmux."
      puts "(If the key doesn't respond yet, reload tmux: `tmux source-file <your conf>`.)"
    end

    # Codex can't discover project-local hooks in linked worktrees, so its agent-state
    # hooks ship as ONE block in the user's global `~/.codex/config.toml`. Writing the
    # user's global config is opt-in: ask (default no on a non-tty / `--no-codex-hooks`).
    # `consent`: nil ⇒ prompt, true ⇒ yes (`--codex-hooks`), false ⇒ skip.
    def step_codex_hooks(consent)
      return unless codex_present?

      # Already opted in → re-ensure the block (idempotent + byte-stable, so codex's
      # hash-keyed `/hooks` trust survives) so `install` doubles as a repair path: it
      # refreshes a block left stale by an upgrade or a moved reporter script. No re-prompt
      # — consent was given when it was first added.
      return report_codex_install(CodexHook.install_global, reensure: true) if CodexHook.installed?
      return if consent == false

      ok_to_write = consent || prompt_yes?("Install codex hooks globally for agent status monitoring? Writes a managed block to #{CodexHook.config_path}.")
      unless ok_to_write
        note "codex hooks skipped — re-run `install --codex-hooks` to opt in later"
        return
      end

      report_codex_install(CodexHook.install_global, reensure: false)
    end

    def report_codex_install(result, reensure:)
      case result
      when :collision then bad "codex hooks: #{CodexHook.config_path} already has its own [hooks] — left untouched"
      when :corrupt   then bad "codex hooks: post-write sanity failed — restored your config"
      when nil        then bad "codex hooks: couldn't write #{CodexHook.config_path}"
      else
        ok(reensure ? "codex hooks re-ensured (global): #{CodexHook.config_path}" : "codex hooks installed: #{CodexHook.config_path}")
        note "one-time: run `/hooks` in codex and trust the switchboard hooks (or start codex with --dangerously-bypass-hook-trust)" unless reensure
      end
    end

    def codex_present?
      File.directory?(File.expand_path(ENV["CODEX_HOME"] || "~/.codex")) ||
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
      unlink_symlink
      unwire_tmux(conf)
      step_codex_unhooks
      teardown_live
      puts "\nDone. Your config (#{Config.path}) and agent state were left untouched."
    end

    # Remove the global codex [hooks] block (the one place codex delivery is global). The
    # per-worktree disable-hooks deliberately leaves it; full teardown removes it.
    def step_codex_unhooks
      return unless CodexHook.installed?

      CodexHook.remove_global
      ok "removed global codex hooks from #{CodexHook.config_path}"
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
        backup(conf)
        atomic_write(conf, strip_block(File.read(conf)))
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
      %w[toggle home].each do |role|
        recorded = tmux_option("@switchboard-#{role}-key")
        run_tmux("unbind-key", recorded) if recorded
        run_tmux("set-option", "-gu", "@switchboard-#{role}-key")
        run_tmux("set-option", "-gu", "@switchboard-#{role}-clobbered")
      end
      run_tmux("unbind-key", "s") # legacy default — covers installs predating the @option record
      HOOK_SLOTS.each { |slot| run_tmux("set-hook", "-gu", slot) }
    end

    # --- keybindings (the `tmux-bind` entry point) ---------------------------

    # Per-role tmux subcommand the bound key runs. Roles match Config's tmux_keys.
    ROLE_SUBCOMMANDS = { "toggle" => "toggle-sidebar", "home" => "home" }.freeze

    # Bind the configured toggle/home keys and clean up the ones we previously bound.
    # Run by switchboard.tmux on every tmux reload AND by the interactive config-edit
    # reload (announce: true → it reports the result, DX2). The cleanup tracks the
    # last key WE bound in tmux @options rather than scanning list-keys, so it never
    # clobbers a user's own switchboard binding and survives a repo move. Server ops,
    # no TMUX gate; every call degrades on failure.
    #
    #   per role: bind desired FIRST → unbind the key we recorded last → record the
    #   new key → capture/clear a clobbered foreign binding (for doctor). A rejected
    #   bind falls back (toggle → s) WITHOUT cleaning, so the recovery key is safe.
    def apply_keybindings(announce: false, config: Config.new)
      raw = list_prefix_keys
      legacy = tmux_option("@switchboard-toggle-key").nil? && toggle_key_live_from?(raw, "s")
      bound = ROLE_SUBCOMMANDS.keys.to_h do |role|
        desired = config.tmux_key(role)
        recorded = tmux_option("@switchboard-#{role}-key")
        clobbered = desired && desired != recorded ? foreign_binding(raw, desired, ROLE_SUBCOMMANDS[role]) : nil
        [role, run_rebind(role, desired, recorded: recorded, legacy_toggle: legacy, clobbered: clobbered)]
      end
      announce_bindings(bound) if announce
    end

    # Pure: the ordered tmux ops to converge `role` onto `desired`. Symbolic tuples
    # (translated by tmux_argv), bind FIRST so a failed bind never strands the user.
    # nil desired ⇒ clean the role up (unbind what we recorded, forget it).
    def rebind_ops(role, desired, recorded:, legacy_toggle: false, clobbered: nil)
      ops = []
      if desired.nil?
        ops << [:unbind, recorded] if recorded
        ops << [:clear_key, role]
        ops << [:clear_clobber, role]
        return ops
      end
      ops << [:bind, role, desired]
      ops << [:unbind, recorded] if recorded && recorded != desired
      ops << [:unbind, "s"] if role == "toggle" && legacy_toggle && desired != "s" && recorded != "s"
      ops << [:set_key, role, desired]
      ops << (clobbered ? [:set_clobber, role, clobbered] : [:clear_clobber, role])
      ops
    end

    # Translate a symbolic rebind op to a tmux argv array (no shell). The bind mirrors
    # the fragment's quoting — '<bin>' in single quotes so a path with spaces survives
    # the /bin/sh that run-shell hands the command to.
    def tmux_argv(op)
      case op[0]
      when :bind          then ["bind-key", op[2], "run-shell", "'#{bin_path}' #{ROLE_SUBCOMMANDS[op[1]]}"]
      when :unbind        then ["unbind-key", op[1]]
      when :set_key       then ["set-option", "-g", "@switchboard-#{op[1]}-key", op[2]]
      when :clear_key     then ["set-option", "-gu", "@switchboard-#{op[1]}-key"]
      when :set_clobber   then ["set-option", "-g", "@switchboard-#{op[1]}-clobbered", op[2]]
      when :clear_clobber then ["set-option", "-gu", "@switchboard-#{op[1]}-clobbered"]
      end
    end

    # Execute one role's ops, bind-first. If tmux rejects the key (denylist let it
    # through but it's not a real key), keep a working toggle by binding the default
    # and bail WITHOUT cleaning or recording; leave home unbound. Returns the key
    # actually bound to our command, or nil.
    def run_rebind(role, desired, recorded:, legacy_toggle:, clobbered:)
      ops = rebind_ops(role, desired, recorded: recorded, legacy_toggle: legacy_toggle, clobbered: clobbered)
      if desired.nil?
        ops.each { |op| run_tmux(*tmux_argv(op)) }
        return nil
      end

      bind_op, *rest = ops
      unless run_tmux(*tmux_argv(bind_op))
        # tmux rejected the key (the denylist passed, but it's not a real key).
        # Recover THROUGH rebind so the rejected attempt AND any previously-recorded
        # key get cleaned and the @option reflects what's actually bound — else a
        # stale binding lingers across a later config change. Toggle recovers to the
        # default (a working key survives); home recovers to unbound. Guard the
        # toggle's self-recursion if the default itself can't bind.
        recovery = role == "toggle" ? Config::TMUX_KEY_DEFAULTS["toggle"] : nil
        return nil if recovery == desired

        return run_rebind(role, recovery, recorded: recorded, legacy_toggle: legacy_toggle, clobbered: nil)
      end
      rest.each { |op| run_tmux(*tmux_argv(op)) }
      desired
    end

    # One tmux command (argv, no shell), output swallowed; returns success. The single
    # seam every binding side-effect goes through, so tests assert the exact command
    # sequence without a tmux server.
    def run_tmux(*argv)
      system("tmux", *argv, out: File::NULL, err: File::NULL)
    end

    # Raw `tmux list-keys -T prefix` output (a stubbable seam; offline tests fake it).
    def list_prefix_keys
      `tmux list-keys -T prefix 2>/dev/null`
    end

    # A global tmux user option's value, or nil when unset / no server.
    def tmux_option(name)
      v = `tmux show-options -gqv #{Shellwords.escape(name)} 2>/dev/null`.strip
      $?.success? && !v.empty? ? v : nil
    end

    # The foreign command `key` is currently bound to (NOT one of ours), or nil — so
    # doctor can warn before tmux-bind clobbers it. Ours = a switchboard run-shell
    # for this role.
    def foreign_binding(raw, key, subcommand)
      binding = prefix_binding_from(raw, key)
      return nil if binding.nil? || (binding.include?("'#{bin_path}'") && binding.include?(subcommand))

      binding
    end

    # DX2: after an interactive rebind, show what's bound so the user sees it took
    # effect instead of having to test the key. `bound` is role => bound-key-or-nil.
    def announce_bindings(bound)
      desc = { "toggle" => "toggles the sidebar", "home" => "jumps home" }
      parts = bound.filter_map { |role, key| "prefix-#{key} #{desc[role]}" if key }
      run_tmux("display-message", "switchboard: #{parts.join(', ')}") unless parts.empty?
    end

    # Which of switchboard's indexed hooks are actually LIVE in the running tmux
    # server (slot => bool), or nil when there's no server to ask. tmux_wired?
    # checks the config FRAGMENT is sourced; this checks the hooks took — they don't
    # until tmux reloads its config, so after a `git pull` upgrade the new slot reads
    # live: false here while tmux_wired? still says true. `doctor` surfaces the gap.
    # A server op (show-hooks -g), so it works from a plain shell too, no client needed.
    def live_hooks
      raw = `tmux show-hooks -g 2>/dev/null`
      $?.success? ? live_hooks_from(raw) : nil
    end

    # Pure: which slots appear in `tmux show-hooks -g` output. Split out so the
    # parse is unit-testable without a tmux server.
    def live_hooks_from(raw)
      HOOK_SLOTS.to_h { |slot| [slot, raw.to_s.include?(slot)] }
    end

    # Is prefix-s actually bound to toggle-sidebar in the RUNNING server? Pairs with
    # live_hooks: an upgrade that hasn't re-sourced the fragment can leave prefix-s
    # unbound — or carrying an ancient binding (e.g. the retired fzf-popup on
    # prefix-S) — while tmux_wired? still reads true off the config. That's the
    # "prefix-s stopped working after a git pull" case, invisible until you press it.
    # nil = no server to ask (a server op via list-keys; no client needed).
    def toggle_key_live?
      raw = `tmux list-keys -T prefix 2>/dev/null`
      $?.success? ? toggle_key_live_from?(raw, Config.new.tmux_key("toggle")) : nil
    end

    # Pure: does `tmux list-keys -T prefix` show `key` bound to toggle-sidebar?
    # Whitespace-bounded so a multi-char key never matches a prefix of itself; the
    # command must mention toggle-sidebar so a foreign binding doesn't read as ours.
    # Defaults to `s` (the historical key) so legacy-detection callers read clean.
    def toggle_key_live_from?(raw, key = "s")
      raw.to_s.lines.any? { |l| l.match?(/-T prefix\s+#{Regexp.escape(key)}\s/) && l.include?("toggle-sidebar") }
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
      parse_version(`tmux -V 2>/dev/null`)
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
      system("tmux", "source-file", conf, out: File::NULL, err: File::NULL) if ENV["TMUX"]
    end

    # The tmux.conf to edit: an explicit override, else the first $HOME-rooted
    # file tmux actually loaded (asked of the running server — skips system
    # files like /opt/homebrew/etc/tmux.conf), else the conventional fallback.
    def tmux_conf(override = nil)
      return File.expand_path(override) if override && !override.to_s.empty?

      loaded_user_conf ||
        [File.expand_path("~/.tmux.conf"), File.expand_path("~/.config/tmux/tmux.conf")].find { |p| File.exist?(p) } ||
        File.expand_path("~/.tmux.conf")
    end

    def loaded_user_conf
      return nil unless ENV["TMUX"]

      home = File.expand_path("~")
      `tmux display-message -p '#\{config_files}' 2>/dev/null`.strip
        .split(",").map(&:strip)
        .find { |f| f.start_with?(home) && File.exist?(f) }
    end

    # What prefix-<key> is currently bound to (for the "we're taking it" note), or
    # nil. Best-effort: only meaningful inside a running server.
    def prefix_binding(key)
      return nil unless ENV["TMUX"]

      prefix_binding_from(`tmux list-keys -T prefix 2>/dev/null`, key)
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
      return if ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |p| File.expand_path(p) }.include?(bin_dir)

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
