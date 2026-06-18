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
      cwds = agent_cwds
      worktree_paths.select do |wt|
        cwds.any? { |cwd| cwd == wt || cwd.start_with?("#{wt}/") }
      end.to_set
    end

    def agent_cwds
      (tmux_cwds + process_cwds).uniq
    end

    # tmux panes whose foreground command is an agent CLI by name.
    def tmux_cwds
      out = `tmux list-panes -a -F '#\{pane_current_command}#{TAB}#\{pane_current_path}' 2>/dev/null`
      out.lines.filter_map do |line|
        cmd, path = line.chomp.split("\t", 2)
        path if path && CLIS.include?(cmd)
      end
    rescue StandardError
      []
    end

    # Processes whose args mention an agent CLI (catches node-wrapped `claude`),
    # mapped to their working directory in ONE lsof call (per-pid lsof is slow).
    def process_cwds
      pids = `pgrep -f '#{CLIS.join('|')}' 2>/dev/null`.split.first(40)
      return [] if pids.empty?

      out = `lsof -a -d cwd -p #{pids.join(',')} -Fn 2>/dev/null`
      out.lines.filter_map { |line| line[1..].chomp if line.start_with?("n") }
    rescue StandardError
      []
    end

    TAB = "\t"
  end
end
