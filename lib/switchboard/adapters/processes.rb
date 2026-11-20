# frozen_string_literal: true

require "set"

module Switchboard
  # The machine's process table, read in one `ps` call, for questions about how processes
  # are related: which matched agent pids are the agents themselves, and which are only
  # their helpers (an MCP server, a tool shell). Delete is the reader, so a read that fails
  # or can't finish an answer is nil, never a guess.
  module Processes
    module_function

    # { pid => { ppid:, uid:, tty:, comm: } } for every process, or nil when `ps` failed.
    # `comm` is the rest of the line: macOS prints the executable's full path, which can
    # hold spaces (`Claude Helper (Renderer)`). A process without a terminal has tty `??`
    # on macOS and `?` on Linux.
    def table
      out = IO.popen({ "LC_ALL" => "C" }, ["ps", "-A", "-o", "pid=,ppid=,uid=,tty=,comm="], err: File::NULL, &:read)
      $?.success? ? parse(out) : nil
    rescue StandardError
      nil
    end

    # { pid => argv words } for `pids` still running, from one `ps`; nil when ps failed. A
    # pid that exited has no line, which ps reports as a failure: that's only one when it
    # printed nothing for pids that were alive. Words split on spaces, enough to name an
    # executable or the script node runs.
    def commands(pids)
      return {} if pids.empty?

      out = IO.popen({ "LC_ALL" => "C" }, ["ps", "-o", "pid=,command=", "-p", pids.join(",")], err: File::NULL, &:read)
      found = out.each_line.each_with_object({}) do |line, h|
        pid, *argv = line.split
        h[pid.to_i] = argv if pid&.match?(/\A\d+\z/)
      end
      return nil if found.empty? && pids.any? { |p| ProcessIdentity.alive?(p) }

      found
    rescue StandardError
      nil
    end

    def parse(out)
      rows = out.each_line.each_with_object({}) do |line, h|
        pid, ppid, uid, tty, comm = line.strip.split(/\s+/, 5)
        next unless comm && [pid, ppid, uid].all? { |n| n.match?(/\A\d+\z/) }

        h[pid.to_i] = { ppid: ppid.to_i, uid: uid.to_i, tty: tty, comm: comm }
      end
      rows.empty? ? nil : rows
    end

    # The pids in `pids` with no ancestor in `pids`: the agents themselves, not the helpers
    # they started, however many unmatched processes (an `sh` wrapper) sit between. nil when
    # an ancestry can't be finished (a pid missing from the table, or a loop), since a
    # helper mistaken for an agent would make an idle agent read busy, and the reverse
    # would let a working one be deleted.
    def roots(pids, table)
      set = pids.to_set
      found = pids.map { |pid| [pid, matched_ancestor?(pid, set, table)] }
      return nil if found.any? { |_, a| a.nil? }

      found.reject { |_, a| a }.map(&:first)
    end

    # Is `pid` one of `roots`, or below one in the table?
    def subtree?(pid, roots, table)
      set = roots.to_set
      cur = pid
      64.times do
        return true if set.include?(cur)
        return false if cur <= 1 || !table.key?(cur)

        cur = table[cur][:ppid]
      end
      false
    end

    # Every process whose working folder is `real` or under it, except this process and a
    # tmux server: [{ pid:, start:, comm:, tty:, uid: }], or nil when the scan can't be trusted
    # to be complete. Only the kernel cwd counts; a process that merely has a file open in
    # the tree isn't found (walking every open file is far too slow).
    def in_tree(real, table: self.table, cwds: table && self.cwds(table))
      return nil unless table && cwds

      # The kernel reports resolved paths, so no realpath (which can hang on a dead mount).
      hits = cwds.select { |_, cwd| cwd == real || cwd.start_with?("#{real}/") }.keys
      hits -= [Process.pid] # an ancestor still counts: a shell in the folder that ran this is someone's
      # A tmux server keeps the folder it was started in, but holds no file there and
      # carries every session on it: never a process of the workspace's.
      hits.reject! { |pid| tmux?(table[pid]) }
      table = self.table || {} unless hits.all? { |pid| table.key?(pid) } # started after the table was read
      hits.filter_map do |pid|
        row = table[pid]
        return nil if row.nil? && ProcessIdentity.alive?(pid)

        start = row && ProcessIdentity.start_of(pid)
        if start.nil? || start.empty?
          next unless ProcessIdentity.alive?(pid) # exited since the scan

          return nil # running, but who it is can't be read
        end

        { pid: pid, start: start, comm: File.basename(row[:comm]), tty: row[:tty], uid: row[:uid] }
      end
    end

    def tmux?(row) = row && (File.basename(row[:comm].to_s) == "tmux" || row[:comm].to_s.start_with?("tmux: "))

    # A process with no controlling terminal (`??` on macOS, `?` on Linux).
    def detached?(row) = %w[?? ?].include?(row[:tty])

    # { pid => cwd } for every process this user can read, or nil when that can't be
    # trusted complete: this process must be there at its own cwd, and every process of
    # ours the table lists and that's still running (a zombie has no cwd). lsof exits 0
    # while quietly leaving out processes it couldn't read, so its status proves nothing.
    def cwds(table)
      found = File.directory?("/proc/self") ? proc_cwds : lsof_cwds
      return nil unless found && Paths.real_or_self(found[Process.pid].to_s) == Paths.real_or_self(Dir.pwd)

      missing = table.select { |pid, row| row[:uid] == Process.uid && !found.key?(pid) }.keys
      missing.all? { |pid| !ProcessIdentity.alive?(pid) || zombie?(pid) || hidden?(pid) } ? found : nil
    rescue StandardError
      nil
    end

    def proc_cwds
      Dir.children("/proc").each_with_object({}) do |entry, h|
        next unless entry.match?(/\A\d+\z/)

        h[entry.to_i] = File.readlink("/proc/#{entry}/cwd")
      rescue SystemCallError
        next # another user's, or it exited
      end
    end

    def lsof_cwds(only = [])
      out = IO.popen(["lsof", "-nPbw", "-a", "-d", "cwd", *only, "-Fpn"], err: File::NULL, &:read)
      found = {}
      pid = nil
      out.each_line(chomp: true) do |line|
        if line.start_with?("p") then pid = line[1..].to_i
        elsif line.start_with?("n") && pid then found[pid] = Agents.lsof_path(line[1..])
        end
      end
      found.empty? ? nil : found
    end

    # Linux refuses another of your own processes' cwd only when it made itself
    # non-dumpable (ssh-agent, gpg-agent): unreadable by design, not a scan that failed.
    def hidden?(pid)
      return false unless File.directory?("/proc/self")

      File.readlink("/proc/#{pid}/cwd")
      false
    rescue Errno::EACCES, Errno::EPERM
      true
    rescue StandardError
      false
    end

    def zombie?(pid)
      IO.popen(["ps", "-o", "stat=", "-p", pid.to_s], err: File::NULL, &:read).strip.start_with?("Z")
    rescue StandardError
      false
    end

    # Does a pid in `set` sit above `pid`? nil when the walk can't reach pid 1.
    def matched_ancestor?(pid, set, table)
      return nil unless table.key?(pid)

      cur = table[pid][:ppid]
      64.times do
        return false if cur <= 1
        return nil if cur == pid # a loop back to itself
        return true if set.include?(cur)
        return nil unless table.key?(cur)

        cur = table[cur][:ppid]
      end
      nil
    end
  end
end
