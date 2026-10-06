# frozen_string_literal: true

module Switchboard
  # The install path we bake into long-lived wiring (the tmux.conf marker line,
  # tmux hooks/bindings, per-worktree Claude hooks, the global codex block).
  #
  # A clone's realpath is stable, so it passes through. A Homebrew install's is
  # NOT: realpath lands in the versioned keg (`<prefix>/Cellar/switchboard/0.50.0/…`),
  # which `brew upgrade` + `brew cleanup` deletes — stranding every baked path and,
  # worse, changing the codex hook commands' bytes, which voids codex's hash-keyed
  # `/hooks` trust on every release. So a keg path is rewritten to its `opt/`
  # twin (`<prefix>/opt/switchboard/…`), the symlink brew repoints at the current
  # keg on each upgrade. Fails safe: no opt link ⇒ the realpath, as before.
  module StablePath
    module_function

    KEG = %r{\A(?<prefix>.+)/Cellar/switchboard/[^/]+(?<rest>/.*)?\z}

    def resolve(path)
      homebrew_opt(path) || path
    end

    # The `opt/` twin of a path inside a switchboard keg, or nil (not a keg path,
    # or brew hasn't linked an opt dir for it).
    def homebrew_opt(path)
      m = KEG.match(path) or return nil
      opt = "#{m[:prefix]}/opt/switchboard"
      File.directory?(opt) ? "#{opt}#{m[:rest]}" : nil
    end

    def homebrew?(path)
      !homebrew_opt(path).nil?
    end
  end
end
