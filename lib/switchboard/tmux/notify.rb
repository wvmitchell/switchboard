# frozen_string_literal: true

module Switchboard
  # Status-line notices.
  module Tmux
    module_function

    # Surface a short message on tmux's status line — visible no matter which
    # pane has focus (a sidebar-only flash is missed when you're not on the tree).
    # Held at least NOTIFY_MS (tmux's own display-time defaults to 750 ms: gone before it
    # can be read); a keypress still clears it. Any failure retries without -d: tmux < 3.2
    # has no -d and refuses the whole command (a second try on a dead server costs a fork).
    # Never -N: it doesn't just hold the message through keypresses, it DISCARDS every key the
    # client types until the delay ends (verified, tmux 3.8).
    def notify(message, client: nil, display_time: self.display_time)
      target = client ? ["-c", client] : []
      system("tmux", "-u", *notify_args(message, display_time, target: target), out: File::NULL, err: File::NULL) ||
        system("tmux", "-u", "display-message", *target, literal(message), out: File::NULL, err: File::NULL)
    end

    # notify on every attached client. A daemonized worker's own "current client" is whatever
    # its TMUX_PANE named at spawn — maybe a session nobody is in now — so a notice about a pane
    # goes to every screen instead. No client listed: the plain notify.
    # The caller names the hold: -A here would resolve the worker's own session, not each client's.
    def notify_everyone(message, display_time:)
      names = IO.popen(["tmux", "-u", "list-clients", "-F", "\#{client_name}"], err: File::NULL, &:read).to_s.split("\n")
      names = [] unless $?.success?
      return notify(message, display_time: display_time) if names.empty?

      names.each { |name| notify(message, client: name, display_time: display_time) }
    rescue StandardError
      notify(message, display_time: display_time)
    end

    def notify_args(message, display_time, target: [])
      ["display-message", *target, "-d", notify_hold(display_time).to_s, literal(message)]
    end

    # The display-time in effect here: a session can set its own (-A resolves it from inside a
    # pane); outside one there's only the global.
    def display_time
      v = `tmux -u show-options -Aqv display-time 2>/dev/null`.strip
      v.empty? ? `tmux -u show-options -gqv display-time 2>/dev/null`.strip : v
    end

    # Pure: the user's display-time → our hold. Never shorter than theirs, and their 0
    # (until a key) stays 0; unreadable is NOTIFY_MS.
    def notify_hold(display_time)
      ms = display_time.to_s.strip
      return NOTIFY_MS unless ms.match?(/\A\d+\z/)

      ms.to_i.zero? ? 0 : [ms.to_i, NOTIFY_MS].max
    end

    # display-message's text is a format: `#{…}` expands and `#(…)` runs a shell command, then
    # strftime reads `%`; error text (a config parse error, an exception) can carry any of them.
    # `##` and `%%` are the literals.
    def literal(message)
      message.to_s.gsub("#", "##").gsub("%", "%%")
    end
  end
end
