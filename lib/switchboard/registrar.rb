# frozen_string_literal: true

require "fileutils"

module Switchboard
  # Registers projects into the config — the capability that lets switchboard
  # stand up from an empty sidebar with no CLI round-trip (and finally decouple
  # from emdash's project seeding). Two ways in: point at a repo already on disk,
  # or clone one from a URL first. Both land in the same Config.add_project write
  # path, so the CLI and the sidebar action never drift.
  module Registrar
    module_function

    # Register an existing local git repo. Derives the project name from the
    # repo's directory leaf unless one is given. Returns [entry, nil] on success
    # or [nil, error_message].
    def register(config, path, name: nil, base: nil)
      repo = Git.toplevel(File.expand_path(path.to_s))
      return [nil, "not a git repo: #{path}"] unless repo

      name ||= File.basename(repo)
      return [nil, "name taken: #{name}"] if config.project(name)

      # Pick the base ref new worktrees branch from. Prefer an explicit base
      # (from the CLI); else the remote's default branch; else, for a repo with
      # no origin, the local HEAD branch. Drop it when it's blank (e.g. an unborn
      # repo) or just echoes the global default — then the project inherits the
      # global base instead of carrying redundant (or empty) per-project noise.
      if base.nil?
        base = Git.remote_head(repo)
        base = Git.current_branch(repo) if base.to_s.empty? # no origin → local HEAD
        base = nil if base.to_s.empty? || base == config.base
      end
      [Config.add_project(name, repo, base), nil]
    end

    # Unregister a project by name — the inverse of register, and the keyboard
    # path to removing a project without hand-editing config.yml. Pure registry
    # surgery: the repo and its worktrees on disk are untouched (callers own any
    # session teardown). Returns [entry, nil] on success or [nil, error_message]
    # when no project by that name is registered.
    def unregister(config, name)
      return [nil, "no such project: #{name}"] unless config.project(name)

      [Config.remove_project(name), nil]
    end

    # Clone a URL under the projects root, then register the result. Returns
    # [entry, nil] on success or [nil, error_message].
    def clone(config, url, name: nil, base: nil)
      name ||= name_from_url(url)
      return [nil, "can't derive a name from: #{url}"] if name.to_s.empty?
      return [nil, "name taken: #{name}"] if config.project(name)

      root = config.projects_root
      dest = File.join(root, name)
      return [nil, "already exists: #{dest}"] if File.exist?(dest)

      FileUtils.mkdir_p(root)
      return [nil, "clone failed: #{url}"] unless Git.clone(url, dest)

      register(config, dest, name: name, base: base)
    end

    # Project name from a git URL: the last path segment, minus a trailing
    # slash and the .git suffix (git@host:org/repo.git -> repo).
    def name_from_url(url)
      url.to_s.strip.sub(%r{/+\z}, "").split(%r{[/:]}).last.to_s.sub(/\.git\z/, "")
    end
  end
end
