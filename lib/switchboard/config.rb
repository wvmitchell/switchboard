# frozen_string_literal: true

require "yaml"
require "fileutils"

module Switchboard
  # Switchboard's own project registry — what lets it stand alone, with no
  # emdash (or Conductor) database at runtime. Lives at
  # ~/.config/switchboard/config.yml, created empty by `switchboard install`
  # (or `init`) and grown by the add-project flow.
  class Config
    DEFAULT_PATH = File.expand_path("~/.config/switchboard/config.yml")
    DEFAULT_ROOT = "~/switchboard/worktrees"
    DEFAULT_PROJECTS_ROOT = "~/Programming" # where the clone action drops repos

    # Built-in sound name per resting state; the Sound module synthesizes + caches
    # these. Overridable globally or per project via a `sounds:` map.
    DEFAULT_SOUNDS = { "done" => "train", "waiting" => "chime" }.freeze

    # Default tmux key per configurable role (`tmux_keys:` map). The toggle defaults
    # to `s` (switchboard's historical binding); home is unbound by default (nil) —
    # an optional one-key jump the user opts into. nil ⇒ "don't bind this role".
    TMUX_KEY_DEFAULTS = { "toggle" => "s", "home" => nil }.freeze

    def self.path
      ENV["SWITCHBOARD_CONFIG"] || DEFAULT_PATH
    end

    def self.exist?
      File.exist?(path)
    end

    # The effective shape of an empty switchboard config — the source of truth that
    # `scaffold`'s template must parse to, and `add_project`'s fresh-file fallback.
    # Fresh hash each call (never a shared mutable constant).
    def self.default_data
      { "worktree_root" => DEFAULT_ROOT, "projects" => [] }
    end

    # The annotated config `scaffold` writes for a fresh install, so the optional
    # knobs are discoverable in the file itself, not just the README. ONLY
    # worktree_root + projects are uncommented, so it parses to exactly default_data
    # (config_test pins this) and the effective config is unchanged; every other knob
    # is a commented example at its default. The comments are stripped the first time
    # add_project rewrites the file via YAML.dump — by then the new user has read them
    # (preserving them would need a comment-aware emitter; out of scope for stdlib).
    SCAFFOLD_TEMPLATE = <<~YAML
      # switchboard config — see the README "Config" section for the full reference.
      # Uncommented keys are active; the commented ones below show every optional knob
      # at its default. Uncomment and edit what you want, then save.

      worktree_root: "#{DEFAULT_ROOT}"   # where `n` puts new worktrees
      # projects_root: "#{DEFAULT_PROJECTS_ROOT}"        # where `a` / clone drop fetched repos
      # base: origin/main                          # default ref new worktrees branch from
      # branch_prefix: ""                          # new branches become <prefix>/<name>
      # session_command: ""                        # run on a worktree's first session (e.g. claude --dangerously-skip-permissions)
      # agent_state_hooks: true                    # auto-wire the agent-state dots on worktree create
      # prune_on_launch: true                      # prune orphaned sb/ sessions when landing on home

      # Completion sounds (on by default): a built-in (train / chime, or train_1..3 /
      # chime_1..3), a file path, or a macOS system-sound name. enabled: false mutes all.
      # sounds:
      #   enabled: true
      #   done: train
      #   waiting: chime

      # Prefix keys switchboard binds. toggle defaults to s; home is unbound unless set.
      # A key is a char, a named key (Space, F1, BSpace), or a C-/M- combo.
      # tmux_keys:
      #   toggle: s
      #   home: S

      projects: []   # grown by `a` in the sidebar or `switchboard add <name> <path>`
    YAML

    # Write the annotated default config if none exists yet; return the path either
    # way. Never clobbers an existing file (even a malformed/empty one) — callers that
    # want to read or seed it open the real file. Idempotent.
    def self.scaffold
      file = path
      unless File.exist?(file)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, SCAFFOLD_TEMPLATE)
      end
      file
    end

    # Append a project to the on-disk config, preserving the existing raw
    # structure (unexpanded paths and per-project keys). The single config-write
    # path shared by the CLI `add`/`clone` and the sidebar's add action, so the
    # two never drift. Returns the written entry.
    def self.add_project(name, repo, base = nil)
      file = path
      data = File.exist?(file) ? (YAML.safe_load_file(file) || {}) : default_data
      entry = { "name" => name, "path" => repo }
      entry["base"] = base if base
      (data["projects"] ||= []) << entry
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, YAML.dump(data))
      entry
    end

    # Drop a project from the on-disk config by name, preserving the rest of the
    # raw structure (other projects' unexpanded paths and per-project keys). The
    # inverse of add_project, and the single config-write path behind the
    # sidebar's `d`-on-a-project and the CLI `remove`, so the two never drift.
    # Reads the file fresh (never a cached @data), so it's correct even when a
    # long-lived sidebar's config is stale. Returns the removed raw entry, or nil
    # when no project by that name is registered (or there's no config yet).
    def self.remove_project(name)
      file = path
      return nil unless File.exist?(file)

      data = YAML.safe_load_file(file) || {}
      projects = data["projects"]
      return nil unless projects.is_a?(Array)

      # Match by index, not Array#delete(entry): delete removes every element
      # equal to the found hash, so two hand-edited entries with identical
      # content would both vanish on one removal. Drop exactly the first match.
      idx = projects.find_index { |p| p.is_a?(Hash) && p["name"] == name }
      return nil unless idx

      removed = projects.delete_at(idx)
      File.write(file, YAML.dump(data))
      removed
    end

    def initialize(file = self.class.path)
      @file = file
      @data = load_data(file)
    end

    # Why this exists rather than the old inline read raising: a malformed
    # config.yml would otherwise crash every consumer (the sidebar, `doctor`, and
    # now the `tmux-bind` keybinding path). Degrade to an empty config and remember
    # the parse error so `doctor` can report it; a valid file is unaffected.
    attr_reader :load_error

    def load_data(file)
      return {} unless File.exist?(file)

      YAML.safe_load_file(file) || {}
    rescue StandardError => e
      @load_error = e.message
      {}
    end

    # Where `switchboard` puts worktrees it creates: <root>/<project>/<name>.
    def worktree_root
      File.expand_path(@data["worktree_root"] || DEFAULT_ROOT)
    end

    # Where the clone action drops the repos it fetches: <root>/<name>. Kept
    # separate from worktree_root — these are the canonical source checkouts,
    # not the throwaway worktrees.
    def projects_root
      File.expand_path(@data["projects_root"] || DEFAULT_PROJECTS_ROOT)
    end

    # Whether to wire per-worktree agent-state hooks (sidebar dots) when creating
    # a worktree. On by default; scoped to the worktree, never global. Set
    # `agent_state_hooks: false` in config.yml to opt out.
    def agent_state_hooks?
      @data.fetch("agent_state_hooks", true) != false
    end

    # Whether the home sidebar reconciles (prunes orphaned sb/ sessions) on
    # launch, so a deleted/moved/crashed worktree's session doesn't silently
    # survive a relaunch. On by default; set `prune_on_launch: false` to opt out.
    def prune_on_launch?
      @data.fetch("prune_on_launch", true) != false
    end

    # Optional prefix for new branches, e.g. "wvmitchell" -> wvmitchell/<name>.
    def branch_prefix
      prefix = @data["branch_prefix"]
      prefix.to_s.empty? ? nil : prefix
    end

    # Default ref new worktrees branch from. Global, overridable per project.
    def base
      b = @data["base"]
      b.to_s.empty? ? "origin/main" : b
    end

    # Command switchboard types into a worktree's window the first time it
    # creates that worktree's tmux session — e.g.
    # "claude --dangerously-skip-permissions". Global default here; each project
    # can override with its own `session_command`. Empty/unset means run nothing
    # (you land in a plain shell, as before). This is the global; per-project
    # resolution happens in `projects` / `session_command_for`.
    def session_command
      cmd = @data["session_command"]
      cmd.to_s.empty? ? nil : cmd
    end

    # Resolved tmux key for a role ("toggle"/"home"): the configured value when it's
    # a usable key token, else the role default (toggle ⇒ "s", home ⇒ nil/unbound).
    # A `home` that resolves equal to the toggle is dropped — one key can't carry two
    # actions, and the toggle wins (doctor surfaces the collision). nil ⇒ leave the
    # role unbound. What `tmux-bind` binds.
    def tmux_key(role)
      raw = raw_tmux_key(role)
      key = valid_tmux_key?(raw) ? raw.strip : TMUX_KEY_DEFAULTS[role]
      return nil if role == "home" && key == tmux_key("toggle")

      key
    end

    # The raw configured value for a role (unvalidated), or nil. doctor uses this to
    # show "you set X, fell back to Y" when a value doesn't validate.
    def raw_tmux_key(role)
      keys = @data["tmux_keys"]
      keys.is_a?(Hash) ? keys[role] : nil
    end

    # A usable tmux key token: a non-empty String with no whitespace, quotes, or
    # control chars. Non-String YAML scalars (an int/bool/array/hash) are rejected.
    # Deliberately permissive otherwise — the rebind uses an argv array (no shell, so
    # no injection to guard), and tmux itself is the authority on whether a token is a
    # real key. An over-strict allowlist would wrongly reject valid keys (NPage, IC,
    # KP*, Unicode); a token tmux ultimately rejects is caught at bind time instead.
    def valid_tmux_key?(value)
      return false unless value.is_a?(String)

      s = value.strip
      !s.empty? && !s.match?(/['"\s\x00-\x1f]/)
    end

    def projects
      Array(@data["projects"]).filter_map do |p|
        next unless p["name"] && p["path"]

        {
          "name" => p["name"],
          "path" => File.expand_path(p["path"]),
          "base_ref" => p["base"] || base,
          # Per-project override, falling back to the global default.
          "session_command" => p["session_command"].to_s.empty? ? session_command : p["session_command"]
        }
      end
    end

    def project(name)
      projects.find { |p| p["name"] == name }
    end

    # Resolved session command for a project (its override, else the global
    # default, else nil) — what Tmux.go runs once on session creation.
    def session_command_for(name)
      p = project(name)
      p ? p["session_command"] : session_command
    end

    # Resolved sound spec for a project reaching `state` (:done/:waiting), or nil
    # when sounds are off for it. Resolution mirrors session_command: a per-project
    # `sounds` override, else the global `sounds` map, else the built-in default.
    # The returned string is a name or path; the Sound module turns it into a file.
    # Per-state keys are override-or-inherit only (absent/empty -> inherit, never
    # mute) — muting is exclusively `enabled: false` (or `sounds: false`), so a
    # falsy YAML value can't silently behave differently from an empty one.
    def sound_for(project_name, state)
      return nil unless sounds_enabled?(project_name)

      key = state.to_s
      present(project_sounds(project_name)[key]) || present(global_sounds[key]) || DEFAULT_SOUNDS[key]
    end

    # Sounds on by default; a per-project setting wins over the global one, and
    # either can mute via `enabled: false` or a bare `sounds: false`.
    def sounds_enabled?(project_name = nil)
      node = project_sounds_node(project_name)
      unless node.nil?
        return false if node == false
        return node["enabled"] != false if node.is_a?(Hash) && node.key?("enabled")
      end

      glob = @data["sounds"]
      return false if glob == false

      glob.is_a?(Hash) && glob.key?("enabled") ? glob["enabled"] != false : true
    end

    private

    # nil unless `v` is a non-empty string — so an absent/blank per-state value
    # falls through to the next source rather than muting.
    def present(v)
      s = v.to_s.strip
      s.empty? ? nil : s
    end

    def global_sounds
      @data["sounds"].is_a?(Hash) ? @data["sounds"] : {}
    end

    def project_sounds(name)
      node = project_sounds_node(name)
      node.is_a?(Hash) ? node : {}
    end

    # The raw `sounds` node for a project: a Hash, `false`, or nil when the
    # project has no `sounds` key at all (the three cases sounds_enabled? splits).
    def project_sounds_node(name)
      return nil unless name

      p = Array(@data["projects"]).find { |e| e.is_a?(Hash) && e["name"] == name }
      p&.key?("sounds") ? p["sounds"] : nil
    end
  end
end
