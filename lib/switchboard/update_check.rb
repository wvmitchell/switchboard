# frozen_string_literal: true

require "json"
require "fileutils"

module Switchboard
  # "Is a newer switchboard out?" for the sidebar's update line (#47), Homebrew stable
  # installs only (a clone follows its own branch, a --HEAD keg follows main). A
  # visible sidebar spawns `switchboard check-update` when the cache is stale; that
  # child reads the newest release tag (LatestRelease: bounded, config-stripped) and
  # writes it to a small JSON cache. Every sidebar reads the cache in rebuild and
  # compares it to the INSTALLED version.rb, not the VERSION it loaded: after an
  # upgrade, a running sidebar still has the old code, and comparing against that
  # would keep the line up after you did what it asked.
  module UpdateCheck
    module_function

    TTL = 4 * 3600   # re-check a good answer this often
    RETRY = 3600     # ...and wait this long after any attempt, so offline never loops
    DISABLE_ENV = "SWITCHBOARD_NO_UPDATE_CHECK" # the suite, smoke runs and the sandbox set it
    VERSION_LITERAL = /^\s*VERSION\s*=\s*"(\d+\.\d+\.\d+)"/
    SHAPE = /\A\d+\.\d+\.\d+\z/

    # SWITCHBOARD_UPDATE_CACHE (a file path) → $XDG_CACHE_HOME/switchboard → ~/.cache.
    # An exported-but-empty override counts as unset, like Pr.cache_dir.
    def cache_path
      override = ENV["SWITCHBOARD_UPDATE_CACHE"]
      return File.expand_path(override) if override && !override.empty?

      xdg = ENV["XDG_CACHE_HOME"]
      root = xdg && !xdg.empty? ? File.join(xdg, "switchboard") : File.expand_path("~/.cache/switchboard")
      File.join(root, "latest.json")
    end

    # Its mtime throttles retries; the child's flock on it keeps one lookup at a time.
    def attempt_path
      File.join(File.dirname(cache_path), "latest.attempt")
    end

    def disabled_by_env?
      value = ENV[DISABLE_ENV].to_s
      !value.empty? && value != "0"
    end

    def sandbox?
      !ENV["SWITCHBOARD_SANDBOX"].to_s.empty?
    end

    # Only the installed Homebrew binary speaks for the install: a dogfood checkout is
    # a clone and would compare against its own feature branch. One `command -v`.
    def applies?
      Upgrade.install_method == :brew && Installer.installed_bin?
    rescue StandardError
      false
    end

    # Is a check due? Stats only (every visible reload asks).
    def due?(now = Time.now)
      stale?(cache_path, TTL, now) && stale?(attempt_path, RETRY, now)
    end

    def stale?(file, ttl, now)
      now - File.mtime(file) > ttl
    rescue SystemCallError
      true
    end

    # The sidebar touches the attempt file right before it spawns, so every other
    # pane reads "not due" at once instead of each booting a child of its own.
    def claim
      FileUtils.mkdir_p(File.dirname(attempt_path))
      FileUtils.touch(attempt_path)
      true
    rescue SystemCallError
      false
    end

    # The child's work: one lookup at a time (a held lock means another child is on
    # it), and only a real answer is written, so offline keeps the last good one.
    def run_child
      return if disabled_by_env?

      FileUtils.mkdir_p(File.dirname(attempt_path))
      File.open(attempt_path, File::RDWR | File::CREAT, 0o644) do |lock|
        return unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        FileUtils.touch(attempt_path)
        result = check
        write(result) if result
      end
    rescue SystemCallError
      nil
    end

    # {"latest", "checked_at"}, or nil when the tags couldn't be read in time.
    def check
      return nil if disabled_by_env?

      latest = LatestRelease.latest or return nil
      { "latest" => latest, "checked_at" => Time.now.to_i }
    end

    def write(result)
      MarkerBlock.atomic_write(cache_path, "#{JSON.generate(result)}\n")
    end

    # The cached latest version, or nil for a missing, torn or odd file (fails closed:
    # anything unexpected means no line).
    def read(path = cache_path)
      data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      latest = data.is_a?(Hash) && data["latest"]
      latest.is_a?(String) && latest.match?(SHAPE) ? latest : nil
    rescue StandardError
      nil
    end

    # The installed checkout's version.rb: Installer.repo_root resolves a keg path to
    # its opt/ twin, so after `brew upgrade` this names the NEW keg's file.
    def version_file
      File.join(Installer.repo_root, "lib", "switchboard", "version.rb")
    end

    def installed_version(path = version_file)
      File.read(path, encoding: Encoding::UTF_8)[VERSION_LITERAL, 1]
    rescue StandardError
      nil
    end

    # Pure: the version to announce, or nil when the installed one is current.
    def cue(latest, installed)
      return nil unless latest && installed

      LatestRelease.compare(latest, installed).positive? ? latest : nil
    end
  end
end
