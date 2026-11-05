# frozen_string_literal: true

module Switchboard
  # The keybinding engine, the `tmux-bind` entry point: binds the configured keys, cleans up the
  # ones it bound before, and answers doctor's questions about what tmux has live.
  module Installer
    module_function

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
      # A config that won't parse says nothing about the keys: keep the last-good ones, the way
      # the sidebar keeps its last-good config. Re-bound, not just left, since a tmux.conf
      # reload can drop a binding while its @option lives on. Defaults only when none are recorded.
      if config.load_error
        recorded = ROLE_SUBCOMMANDS.each_key.to_h { |role| [role, tmux_option("@switchboard-#{role}-key")] }.compact
        unless recorded.empty?
          recorded.each { |role, key| run_tmux(*tmux_argv([:bind, role, key])) }
          notify("switchboard: config.yml won't parse — tmux keys left as they were") if announce
          return
        end
      end

      raw = list_prefix_keys
      legacy = tmux_option("@switchboard-toggle-key").nil? && toggle_key_live_from?(raw, "s")
      wanted = ROLE_SUBCOMMANDS.keys.to_h { |role| [role, config.tmux_key(role)] }
      bound = {}
      ROLE_SUBCOMMANDS.each_key do |role|
        desired = wanted[role]
        recorded = tmux_option("@switchboard-#{role}-key")
        # A key another role wants or now holds stays bound (toggle and home swapped):
        # unbinding it here would delete the binding that role just made, or is about to make.
        taken = (wanted.reject { |r, _| r == role }.values + bound.values).compact.uniq
        # The toggle fell back onto this key (tmux refused the configured one): the toggle
        # keeps it, and this role reads as refused instead of silently taking it away.
        yielded = desired && bound.any? { |r, key| key == desired && key != wanted[r] }
        desired = nil if yielded
        clobbered = desired && desired != recorded ? foreign_binding(raw, desired) : nil
        bound[role] = run_rebind(role, desired, recorded: recorded, legacy_toggle: legacy, clobbered: clobbered, taken: taken)
        run_tmux("set-option", "-g", "@switchboard-#{role}-rejected", wanted[role]) if yielded
      end
      # Which config file these keys came from: key_drift? only judges against the same one
      # (a shell and a tmux server can resolve config.yml differently).
      run_tmux("set-option", "-g", "@switchboard-config-path", File.expand_path(config.file))
      announce_bindings(bound) if announce
    end

    # Pure: the ordered tmux ops to converge `role` onto `desired`. Symbolic tuples
    # (translated by tmux_argv), bind FIRST so a failed bind never strands the user.
    # nil desired ⇒ clean the role up (unbind what we recorded, forget it).
    def rebind_ops(role, desired, recorded:, legacy_toggle: false, clobbered: nil, taken: [])
      ops = []
      if desired.nil?
        ops << [:unbind, recorded] if recorded && !taken.include?(recorded)
        ops << [:clear_key, role]
        ops << [:clear_clobber, role]
        return ops
      end
      ops << [:bind, role, desired]
      ops << [:unbind, recorded] if recorded && recorded != desired && !taken.include?(recorded)
      ops << [:unbind, "s"] if role == "toggle" && legacy_toggle && desired != "s" && recorded != "s" && !taken.include?("s")
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
    # through but it's not a real key), recover through a rebind (toggle to the default,
    # home to unbound) and remember the refused key in @switchboard-<role>-rejected, so a
    # config still naming it doesn't read as an unapplied edit. Returns the key actually
    # bound to our command, or nil.
    def run_rebind(role, desired, recorded:, legacy_toggle:, clobbered:, taken: [])
      ops = rebind_ops(role, desired, recorded: recorded, legacy_toggle: legacy_toggle, clobbered: clobbered, taken: taken)
      if desired.nil?
        ops.each { |op| run_tmux(*tmux_argv(op)) }
        run_tmux("set-option", "-gu", "@switchboard-#{role}-rejected")
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

        bound = run_rebind(role, recovery, recorded: recorded, legacy_toggle: legacy_toggle, clobbered: nil, taken: taken)
        # After the recovery (which clears it): remember the key tmux refused, so a config
        # still naming it doesn't read as an unapplied edit (key_drift?).
        run_tmux("set-option", "-g", "@switchboard-#{role}-rejected", desired)
        return bound
      end
      rest.each { |op| run_tmux(*tmux_argv(op)) }
      run_tmux("set-option", "-gu", "@switchboard-#{role}-rejected")
      desired
    end

    # One tmux command (argv, no shell), output swallowed; returns success. The single
    # seam every binding side-effect goes through, so tests assert the exact command
    # sequence without a tmux server.
    def run_tmux(*argv)
      # tmux reads an argument ending in `;` as the end of a command: `bind-key C-;` binds
      # "C-" (and fails), `set-option … C-;` stores "C-". Escaped, tmux takes the `;` literally.
      argv = argv.map { |a| a.is_a?(String) && a.end_with?(";") && !a.end_with?("\\;") ? "#{a.chop}\\;" : a }
      system("tmux", "-u", *argv, out: File::NULL, err: File::NULL)
    end

    # Raw `tmux list-keys -T prefix` output (a stubbable seam; offline tests fake it).
    def list_prefix_keys
      `tmux -u list-keys -T prefix 2>/dev/null`
    end

    # A global tmux user option's value, or nil when unset / no server.
    def tmux_option(name)
      v = `tmux -u show-options -gqv #{Shellwords.escape(name)} 2>/dev/null`.strip
      $?.success? && !v.empty? ? v : nil
    end

    # The foreign command `key` is currently bound to (NOT one of ours), or nil — so
    # doctor can warn before tmux-bind clobbers it.
    def foreign_binding(raw, key)
      binding = prefix_binding_from(raw, key)
      return nil if binding.nil? || ours?(binding)

      binding
    end

    # Our own binding of EITHER role (a toggle/home swap finds each key still bound to the
    # other role, which is no clobber): our bin path followed by a role's exact subcommand.
    def ours?(binding)
      subs = ROLE_SUBCOMMANDS.values.map { |sub| Regexp.escape(sub) }.join("|")
      binding.match?(/'#{Regexp.escape(bin_path)}' (?:#{subs})(?=["\s]|\z)/)
    end

    # DX2: after an interactive rebind, show what's bound so the user sees it took
    # effect instead of having to test the key. `bound` is role => bound-key-or-nil.
    def announce_bindings(bound)
      desc = { "toggle" => "toggles the sidebar", "home" => "jumps home" }
      parts = bound.filter_map { |role, key| "prefix-#{key} #{desc[role]}" if key }
      notify("switchboard: #{parts.join(', ')}") unless parts.empty?
    end

    # Tmux.notify through the run_tmux/tmux_option seams: the same hold, fallback and escaping.
    def notify(message)
      run_tmux(*Tmux.notify_args(message, tmux_option("display-time"))) ||
        run_tmux("display-message", Tmux.literal(message))
    end

    # Which of switchboard's indexed hooks are actually LIVE in the running tmux
    # server (slot => bool), or nil when there's no server to ask. tmux_wired?
    # checks the config FRAGMENT is sourced; this checks the hooks took — they don't
    # until tmux reloads its config, so after a `git pull` upgrade the new slot reads
    # live: false here while tmux_wired? still says true. `doctor` surfaces the gap.
    # A server op (show-hooks -g), so it works from a plain shell too, no client needed.
    def live_hooks
      raw = `tmux -u show-hooks -g 2>/dev/null`
      $?.success? ? live_hooks_from(raw) : nil
    end

    # Pure: which slots appear in `tmux show-hooks -g` output. Split out so the
    # parse is unit-testable without a tmux server.
    def live_hooks_from(raw)
      HOOK_SLOTS.to_h { |slot| [slot, raw.to_s.include?(slot)] }
    end

    # Is the toggle key actually bound to toggle-sidebar in the RUNNING server? Pairs with
    # live_hooks: an upgrade that hasn't re-sourced the fragment can leave the key unbound
    # — or carrying an ancient binding (e.g. the retired fzf-popup on prefix-S) — while
    # tmux_wired? still reads true off the config. That's the "toggle key stopped
    # working after a git pull" case, invisible until you press it.
    # nil = no server to ask: list-keys alone would start one and list tmux's defaults.
    def toggle_key_live?(key = bound_toggle_key)
      return nil unless tmux_server?

      # Naming the key lets tmux parse it with bind-key's own parser, so any spelling it
      # accepts (`^B`, `M-#`, `f5`) resolves; an unbound key exits non-zero.
      # A trailing `;` ends a tmux command (leaving `list-keys -T prefix`, the whole table), so
      # it's escaped the way bind-key needs it.
      one = `tmux -u list-keys -T prefix -- #{Shellwords.escape(key.to_s.sub(/;\z/) { "\\;" })} 2>/dev/null`
      return one.scrub.include?("toggle-sidebar") if $?.success?

      # Unbound, or a tmux too old to take a key here: read the whole table.
      all = `tmux -u list-keys -T prefix 2>/dev/null`
      $?.success? ? toggle_key_live_from?(all, key) : nil # a failed read says nothing either way
    end

    # Does config.yml name a different key for `role` than tmux-bind last applied? Checked
    # against what was bound AND what tmux refused (that one fell back on purpose), so only a
    # hand edit nobody re-applied reads as drift. nil = can't tell (no tmux server, or config.yml
    # didn't parse).
    def key_drift?(role, config: Config.new)
      return nil unless bound_from?(config)

      key_drift_from?(config.tmux_key(role), tmux_option("@switchboard-#{role}-key"),
                      tmux_option("@switchboard-#{role}-rejected"))
    end

    # The configured key for `role` that isn't bound because tmux refused it (or, for home,
    # the toggle fell back onto it); nil otherwise or when there's no verdict.
    def refused_key(role, config: Config.new)
      return nil unless bound_from?(config)

      refused = tmux_option("@switchboard-#{role}-rejected")
      refused if refused && refused == config.tmux_key(role)
    end

    # Did tmux bind its keys from THIS config? Otherwise its options say nothing about it:
    # a config that won't parse reads as defaults, a shell and the tmux server can resolve
    # config.yml differently, an older switchboard didn't record it, or a tmux read failed.
    def bound_from?(config)
      return false if config.load_error || !tmux_server?

      bound_from = tmux_option("@switchboard-config-path")
      !bound_from.nil? && bound_from == File.expand_path(config.file)
    end

    # Pure core of key_drift? (nil = unbound on each side).
    def key_drift_from?(configured, recorded, rejected)
      configured != recorded && (rejected.nil? || configured != rejected)
    end

    # The toggle key switchboard last bound — its fallback when tmux rejected the configured
    # one (apply_keybindings records it), else the configured key.
    def bound_toggle_key(config: Config.new)
      tmux_option("@switchboard-toggle-key") || config.tmux_key("toggle")
    end

    # Pure: does `tmux list-keys -T prefix` show `key` bound to toggle-sidebar?
    # Whitespace-bounded so a multi-char key never matches a prefix of itself; the
    # command must mention toggle-sidebar so a foreign binding doesn't read as ours.
    # Defaults to `s` (the historical key) so legacy-detection callers read clean.
    def toggle_key_live_from?(raw, key = "s")
      # tmux lists punctuation keys escaped (`\$`, `\#`), so allow the backslash.
      raw.to_s.scrub.lines.any? { |l| l.match?(/-T prefix\s+\\?#{Regexp.escape(key)}\s/) && l.include?("toggle-sidebar") }
    end
  end
end
