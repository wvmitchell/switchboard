# frozen_string_literal: true

# A stand-in for Claude Code in session-name smoke tests — never the real thing. It draws
# Claude's prompt box the way 2.1.310 does (divider lines, `❯` + NBSP, a dim placeholder
# when empty), keeps a session file like Claude's (`<sessions dir>/<pid>.json`: pid,
# procStart, cwd, status, name), honors `/rename <name>` + Enter, and logs every byte it
# receives so a test can prove nothing was typed.
#
#   ruby fake_claude.rb <sessions dir> <control dir>
#
# The control dir holds `status` (the test writes idle/busy/… to flip it) and `keys` (the log).
require "io/console"
require "json"

sessions, control = ARGV
file = File.join(sessions, "#{Process.pid}.json")
proc_start = IO.popen({ "LC_ALL" => "C", "TZ" => "UTC" }, ["ps", "-p", Process.pid.to_s, "-o", "lstart="], &:read).strip
box = +""
name = "old-xy"
status = nil

save = lambda do
  data = { "pid" => Process.pid, "sessionId" => "fake", "cwd" => Dir.pwd, "procStart" => proc_start,
           "kind" => "interactive", "name" => name, "status" => status }
  tmp = "#{file}.tmp"
  File.write(tmp, JSON.generate(data))
  File.rename(tmp, file)
end

shown = nil
draw = lambda do
  frame = [box.dup, name, status]
  next if frame == shown # a static screen while the worker captures it, like Claude's

  shown = frame
  rule = "\e[38;2;136;136;136m#{'─' * 60}\e[39m"
  line = box.empty? ? "❯ \e[2mTry \"refactor <filepath>\"\e[0m" : "❯ #{box}"
  $stdout.write("\e[H\e[2J  fake claude · #{name}\r\n\r\n#{rule}\r\n#{line}\r\n#{rule}\r\n  ⏵⏵ #{status}")
  $stdout.flush
end

at_exit { File.delete(file) if File.exist?(file) }
%w[TERM HUP INT].each { |sig| trap(sig) { exit } }

$stdin.raw do
  loop do
    want = File.exist?(File.join(control, "status")) ? File.read(File.join(control, "status")).strip : "idle"
    if want != status
      status = want
      save.call
    end
    draw.call
    next unless IO.select([$stdin], nil, nil, 0.1)

    bytes = $stdin.readpartial(4096)
    File.open(File.join(control, "keys"), "ab") { |f| f.write(bytes) }
    bytes.each_char do |c|
      case c
      when "\r"
        if box.start_with?("/rename ")
          name = box.delete_prefix("/rename ")
          save.call
        end
        box = +""
      when "\x7f", "\b" then box.chop!
      else box << c if c.ord >= 32
      end
    end
  end
end
