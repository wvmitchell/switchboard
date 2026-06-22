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

      # Sanitize the project segment too: an explicit project name can carry
      # traversal (`switchboard add ../x …`), and File.join would otherwise let it
      # escape the worktree root just like an unsanitized workspace name would.
      dest = File.join(config.worktree_root, sanitize(project_name), name)
      Git.clear_bridge(dest) # reclaim a stale rename bridge squatting the name
      return warn("already exists: #{dest}") if File.exist?(dest)

      branch = [config.branch_prefix, name].compact.join("/")
      base = project["base_ref"] # e.g. origin/main (global `base`, per-project override)

      Git.fetch_base(project["path"], base) # make the base ref current first
      ok = system("git", "-C", project["path"], "worktree", "add", dest, "-b", branch, base,
                  out: File::NULL, err: File::NULL)
      return nil unless ok

      # Scope agent-state hooks to this worktree (never global). Best-effort: a
      # hook-wiring hiccup must never sink an otherwise-good worktree.
      begin
        Hook.enable(dest) if config.agent_state_hooks?
      rescue StandardError
        nil
      end
      dest
    end

    # Filesystem- and branch-safe: spaces become dashes, the char class drops
    # anything exotic, and ".", ".." and empty path segments are stripped so a
    # name can never climb out of (or absolute-jump around) the worktree root via
    # File.join — "../../etc" sanitizes to "etc", "/tmp/x" to "tmp/x", "." to "".
    def sanitize(name)
      cleaned = name.to_s.strip.gsub(/\s+/, "-").gsub(%r{[^\w./-]}, "")
      cleaned.split("/").reject { |seg| seg.empty? || seg == "." || seg == ".." }.join("/")
    end
  end
end
