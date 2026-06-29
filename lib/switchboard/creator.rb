# frozen_string_literal: true

module Switchboard
  # Creates a new worktree (and its branch) for a project under the configured
  # worktree root. This is the capability that lets switchboard create work,
  # not just navigate what other tools made.
  module Creator
    module_function

    PLACEHOLDER_TRIES = 5 # bounded retries past a generated name already taken

    # Returns the new worktree path, or nil on failure (message to stderr).
    def create(config, project_name, workspace_name)
      project = config.project(project_name)
      return warn("unknown project: #{project_name}") unless project

      base = project["base_ref"] # e.g. origin/main (global `base`, per-project override)
      Git.fetch_base(project["path"], base) # make the base ref current first
      # Sanitize the project segment too: an explicit project name can carry
      # traversal (`switchboard add ../x …`), and File.join would otherwise let it
      # escape the worktree root just like an unsanitized workspace name would.
      root = File.join(config.worktree_root, sanitize(project_name))

      # No name given -> a faker placeholder you rename once you know the work (#94).
      # Retry past a name already taken by a dir OR a branch (a placeholder branch can
      # outlive its dir), so a random name never just fails. Don't clear a bridge for a
      # random name — it could be a live rename bridge; just try a different name.
      if blank?(workspace_name)
        PLACEHOLDER_TRIES.times do
          name = Placeholder.generate
          dest = File.join(root, name)
          next if File.exist?(dest)
          return enable_hooks(config, project_name, dest) if add_worktree(config, project, name, dest, base)
        end
        return warn("couldn't find a free placeholder name")
      end

      name = sanitize(workspace_name)
      return warn("invalid workspace name") if name.empty?

      dest = File.join(root, name)
      Git.clear_bridge(dest) # reclaim a stale rename bridge squatting the name
      return warn("already exists: #{dest}") if File.exist?(dest)

      add_worktree(config, project, name, dest, base) ? enable_hooks(config, project_name, dest) : nil
    end

    # git worktree add for `name`'s branch off `base`. `--no-track` so a branch cut
    # from a remote-tracking base (origin/main) does NOT inherit it as an upstream —
    # so a configured upstream means a real `git push -u`, which is the signal
    # rename's `pushed?` gate uses to leave a branch alone (#94). Returns whether it
    # succeeded.
    def add_worktree(config, project, name, dest, base)
      branch = [config.branch_prefix, name].compact.join("/")
      system("git", "-C", project["path"], "worktree", "add", "--no-track", "-b", branch, dest, base,
             out: File::NULL, err: File::NULL)
    end

    # Wire the per-worktree agent hooks (agent-state reporter + the #92 self-naming
    # nudge), scoped to this worktree, never global. Enabled when EITHER dots or
    # auto_rename is on — auto_rename resolved *per project* (auto_rename_for), so a
    # project that opts in with the global off still gets the hook the runtime nudge
    # needs. Best-effort: a hook-wiring hiccup must never sink an otherwise-good worktree.
    def enable_hooks(config, project_name, dest)
      AgentHooks.enable(dest) if config.agent_state_hooks? || config.auto_rename_for(project_name)
      dest
    rescue StandardError
      dest
    end

    def blank?(str)
      str.to_s.strip.empty?
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
