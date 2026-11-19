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
