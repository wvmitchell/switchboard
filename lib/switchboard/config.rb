# frozen_string_literal: true

require "yaml"

module Switchboard
  # Switchboard's own project registry — what lets it stand alone, with no
  # emdash (or Conductor) database at runtime. Lives at
  # ~/.config/switchboard/config.yml and is seeded once by `switchboard init`.
  class Config
    DEFAULT_PATH = File.expand_path("~/.config/switchboard/config.yml")
    DEFAULT_ROOT = "~/switchboard/worktrees"

    def self.path
      ENV["SWITCHBOARD_CONFIG"] || DEFAULT_PATH
    end

    def self.exist?
      File.exist?(path)
    end

    def initialize(file = self.class.path)
      @file = file
      @data = File.exist?(file) ? (YAML.safe_load_file(file) || {}) : {}
    end

    # Where `switchboard` puts worktrees it creates: <root>/<project>/<name>.
    def worktree_root
      File.expand_path(@data["worktree_root"] || DEFAULT_ROOT)
    end

    # Optional prefix for new branches, e.g. "wvmitchell" -> wvmitchell/<name>.
    def branch_prefix
      prefix = @data["branch_prefix"]
      prefix.to_s.empty? ? nil : prefix
    end

    def projects
      Array(@data["projects"]).filter_map do |p|
        next unless p["name"] && p["path"]

        {
          "name" => p["name"],
          "path" => File.expand_path(p["path"]),
          "base_ref" => p["base"] || "origin/main"
        }
      end
    end

    def project(name)
      projects.find { |p| p["name"] == name }
    end
  end
end
