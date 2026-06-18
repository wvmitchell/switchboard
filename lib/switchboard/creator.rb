# frozen_string_literal: true

module Switchboard
  # Creates a new worktree (and its branch) for a project under the configured
  # worktree root. This is the capability that lets switchboard create work,
  # not just navigate what other tools made.
  module Creator
    module_function

    # Returns the new worktree path, or nil on failure (message to stderr).
    def create(config, project_name, workspace_name)
      project = config.project(project_name)
      return warn("unknown project: #{project_name}") unless project

      name = sanitize(workspace_name)
      return warn("invalid workspace name") if name.empty?

      dest = File.join(config.worktree_root, project_name, name)
      return warn("already exists: #{dest}") if File.exist?(dest)

      branch = [config.branch_prefix, name].compact.join("/")
      base = project["base_ref"]

      Git.fetch(project["path"]) # make sure the base ref is current
      ok = system("git", "-C", project["path"], "worktree", "add", dest, "-b", branch, base,
                  out: $stderr, err: $stderr)
      ok ? dest : warn("git worktree add failed (base: #{base})")
    end

    # Filesystem- and branch-safe; spaces become dashes.
    def sanitize(name)
      name.to_s.strip.gsub(/\s+/, "-").gsub(%r{[^\w./-]}, "")
    end
  end
end
