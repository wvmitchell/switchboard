# frozen_string_literal: true

require "yaml"
require "fileutils"

module Switchboard
  # Switchboard's own project registry — what lets it stand alone, with no
  # emdash (or Conductor) database at runtime. Lives at
  # ~/.config/switchboard/config.yml and is seeded once by `switchboard init`.
  class Config
    DEFAULT_PATH = File.expand_path("~/.config/switchboard/config.yml")
    DEFAULT_ROOT = "~/switchboard/worktrees"
    DEFAULT_PROJECTS_ROOT = "~/Programming" # where the clone action drops repos

    def self.path
      ENV["SWITCHBOARD_CONFIG"] || DEFAULT_PATH
    end

    def self.exist?
      File.exist?(path)
    end

    # Append a project to the on-disk config, preserving the existing raw
    # structure (unexpanded paths and per-project keys). The single config-write
    # path shared by the CLI `add`/`clone` and the sidebar's add action, so the
    # two never drift. Returns the written entry.
    def self.add_project(name, repo, base = nil)
      file = path
      data = File.exist?(file) ? (YAML.safe_load_file(file) || {}) : { "worktree_root" => DEFAULT_ROOT }
      entry = { "name" => name, "path" => repo }
      entry["base"] = base if base
      (data["projects"] ||= []) << entry
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, YAML.dump(data))
      entry
    end

    def initialize(file = self.class.path)
      @file = file
      @data = File.exist?(file) ? (YAML.safe_load_file(file) || {}) : {}
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
  end
end
