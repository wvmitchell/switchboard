# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"
require_relative "../support/keyed_marker_store"
require_relative "../support/paths"

module Switchboard
  # What each workspace is CALLED, keyed by its folder's realpath. A rename changes only
  # this (and the branch, the tmux session, Claude's title); the folder never moves, so
  # every agent keeps finding its history by the cwd it keys on. No entry = the folder
  # name, which is every workspace that has never been renamed.
  #
  # Stored names are user data, not a view preference, so this is stricter than
  # KeyedMarkerStore: a read is all-or-nothing (`[:ok, map]` or `[:error, path, errno]`,
  # never a partial map), reading never deletes, and writes report their failure. One
  # file per realpath (SHA-256 key), written temp+rename, so writers in different
  # projects, delete and prune's GC never lose each other's updates.
  module Names
    module_function

    Entry = Struct.new(:real, :name, :named_at, :project, :branch, :missing_since, keyword_init: true)

    FIELDS = %i[real name named_at project branch missing_since].freeze
    MISSING_TTL = 30 * 24 * 3600 # prune drops an entry whose folder has been gone this long

    def dir = KeyedMarkerStore.dir("SWITCHBOARD_NAMES_DIR", "names")

    def key(real) = Digest::SHA256.hexdigest(real.to_s)

    # The name rule rename enforces, re-checked on read so a hand-edited entry can never
    # reach tmux or a printed command: what sanitize leaves unchanged, no "/".
    def valid_name?(name)
      name.is_a?(String) && !name.empty? && name == Placeholder.sanitize(name) && !name.include?("/")
    end

    # [:ok, {real => Entry}] or [:error, path, errno]. Entries that don't parse, don't
    # match their key or carry an invalid name are skipped (doctor lists them via
    # `invalid`), never deleted here.
    def read_all
      d = dir
      return [:ok, {}] unless File.directory?(d)

      map = {}
      Dir.children(d).each do |f|
        next if f.start_with?(".")

        entry = parse(File.read(File.join(d, f), encoding: Encoding::UTF_8))
        map[entry.real] = entry if entry && key(entry.real) == f
      end
      [:ok, map]
    rescue SystemCallError, IOError => e
      [:error, d, e.message]
    end

    # Entry files that exist but can't be used (bad shape, wrong key, invalid name): doctor.
    def invalid
      d = dir
      return [] unless File.directory?(d)

      Dir.children(d).reject { |f| f.start_with?(".") }.reject do |f|
        entry = parse(File.read(File.join(d, f), encoding: Encoding::UTF_8))
        entry && key(entry.real) == f
      rescue SystemCallError, IOError
        false
      end.map { |f| File.join(d, f) }
    rescue SystemCallError
      []
    end

    def parse(raw)
      return nil unless raw.valid_encoding?

      parts = raw.chomp.split("\t", -1)
      return nil unless parts.size == FIELDS.size

      entry = Entry.new(**FIELDS.zip(parts).to_h)
      entry.real.start_with?("/") && valid_name?(entry.name) ? entry : nil
    end

    # :ok or [:error, errno].
    def write(real, name, project:, branch: "", missing_since: "", named_at: Time.now.to_i)
      return [:error, "invalid name"] unless valid_name?(name)

      fields = [real, name, named_at, project, branch, missing_since].map(&:to_s)
      return [:error, "a field holds a tab or newline"] if fields.any? { |f| f.match?(/[\t\n\r]/) }

      d = dir
      FileUtils.mkdir_p(d)
      file = File.join(d, key(real))
      tmp = File.join(d, ".#{key(real)}.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(tmp, "#{fields.join("\t")}\n")
      File.rename(tmp, file)
      forget_cache
      :ok
    rescue SystemCallError, IOError => e
      FileUtils.rm_f(tmp) if tmp
      [:error, e.message]
    end

    # :ok (a missing entry included) or [:error, errno].
    def delete(real)
      File.delete(File.join(dir, key(real)))
      forget_cache
      :ok
    rescue Errno::ENOENT
      :ok
    rescue SystemCallError => e
      [:error, e.message]
    end

    # The stored name for this realpath, honoring the duplicate rule, or nil (the folder
    # name applies). Lazy and cached, so `Worktree.new(project:, path:)` built anywhere
    # agrees with Model. An unreadable store keeps the last good map in this process
    # (a long-lived sidebar); a fresh process with none reads as "no name", which is
    # display-only: everything that writes or decides reads `read_all` itself.
    def name_for(real)
      entry = cached[real] or return nil
      clash?(entry, cached) ? nil : entry.name
    end

    # A stored name yields to the folder name when another folder in the same parent, or
    # another live entry in the same parent, sanitizes to the same session name. Both
    # sides of an entry clash fall back (no ordering), and folder names are unique in a
    # directory, so the fallback can't collide again. Unreachable through a locked
    # rename; it keeps a hand-edited or restored store from splitting sessions.
    def clash?(entry, map)
      parent = File.dirname(entry.real)
      want = session_leaf(entry.name)
      return true if siblings(parent).any? { |f| f != File.basename(entry.real) && session_leaf(f) == want }

      map.each_value.any? do |other|
        other.real != entry.real && File.dirname(other.real) == parent &&
          File.directory?(other.real) && session_leaf(other.name) == want
      end
    end

    def session_leaf(name) = name.to_s.gsub(Tmux::SANITIZE, "-")

    # Real directories in a parent (legacy rename bridges are symlinks and don't count).
    def siblings(parent)
      Dir.children(parent).select { |f| File.directory?(File.join(parent, f)) && !File.symlink?(File.join(parent, f)) }
    rescue SystemCallError
      []
    end

    # The store read once per (mtime, entry count) of its directory: every add, rewrite
    # (a rename into place) and delete changes it, and this process's own writes drop it.
    def cached
      stamp = stamp_of(dir)
      return @cache if @cache && @cache_stamp == stamp

      status, map = read_all
      if status == :ok
        @cache = map
        @cache_stamp = stamp
      end
      @cache || {}
    end

    def stamp_of(d)
      st = File.stat(d)
      [d, st.mtime.to_r, st.nlink, Dir.children(d).size]
    rescue SystemCallError
      [d, nil]
    end

    def forget_cache
      @cache = nil
      @cache_stamp = nil
    end
  end
end
