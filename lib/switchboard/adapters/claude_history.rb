# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "../support/paths"

module Switchboard
  # Carry a Claude Code conversation history across a workspace rename so `/resume` and
  # `claude --continue` find it at the new path. Claude keeps each session's transcript in
  #   <config>/projects/<encoded-cwd>/<session-id>.jsonl
  # keyed by the workspace's absolute path, and a rename changes that path.
  #
  # A running session keeps writing under the OLD key, and readers such as gstack's
  # transcript guard refuse a folder that isn't a real directory. So both keys must stay
  # real: rename builds a real folder at the new key and HARD-LINKS every file into it. Claude appends in place, so a link sees every later append too. Files the old
  # session creates after the rename (a session started after `/clear`) are linked by
  # prune's catch-up. `claude --continue` picks its session before any hook runs, so a
  # SessionStart pass couldn't do this in time.
  # Nothing here ever creates a symlink in `projects/`. The "projects bridges" older
  # versions left behind are converted into real folders (a live writer) or deleted (none;
  # their target holds the data).
  #
  # The encoding is Claude's: every non-alphanumeric char becomes "-", so it's lossy and
  # only ever computed forward from a path.
  #
  # Best-effort throughout: a failure means less history carried, never a failed rename.
  # Unexpected errors land in a small log doctor reports.
  #
  # Known limits:
  #   1. Lossy-encoding collision: sibling worktrees differing only in "_"/"."/"-" share
  #      one Claude folder (Claude's limit); every pair operation skips equal keys.
  #   2. Hard links need one filesystem; `projects/` is one directory, so they always are.
  #   3. A session started in a workspace subdirectory has its own key; only the root key
  #      is carried.
  #   4. A reused workspace name can still hold the earlier workspace's real folder, so
  #      `/resume` there lists its sessions until that folder is cleaned up; doctor names it.
  #   5. A projects bridge converted with no worktree bridge to pair it is linked back to
  #      its old target once; what its session writes after that stays only in the
  #      converted folder.
  module ClaudeHistory
    QUIET = 600       # a folder this long unchanged has no writer finishing up
    TEMP_AGE = 3600   # a staging folder this old belongs to a crashed run
    LOG_LINES = 50
    LOG_BYTES = 512
    RENAME_SWAP = 2   # renamex_np: exchange two names atomically (macOS)
    TEMP = /\A\..+\.sb-\d+-\h+\z/

    # What one history operation did, for prune's line and doctor.
    Summary = Struct.new(:linked, :converted, :deleted, :kept, :clashes, :partial, keyword_init: true) do
      def self.zero = new(linked: 0, converted: 0, deleted: 0, kept: Hash.new(0), clashes: [], partial: false)
    end

    module_function

    # Rename: make the new key a real folder holding links to every transcript under the
    # old one. :linked, :partial (something skipped or failed), or :no_source.
    def link(old_path, new_path, now: Time.now)
      src = key_path(old_path)
      dst = key_path(new_path)
      return :no_source if src == dst

      # Bounded: the sidebar's `r` runs this, and a prune may hold the lock for a while.
      # Busy means prune's catch-up carries it later (the worktree bridge pairs the keys).
      with_lock(timeout: 2) { carry(src, dst, now) } || begin
        record_error("link", dst, RuntimeError.new("busy: the next prune carries it"))
        :partial
      end
    rescue StandardError => e
      record_error("link", dst, e)
      :partial
    end

    # Pairs are [old_path, new_path] from the worktree bridges. Links what the old key
    # gained since the rename; replaces and removes nothing.
    def catch_up(pairs, now: Time.now)
      sum = Summary.zero
      with_lock do
        pairs.each do |old_path, new_path|
          src = key_path(old_path)
          dst = key_path(new_path)
          next unless qualifies?(src, dst, since: bridged_at(old_path))

          mirror(src, dst, sum)
        rescue StandardError => e
          record_error("catch_up", src, e)
        end
      end
      sum
    end

    # Prune's pass over the projects bridges older versions left, limited to keys under
    # `owned` prefixes. Writer-held ones become real folders first, outermost first; then
    # writerless ones go, outside in, so a chain never loses a link a live session uses.
    def sweep(owned:, now: Time.now)
      sum = Summary.zero
      with_lock do
        writers = ClaudeSessions.writers_by_key
        links = outer_first(owned_links(owned))
        held, free = links.partition { |l| writers.nil? || !writers.fetch(File.basename(l), []).empty? }
        held.each { |l| tally(sum, realize(l, now: now, writers: writers, relink: true)) }
        free.each { |l| tally(sum, realize(l, now: now, writers: writers)) }
        clean_temps(now)
      end
      sum
    end

    # The projects bridges sweep would act on, plus dangling owned ones (for doctor).
    def sweep_candidates(owned:)
      owned_links(owned).select { |l| real_folder(l) || !File.exist?(l) }
    end

    # Creation: never let a new workspace inherit a stranger's projects bridge at its key.
    def free_key(path)
      with_lock { claim_key(key_path(path)) }
    rescue StandardError => e
      record_error("free_key", path, e)
      nil
    end

    # Read-only view of each pair for prune's dry run and doctor: files still to link and
    # same-named files that differ ([old, new] paths).
    def inspect_pairs(pairs)
      pairs.filter_map do |old_path, new_path|
        src = key_path(old_path)
        dst = key_path(new_path)
        next unless qualifies?(src, dst, since: bridged_at(old_path))

        sum = Summary.zero
        mirror(src, dst, sum, dry: true)
        { old: src, new: dst, missing: sum.linked, clashes: sum.clashes }
      rescue StandardError
        nil
      end
    end

    # A key whose folder already holds sessions older than the workspace itself: a name
    # reused while the earlier workspace's history is still there.
    def reused?(path)
      born = File.stat(path).birthtime
      dir = key_path(path)
      return false unless real_dir?(dir)

      Dir.glob("*.jsonl", base: dir).any? { |f| File.lstat(File.join(dir, f)).mtime < born - 60 }
    rescue StandardError, NotImplementedError # no birthtime on some Linux filesystems
      false
    end

    # Sweep projects bridges (symlinks in projects/) that dangle, under owned keys only.
    def reap_bridges(owned:)
      owned_links(owned).each do |path|
        File.delete(path) unless File.exist?(path)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    # --- the one projects-bridge rule ------------------------------------------------

    # A symlink directly in projects/ whose target is a real folder there. No writer, a
    # target unchanged for QUIET and a layout we recognize: delete it, the target keeps
    # the data. A writer or doubt: convert it into a real folder of hard links. `relink`
    # links the converted folder back into the old target once (sweep, no pair to do it).
    def realize(link, now:, writers: :lookup, convert_only: false, relink: false)
      return :absent unless File.symlink?(link)
      return :skipped unless child_of_root?(link)

      target = real_folder(link) or return :skipped
      return :pointed_to if pointed_to?(link)

      writers = ClaudeSessions.writers_by_key if writers == :lookup
      mine = writers&.fetch(File.basename(link), [])
      if mine == []
        return :kept_convert_only if convert_only
        return :kept_recent unless quiet?(target, now)
        return :kept_unrecognized unless recognized_layout?(target)

        File.delete(link)
        return :deleted
      end
      return :failed unless convert(link, target)

      mirror(link, target, Summary.zero) if relink
      :converted
    rescue StandardError => e
      record_error("realize", link, e)
      :failed
    end

    # A key that is about to belong to a new owner (a new workspace, a rename's destination):
    # no session of that owner has written there yet. With no known writer, a projects
    # bridge there just goes, whatever its target's age or layout (the target keeps the
    # data). A writer, a doubt, or a link out of projects/ is kept and logged: converting it
    # would hand the new owner someone else's history.
    def claim_key(link)
      return :absent unless File.symlink?(link)

      mine = ClaudeSessions.writers_by_key&.fetch(File.basename(link), [])
      ours = real_folder(link) || !File.exist?(link)
      if mine == [] && ours && !pointed_to?(link)
        File.delete(link)
        return :deleted
      end
      why = if mine.nil? then "writers unknown"
            elsif !mine.empty? then "a live session writes through it"
            elsif !ours then "it links outside Claude's projects folder"
            else "another projects bridge points at it"
            end
      record_error("claim_key", link, RuntimeError.new("kept a projects bridge at a new owner's key: #{why}"))
      :kept
    end

    def convert(link, target)
      temp = temp_path(link)
      Dir.mkdir(temp)
      staged = Summary.zero
      mirror(target, temp, staged, whole: true)
      if staged.partial
        FileUtils.remove_entry_secure(temp) # only our extra names; the target keeps every file
        return false
      end
      return finish_swap(temp, link, target) if exchange(temp, link)

      route = File.readlink(link)
      File.delete(link)
      begin
        place(temp, link)
      rescue Errno::EEXIST, Errno::ENOTEMPTY
        # Claude recreated the folder in the gap: add ours beside its files, never over them.
        mirror(temp, link, Summary.zero, whole: true)
        FileUtils.remove_entry_secure(temp)
      rescue SystemCallError
        begin
          place(temp, link)
        rescue SystemCallError => e
          record_error("convert", link, e) # staging stays: it holds every file
          File.symlink(route, link) unless File.exist?(link) || File.symlink?(link) # the live route back
          return false
        end
      end
      mirror(target, link, Summary.zero, whole: true) # anything written in the gap
      true
    end

    def finish_swap(temp, link, target)
      File.delete(temp) # the symlink, now under the temp name
      mirror(target, link, Summary.zero, whole: true)
      true
    end

    # The rename that puts a staged folder in place (its own method so a test can stand
    # between unlink and rename).
    def place(temp, link) = File.rename(temp, link)

    # macOS only: renamex_np(RENAME_SWAP) swaps the staged folder and the symlink in one
    # step, so a live session never sees the key missing. false where it isn't available.
    def exchange(a, b)
      return false unless RUBY_PLATFORM.include?("darwin")

      require "fiddle"
      fn = Fiddle::Function.new(Fiddle::Handle::DEFAULT["renamex_np"],
                                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      fn.call(a, b, RENAME_SWAP).zero?
    rescue StandardError, LoadError
      false
    end

    # --- walking ---------------------------------------------------------------------

    def carry(src, dst, now)
      from = File.symlink?(src) ? real_folder(src) : src
      realize(src, now: now, convert_only: true)
      claim_key(dst)
      return :no_source unless from && real_dir?(from)
      return :partial if File.symlink?(dst)
      return :no_source if File.exist?(dst) && File.identical?(from, dst)

      sum = Summary.zero
      mirror(from, dst, sum, log_skips: true)
      sum.partial || sum.clashes.any? ? :partial : :linked
    end

    # Link every file under `from` that `to` lacks; never overwrite, never follow a
    # symlink. `dry:` only counts. `log_skips:` logs a skipped top-level entry (rename).
    def mirror(from, to, sum, whole: false, top: true, dry: false, log_skips: false)
      begin
        Dir.mkdir(to) unless dry || File.directory?(to)
      rescue Errno::EEXIST
        nil # Claude made it first
      end
      entries = Dir.children(from).map { |n| [n, File.lstat(File.join(from, n))] }
      entries.each do |name, st|
        s = File.join(from, name)
        d = File.join(to, name)
        if top && !whole && !recognized?(name, st)
          sum.partial = true
          record_error("link", s, RuntimeError.new("not carried: not a regular file or folder")) if log_skips
        elsif st.directory?
          next sum.partial = true if File.symlink?(d)

          mirror(s, d, sum, whole: whole, top: false, dry: dry)
        elsif st.file?
          link_file(s, d, st, sum, dry)
        else
          sum.partial = true # a symlink, socket or fifo: never followed
        end
      rescue SystemCallError => e
        record_error("mirror", s, e)
        sum.partial = true
      end
    end

    def link_file(src, dst, st, sum, dry)
      there = begin
        File.lstat(dst)
      rescue Errno::ENOENT
        nil
      end
      if there
        sum.clashes << [src, dst] unless there.ino == st.ino && there.dev == st.dev
        return
      end
      File.link(src, dst) unless dry
      sum.linked += 1
    end

    # A pair worth catching up: two different real folders, and the new key is still empty,
    # shares an inode with the old (rename's link), or holds only files made after the
    # worktree bridge `since` (rename's link was skipped, then a session started there).
    def qualifies?(src, dst, since: nil)
      return false if src == dst || !real_dir?(src)
      return true unless File.exist?(dst) || File.symlink?(dst)
      return false unless real_dir?(dst) && !File.identical?(src, dst)

      theirs = inodes(dst)
      theirs.empty? || inodes(src).intersect?(theirs) || (since && born_since?(dst, since))
    end

    # Birth time, not mtime: Claude appends in place, so an older file's mtime moves on.
    # Where the filesystem has none, no file counts as new.
    def born_since?(dir, since)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).all? do |rel|
        st = File.lstat(File.join(dir, rel))
        !st.file? || st.birthtime >= since
      end
    rescue NotImplementedError
      false
    end

    def bridged_at(old_path)
      File.lstat(old_path).mtime
    rescue SystemCallError
      nil
    end

    def inodes(dir)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).filter_map do |rel|
        st = File.lstat(File.join(dir, rel))
        [st.dev, st.ino] if st.file?
      end.to_set
    end

    # Anything Claude itself keeps beside the transcripts (`<uuid>/`, `memory/`, a tool's
    # `monitor/`) is a plain file or folder; a symlink, socket or fifo is not ours to carry.
    def recognized?(_name, st) = st.file? || st.directory?

    def recognized_layout?(dir)
      Dir.children(dir).all? { |n| recognized?(n, File.lstat(File.join(dir, n))) }
    end

    def quiet?(dir, now)
      newest = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).map { |r| File.lstat(File.join(dir, r)).mtime }
      (newest << File.lstat(dir).mtime).max < now - QUIET
    end

    # --- projects/ geometry --------------------------------------------------------------

    def key_path(path) = File.join(projects_root, encode(canonical(path)))

    def real_root = Paths.real_or_nil(projects_root)

    def real_dir?(path) = File.directory?(path) && !File.symlink?(path)

    def child_of_root?(path)
      root = real_root
      root && Paths.real_or_self(File.dirname(path)) == root
    end

    # The real folder directly in projects/ a projects bridge resolves to, else nil.
    def real_folder(link)
      target = Paths.real_or_nil(link)
      target if target && real_dir?(target) && File.dirname(target) == real_root
    end

    def owned?(name, owned) = owned.any? { |prefix| name.start_with?(prefix) }

    def owned_links(owned)
      root = projects_root
      return [] unless File.directory?(root)

      Dir.children(root).filter_map do |n|
        p = File.join(root, n)
        p if owned?(n, owned) && File.symlink?(p)
      end
    end

    # Does another projects bridge point at this one (a chain from older renames)?
    def pointed_to?(link)
      root = projects_root
      me = File.basename(link)
      Dir.children(root).any? do |n|
        p = File.join(root, n)
        n != me && File.symlink?(p) && File.basename(File.readlink(p)) == me
      end
    rescue StandardError
      true
    end

    # Outermost links (nothing points at them) first, so a chain is walked from its head.
    def outer_first(links)
      depth = links.to_h { |l| [l, 0] }
      links.each do |l|
        hop = l
        6.times do
          nxt = File.join(File.dirname(hop), File.basename(File.readlink(hop)))
          break unless depth.key?(nxt)

          depth[nxt] += 1
          hop = nxt
        end
      rescue StandardError
        next
      end
      links.sort_by { |l| depth[l] }
    end

    def temp_path(link) = File.join(File.dirname(link), ".#{File.basename(link)}.sb-#{Process.pid}-#{SecureRandom.hex(4)}")

    def clean_temps(now)
      root = projects_root
      Dir.children(root).each do |n|
        p = File.join(root, n)
        next unless n.match?(TEMP) && File.lstat(p).mtime < now - TEMP_AGE

        File.symlink?(p) ? File.delete(p) : FileUtils.remove_entry_secure(p)
      rescue StandardError
        next
      end
    end

    def tally(sum, outcome)
      case outcome
      when :deleted then sum.deleted += 1
      when :converted then sum.converted += 1
      when :absent, :skipped then nil
      else sum.kept[outcome.to_s.delete_prefix("kept_")] += 1
      end
    end

    # --- lock and error log ----------------------------------------------------------------

    # One switchboard process at a time changes projects/. Kept in our state dir, not
    # Claude's. `timeout:` (seconds) gives up and returns nil instead of waiting on.
    def with_lock(timeout: nil)
      path = Paths.state("SWITCHBOARD_CLAUDE_HISTORY_LOCK", "claude-history.lock")
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |f|
        if timeout
          give_up = Time.now + timeout
          sleep 0.05 until f.flock(File::LOCK_EX | File::LOCK_NB) || Time.now > give_up
          return nil unless f.flock(File::LOCK_EX | File::LOCK_NB)
        else
          f.flock(File::LOCK_EX)
        end
        yield
      end
    end

    def log_path = Paths.state("SWITCHBOARD_CLAUDE_HISTORY_LOG", "claude-history.log")

    # One line per unexpected error, appended in a single write so two processes never
    # interleave. Never stdout: hooks run this.
    def record_error(op, path, err)
      where = err.backtrace&.first(3)&.map { |l| l.sub(%r{.*/lib/switchboard/}, "") }&.join(" < ")
      line = "#{Time.now.utc.strftime('%FT%TZ')} #{op} #{File.basename(path.to_s)} #{err.class}: #{err.message} @ #{where}"
      line = "#{line.gsub(/\s+/, ' ').scrub[0, LOG_BYTES - 1]}\n"
      FileUtils.mkdir_p(File.dirname(log_path))
      File.open(log_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |f| f.write(line) }
    rescue StandardError
      nil
    end

    # [count, oldest time string] of the logged errors, or nil when there are none.
    def errors
      lines = File.readlines(log_path, chomp: true).reject(&:empty?)
      [lines.size, lines.first.split(" ", 2).first] unless lines.empty?
    rescue StandardError
      nil
    end

    def trim_log
      lines = File.readlines(log_path)
      return if lines.size <= LOG_LINES

      tmp = "#{log_path}.#{Process.pid}.tmp"
      File.write(tmp, lines.last(LOG_LINES).join)
      File.rename(tmp, log_path)
    rescue StandardError
      nil
    end

    # --- paths ---------------------------------------------------------------------------

    # Claude's cwd -> project-dir encoding: every non-alphanumeric run to "-".
    def encode(path)
      path.to_s.gsub(/[^A-Za-z0-9]/, "-")
    end

    # Claude keys its project dir by the canonicalized cwd (`pwd -P`), so resolve
    # symlinked ancestors (/private/var, a symlinked HOME). But keep the LEAF literal: an
    # old path is a worktree bridge after a rename, and realpath'ing through it would land
    # on the new dir and miss the old key. Degrades to the raw path if the parent is gone.
    def canonical(path)
      File.join(File.realpath(File.dirname(path)), File.basename(path))
    rescue StandardError
      path
    end

    # Where Claude keeps its per-project transcript dirs. A test/override seam
    # first (keeps the suite off the real ~/.claude), then Claude's own dir.
    def projects_root
      override = ENV["SWITCHBOARD_CLAUDE_PROJECTS_DIR"]
      return override unless override.nil? || override.empty?

      File.join(claude_root, "projects")
    end

    # Claude's own config dir: CLAUDE_CONFIG_DIR (empty = unset), else ~/.claude.
    # The one answer every reader of Claude's files shares (transcripts here, the
    # live session files in RemoteLink), so they can never disagree.
    # `base` is a CLAUDE_CONFIG_DIR value to resolve (doctor compares tmux's with yours).
    def claude_root(base = ENV["CLAUDE_CONFIG_DIR"])
      base.nil? || base.empty? ? File.join(Dir.home, ".claude") : base
    end
  end
end
