# frozen_string_literal: true

require "set"

module Switchboard
  # Detects worktrees that currently host a running agent chat (Claude Code,
  # Codex, Aider). Cheap-ish scan: tmux panes by command, plus a process scan
  # (the CLIs usually run as `node`, so the pane command alone misses them).
  module Agents
    CLIS = %w[claude codex aider].freeze

    module_function

    # Subset of `worktree_paths` that have a live agent (cwd in the worktree).
    def active(worktree_paths)
      # Bytes, like RemoteLink: a decoded lsof cwd carries raw non-ASCII bytes, and a
      # text compare against a differently-encoded path raises — blanking every dot.
      cwds = agent_cwds.map(&:b)
      worktree_paths.select do |wt|
        w = wt.b
        cwds.any? { |cwd| cwd == w || cwd.start_with?("#{w}/") }
      end.to_set
    end

    def agent_cwds
      (tmux_cwds + process_cwds).uniq
    end

    # tmux panes whose foreground command is an agent CLI by name.
    def tmux_cwds
      tmux_panes.map { |_id, path| path }
    end

    # [[pane_id, cwd], ...] for agent-CLI panes. Pane ids let the sidebar's
    # activity fallback capture a specific pane to tell busy from idle.
    def tmux_panes
      out = `tmux list-panes -a -F '#\{pane_id}#{TAB}#\{pane_current_command}#{TAB}#\{pane_current_path}' 2>/dev/null`
      out.lines.filter_map do |line|
        id, cmd, path = line.chomp.split("\t", 3)
        [id, path] if path && CLIS.include?(cmd)
      end
    rescue StandardError
      []
    end

    # Processes whose args mention an agent CLI (catches node-wrapped `claude`),
    # mapped to their working directory in ONE lsof call (per-pid lsof is slow).
    def process_cwds
      pids = `pgrep -f '#{CLIS.join('|')}' 2>/dev/null`.split.first(40)
      cwds_of(pids).values
    rescue StandardError
      []
    end

    # { pid => its kernel cwd } for `pids`, in ONE lsof call. The kernel cwd follows
    # a moved dir (a rename), unlike any path the process recorded at startup —
    # which is why RemoteLink attributes a live session by it. -Fn emits a `p<pid>`
    # line, then the cwd's `n<path>` line.
    def cwds_of(pids)
      pids = pids.map(&:to_i).select(&:positive?)
      return {} if pids.empty?

      pid = nil
      `lsof -a -d cwd -p #{pids.join(',')} -Fn 2>/dev/null`.lines.each_with_object({}) do |line, out|
        line = line.chomp
        if line.start_with?("p") then pid = line[1..].to_i
        elsif line.start_with?("n") && pid then out[pid] = lsof_path(line[1..])
        end
      end
    rescue StandardError
      {}
    end

    # Under a C locale (tmux's, often) lsof prints every non-ASCII byte as `\xNN`, so
    # `café` comes back as a path that doesn't exist and matches no worktree. Decode
    # it — but only when the printed path isn't real, so a dir literally named `\x41`
    # survives. Kept in the shell's encoding, like the git paths it's compared with.
    def lsof_path(path)
      return path if !path.include?("\\x") || File.exist?(path)

      decoded = path.b.gsub(/\\x(\h\h)/) { Regexp.last_match(1).hex.chr }
      decoded.force_encoding(Encoding.default_external)
    end

    TAB = "\t"
  end
end
