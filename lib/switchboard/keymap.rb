# frozen_string_literal: true

module Switchboard
  # The canonical surface of the in-sidebar keys (issue #108). ONE ordered enum of
  # ACTIONS is the single source of truth feeding three consumers so they can never
  # drift apart: the sidebar's `dispatch` (key -> action), the `?` help overlay
  # (action -> the key it shows), and `doctor` (validity + collision reports).
  #
  # Each action's `default` key is user-overridable via `sidebar_keys:` in config
  # (resolve-with-default, the same shape as `tmux_keys:` / `sounds:`). Its
  # `aliases` are the always-on structural bytes (movement arrows, ^N/^P, ^O) that
  # are NEVER configurable and never collide — they're non-printable, which
  # Config#valid_sidebar_key? forbids as overrides, so a printable override can't
  # land on one. That also means you can't lock yourself out of movement: even if
  # the `j` letter collides away, ↑/↓/^N/^P still move.
  #
  # Structural keys with their own control flow (↵ context-action, ←/→ resize, the
  # C-l/C-r pokes, focus in/out) live in `dispatch`'s literal case, NOT here —
  # they're reserved, not remappable.
  module Keymap
    module_function

    # name: the action symbol dispatch fires on; default: the remappable key;
    # aliases: fixed structural byte-strings that always also trigger it.
    Action = Struct.new(:name, :default, :aliases, keyword_init: true)

    mk = ->(name, default, *aliases) { Action.new(name: name, default: default, aliases: aliases) }

    # Order matters in exactly one place: collision tie-breaking. When two actions
    # resolve to the same key, the earlier one here keeps it (the later drops to
    # unbound + a doctor report). The list otherwise reads top-to-bottom like the
    # overlay: move, jump, then the per-row and global actions.
    ACTIONS = [
      mk.call(:down,               "j", "\e[B", "\x0E"), # ↓  ^N
      mk.call(:up,                 "k", "\e[A", "\x10"), # ↑  ^P
      mk.call(:top,                "g"),
      mk.call(:bottom,             "G"),
      mk.call(:filter,             "/"),
      mk.call(:add_project,        "a"),
      mk.call(:new_workspace,      "n"),
      mk.call(:open_pr,            "o", "\x0F"),         # ^O
      mk.call(:open_repo,          "O"),
      mk.call(:rename,             "r"),
      mk.call(:delete,             "d"),
      mk.call(:edit_config,        "e"),
      mk.call(:refresh_prs,        "R"),
      mk.call(:toggle_branch_fold, "z"),
      mk.call(:toggle_full_header, "H"),
      mk.call(:help,               "?"),
      mk.call(:quit,               "q")
    ].freeze

    DEFAULTS = ACTIONS.to_h { |a| [a.name, a.default] }.freeze

    # Resolve config into [bindings, collisions]:
    #   bindings:   { action => key | nil }  (nil when the action's key was claimed
    #               by an earlier action — left unbound, its aliases still fire)
    #   collisions: [{ action:, key:, winner: }, ...]  for doctor to report
    # An override wins only when it validates AND its key is still free; otherwise
    # the action falls back to its default, and a default that's also taken drops
    # to nil. Deterministic by ACTIONS order. The shared core of every accessor
    # below, so dispatch / help / doctor never disagree about who owns a key.
    def resolve_with_collisions(config)
      taken = {}
      bindings = {}
      collisions = []
      ACTIONS.each do |a|
        raw = config.raw_sidebar_key(a.name)
        key = config.valid_sidebar_key?(raw) ? raw : a.default
        if (winner = taken[key])
          bindings[a.name] = nil
          collisions << { action: a.name, key: key, winner: winner }
        else
          taken[key] = a.name
          bindings[a.name] = key
        end
      end
      [bindings, collisions]
    end

    # { action => resolved key | nil } — what the help overlay and doctor read.
    def bindings(config)
      resolve_with_collisions(config).first
    end

    # The collision reports (empty when the config is clean) — doctor surfaces them.
    def collisions(config)
      resolve_with_collisions(config).last
    end

    # Resolve config into BOTH lookups the sidebar needs in a SINGLE pass: the
    # dispatch map (key -> action) and the bindings (action -> key). Sidebar's
    # resolve_keymap runs every rebuild (switch-in / idle / tree-tick), so doing
    # one walk of ACTIONS instead of resolving twice matters on that periodic
    # path. Returns [keymap, bindings].
    def resolve(config)
      binds = bindings(config)
      [keymap_for(binds), binds]
    end

    # The dispatch lookup: { key => action }, the resolved configurable keys PLUS
    # every action's always-on structural aliases (arrows / ^N / ^P / ^O). What
    # the sidebar's `dispatch` keys off. Aliases are added last but never clobber a
    # binding — they're non-printable and bindings are printable, so they're
    # disjoint.
    def dispatch_map(config)
      keymap_for(bindings(config))
    end

    # Build the dispatch map from an already-resolved `bindings` hash (so callers
    # that also need the bindings don't re-resolve). Pure.
    def keymap_for(bindings)
      map = {}
      bindings.each { |action, key| map[key] = action if key }
      ACTIONS.each { |a| a.aliases.each { |al| map[al] = a.name } }
      map
    end

    # The `?` overlay's [key_label, description] rows, built from the resolved
    # `bindings` so the shown keys never drift from what `dispatch` honors. A row
    # with an empty key is a section heading. Keys that aren't configurable (↵,
    # ←/→, ^n/^p, the filter- and prompt-mode escapes) are literal here — they're
    # reserved structural keys. Under the default bindings this is byte-identical
    # to the pre-#108 static map. A collision-dropped action shows an em-dash.
    def help_rows(bindings)
      k = ->(name) { bindings[name] || "—" }
      [
        ["", "navigate"],
        ["↑ ↓  ^n ^p  #{k[:down]} #{k[:up]}", "move"],
        ["#{k[:top]}  #{k[:bottom]}", "top · bottom"],
        ["←  →", "narrow · widen pane"],
        ["", "open"],
        ["↵", "open · collapse"],
        [k[:filter], "filter by name"],
        ["", "the selected row"],
        [k[:add_project], "add a project"],
        [k[:new_workspace], "new workspace (auto-named)"],
        ["#{k[:open_pr]}  ^o", "open its PR"],
        [k[:open_repo], "open its repo"],
        [k[:rename], "rename workspace"],
        [k[:delete], "delete · remove"],
        ["", "anywhere"],
        [k[:edit_config], "edit settings"],
        [k[:refresh_prs], "refresh PR badges"],
        [k[:toggle_branch_fold], "fold · unfold branches"],
        [k[:toggle_full_header], "toggle full header"],
        [k[:help], "this help"],
        [k[:quit], "quit all sessions"],
        ["", "filter mode  (#{k[:filter]})"],
        ["↵", "open · create"],
        ["Esc", "cancel"],
        ["Bksp", "trim · exit when empty"],
        ["", "name prompts"],
        ["↵", "submit"],
        ["Esc", "cancel"],
        ["Bksp · ^u", "erase · clear"],
        ["", "diff counts"],
        ["+/−", "committed diff vs base"]
      ]
    end
  end
end
