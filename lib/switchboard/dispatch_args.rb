# frozen_string_literal: true

require "io/wait"

module Switchboard
  # Argument rules for `switchboard new <target> [task|-]`, kept apart from CLI so the
  # DispatchNudge text can be checked against the real parser. Every rule refuses rather
  # than guesses: an agent wrote this brief and nobody is watching the pane it lands in.
  module DispatchArgs
    module_function

    MAX_TASK_BYTES = 65_536 # the task rides env AND argv, so it counts twice against ARG_MAX (1 MiB)
    STDIN_WAIT = 5          # an agent's Bash stdin can be a pipe that never closes
    STDIN_CHUNK = 16_384
    USAGE = 'usage: switchboard new <project|.> ["task" | -]'
    TOO_BIG = "task is over 64 KiB; the limit is 64 KiB: put the detail in a file and point the brief at it"

    # argv after `new` -> [target, task_arg, error]. task_arg is nil (bare create), "-"
    # (read stdin) or the task itself.
    def parse(argv)
      target, *rest = argv
      return [nil, nil, USAGE] if target.nil? || target.start_with?("-")
      return [nil, nil, %(too many arguments: quote the task, e.g. switchboard new . "research gov-1234")] if rest.size > 1

      [target, rest.first, nil]
    end

    # The brief from stdin -> [text, error]. Every wait is bounded, so neither a pipe
    # nobody writes to nor one that stalls mid-brief can hang the caller.
    def read_stdin(io = $stdin, wait: STDIN_WAIT, limit: MAX_TASK_BYTES)
      return [nil, "pipe the brief in, e.g. cat brief.md | switchboard new . -"] if io.tty?

      buf = "".b
      loop do
        unless io.wait_readable(wait)
          return [nil, buf.empty? ? "no brief arrived on stdin" : "the brief stopped arriving"]
        end

        chunk = io.read_nonblock(STDIN_CHUNK, exception: false)
        break if chunk.nil? # EOF
        next if chunk == :wait_readable

        buf << chunk
        return [nil, TOO_BIG] if buf.bytesize > limit
      end
      text = buf.force_encoding(Encoding::UTF_8)
      return [nil, "the brief on stdin isn't valid UTF-8"] unless text.valid_encoding? # never drop bytes silently
      return [nil, "the brief on stdin is empty"] if text.strip.empty?

      [text, nil]
    end

    # A task that would reach the agent wrong, or crash the launcher -> error, else nil.
    def task_error(task, limit: MAX_TASK_BYTES)
      return "the brief isn't valid UTF-8" unless task.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      return "the brief contains a NUL byte" if task.include?("\0") # ENV refuses it at launch
      return "a task can't start with '-': the agent would read it as an option; start with a word" if task.lstrip.start_with?("-")
      return "task is #{(task.bytesize / 1024.0).ceil} KiB; the limit is 64 KiB: put the detail in a file and point the brief at it" if task.bytesize > limit

      nil
    end
  end
end
