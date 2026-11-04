# frozen_string_literal: true

module Switchboard
  # An environment value as UTF-8. Under a C/POSIX locale Ruby hands ENV back as BINARY,
  # which can't be combined with the UTF-8 strings (hook commands, messages) built from it.
  def self.env(name) = ENV[name]&.dup&.force_encoding(Encoding::UTF_8)

  # Where switchboard's on-disk stores live, and the two ways of canonicalizing a path.
  # Everything resolves from ENV per call, never frozen at load, so the test sandbox can
  # redirect it. HookFile::SCRIPT keeps its own shell copy of the state rule (it runs
  # without Ruby), and test/paths_test.rb holds the two together.
  module Paths
    module_function

    APP = "switchboard"
    ROOTS = {
      state: ["XDG_STATE_HOME", "~/.local/state"],
      data: ["XDG_DATA_HOME", "~/.local/share"],
      cache: ["XDG_CACHE_HOME", "~/.cache"]
    }.freeze

    def state(override, leaf)
      utf8(File.expand_path(set_value(override) || under(:state, leaf)))
    end

    def data(leaf)
      utf8(File.expand_path(under(:data, leaf)))
    end

    # Unlike state and data, an XDG root is taken as given rather than expanded.
    def cache(override, leaf)
      path = set_value(override)
      return utf8(File.expand_path(path)) if path

      xdg, default = ROOTS.fetch(:cache)
      root = set_value(xdg)
      return utf8(File.join(root, APP, leaf)) if root

      utf8(File.expand_path(File.join(default, APP, leaf)))
    end

    # For a path that must match nothing once it stops resolving.
    def real_or_nil(path)
      File.realpath(path)
    rescue StandardError
      nil
    end

    # For a best-effort canonical key: a vanished path just keeps its raw spelling.
    def real_or_self(path)
      File.realpath(path)
    rescue StandardError
      path
    end

    def under(root, leaf)
      xdg, default = ROOTS.fetch(root)
      File.join(set_value(xdg) || default, APP, leaf)
    end

    # An exported-but-empty variable counts as unset, as it does for the sh reporter. Taken
    # literally, "" expands to the current directory, and a store's cleanup would delete
    # the files there.
    def set_value(name)
      value = Switchboard.env(name)
      value unless value.to_s.empty?
    end

    # `~` expands from $HOME, BINARY under a C locale, so the encoding is set last.
    def utf8(path) = path.dup.force_encoding(Encoding::UTF_8)
  end
end
