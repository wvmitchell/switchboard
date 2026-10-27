# frozen_string_literal: true

require "fileutils"
require_relative "keyed_marker_store"

module Switchboard
  # After a workspace rename, give its live agent session the same name — the one the
  # resume picker and the phone's session list show (Claude names a session after the
  # workspace's FIRST name and never follows a rename). No agent exposes a rename API,
  # so a detached worker (`switchboard sync-session-name`, spawned by Rename.perform)
  # types the agent's own command into its pane, `/rename <name>` for Claude.
  #
  # Typing into someone's terminal is only safe under a narrow rule (spike notes:
  # Claude Code 2.1.310), so every step fails closed — when anything is unclear the
  # worker waits, never guesses:
  #   • between turns only (status idle/shell). Mid-turn a permission modal can open
  #     in the instant before our Enter, and Enter approves it; from idle, a modal
  #     needs a model round trip first.
  #   • Claude owns its terminal (foreground process group — not suspended, nothing in
  #     front of it), the pane isn't in a tmux mode (copy mode would eat the keys), and
  #     its window is provably off screen (an unparseable reply = maybe watched).
  #   • the prompt box is provably empty (bare `❯`, or only the dim placeholder),
  #     parsed between its divider lines — a modal's cursor draws `❯` too — and our
  #     line fits on one row of it.
  #   • Enter only if the box then reads exactly `❯ /rename <name>` and every gate
  #     still holds; otherwise back out only what we typed, or leave it (failed_send).
  # At most ONE Enter per session per worker: an attempt is retried only after a clean
  # back-out. A session whose text we couldn't remove (failed_send) or whose Enter Claude
  # never confirmed (unconfirmed) is spent, and doctor says so; only a retry you run
  # (a same-name rename, a new worker) tries it again. Latest wins: a newer rename
  # moves `dest` (leaving a bridge symlink), and a newer worker for the same workspace
  # takes its claim; either way the older worker exits.
  module SessionName
    FAST = 2        # seconds between polls at first…
    FAST_FOR = 30   # …for this long, then doubling…
    SLOW_CAP = 30   # …up to this
    CEILING = 3600  # give up (and tell doctor) after an hour
    DELIVERABLE = %w[idle shell].freeze
    # Backspaces may go to a box that's mid-turn (that's usually why we back out), never to a
    # permission modal or a status we don't know.
    BACKSPACEABLE = %w[idle busy shell].freeze
    SPENT = %i[failed_send unconfirmed].freeze # attempts that end a session's turn
    # What an hour of waiting means, from what the last pass saw: an unreadable box, or
    # a `/rename` of ours (any worker's) still sitting in it.
    CEILING_VERDICT = { unrecognized: :unrecognized, leftover: :failed_send }.freeze
    WHEN = "once it's idle and off screen" # the notices' promise, shared so they can't drift
    NAME = /\A\w[\w.-]*\z/ # what Rename hands us (Creator.sanitize); anything else never reaches a pane

    module_function

    # The worker loop. Returns why it stopped (for tests): :done (every live session
    # carries the name), :gone (no session twice running), :superseded, :invalid,
    # :error, or at the ceiling the verdict it left: :failed_send / :unconfirmed (a
    # session is spent) or :ceiling. A spent session is never typed into again, but the
    # worker keeps watching until the ceiling, so a late confirmation still ends as done.
    # Doctor's marker is this worker's verdict, decided by what it saw — the newest
    # worker's verdict wins.
    def work(dest, name, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(s) { pause(s) })
      return :invalid unless name.to_s.match?(NAME)
      # Renamed again before we booted: `dest` is a bridge, and claiming through it would
      # take the newest worker's claim.
      return :superseded if superseded?(dest, name)

      # Keyed once, by the canonical path checked to still carry our name: claim and
      # verdict can then never follow a bridge a later rename leaves at `dest`.
      real = Outcome.realpath(dest)
      return :superseded unless File.basename(real) == name

      token = Owner.claim(real)
      run(dest, name, token, real, clock, sleeper)
    rescue StandardError
      Outcome.record_real(real, :error, name) if real && token && Owner.mine?(real, token) # never silent
      :error
    end

    def run(dest, name, token, real, clock, sleeper)
      start = clock.call
      delay = FAST
      spent = {}
      empty_scans = 0
      loop do
        return :superseded if superseded?(dest, name) || !Owner.mine?(real, token)

        state = Claude.sync(dest, name, spent)
        # Renamed again, or a newer worker took over, mid-pass (a pass can take seconds
        # per session): the verdict isn't ours to write any more.
        return :superseded if superseded?(dest, name) || !Owner.mine?(real, token)

        elapsed = clock.call - start
        case state
        when :done
          Outcome.forget(real)
          return :done
        when :none # one empty scan can be a torn read; two in a row (or one at the end) is nobody here
          if (empty_scans += 1) >= 2 || elapsed >= CEILING
            Outcome.forget(real) # nothing left to rename means nothing failed
            return :gone
          end
        else
          empty_scans = 0
        end
        # One verdict per pass from this worker's own evidence: a spent session tells
        # doctor now, even while another is still pending, and leftover text comes first.
        verdict = SPENT.find { |kind| spent.value?(kind) }
        Outcome.record_real(real, verdict, name) if verdict

        if elapsed >= CEILING
          Outcome.record_real(real, verdict || CEILING_VERDICT.fetch(state, :ceiling), name)
          return verdict || :ceiling
        end
        delay = [delay * 2, SLOW_CAP].min if elapsed >= FAST_FOR
        sleeper.call(delay)
      end
    end

    # A newer rename moved the workspace on (a bridge symlink or nothing at `dest`), so
    # this worker's name is stale.
    def superseded?(dest, name)
      File.symlink?(dest) || !File.directory?(dest) || File.basename(dest) != name
    end

    # Every wait — between polls and inside one delivery. The unit tests stub it.
    def pause(secs)
      sleep(secs)
    end

    # Claude Code's adapter. Codex is a TODO (TODOS.md): its app-server has a
    # thread/name/set RPC, a better route than typing.
    module Claude
      COMMAND = "/rename"
      SETTLE = 0.15       # between re-captures after typing
      SETTLE_TRIES = 8    # ~1.2 s for the box to show what we typed (the spike saw ~130 ms)
      CONFIRM_POLL = 0.25
      CONFIRM_TRIES = 40  # ~10 s for the session file to show the new name
      BOX_CHROME = 5      # `❯`, its NBSP pad, the cursor cell, and a 2-column margin against a wrap

      module_function

      # One pass over every live session in the workspace. `spent` (owned by the worker)
      # maps [pid, procStart] => the attempt that spent it. :none when there's no session;
      # :done when every session is named or not ours to type into; a SPENT state once
      # nothing is left to try; else :unrecognized, :leftover (a /rename already sits in a
      # box) or :waiting.
      def sync(dest, name, spent = {})
        sessions = ClaudeSessions.sessions_in(dest) or return :waiting # couldn't tell: wait, don't quit
        return :none if sessions.empty?

        spent.select! { |key, _| sessions.any? { |s| key == [s[:pid], s[:proc_start]] } } # exited ones say nothing now
        panes = Tmux.panes_by_tty
        states = sessions.map do |s|
          key = [s[:pid], s[:proc_start]]
          spent.delete(key) if spent[key] == :unconfirmed && s[:name] == name # Claude caught up late
          next spent[key] if spent.key?(key)

          state = panes ? deliver(s, name, panes, dest) : :waiting
          spent[key] = state if SPENT.include?(state)
          state
        end
        %i[unrecognized leftover waiting].each { |st| return st if states.include?(st) }

        SPENT.find { |st| states.include?(st) } || :done
      end

      # One session: :done (named), :skip (not ours to type into), :waiting,
      # :unrecognized, :leftover, or a SPENT state.
      def deliver(session, name, panes, dest)
        return :done if session[:name] == name

        locked(session[:pid]) do
          next :waiting if SessionName.superseded?(dest, name)
          next :waiting unless ProcessIdentity.same?(session[:pid], session[:proc_start])

          fresh = current(session[:pid])
          next :done if fresh && fresh[:name] == name
          next :waiting unless fresh && DELIVERABLE.include?(fresh[:status])

          raw = tty_of(session[:pid]) or next :waiting
          tty = Tmux.normalize_tty(raw) or next :skip # no terminal at all
          pane = panes[tty] or next :skip # a terminal tmux doesn't own
          text = "#{COMMAND} #{name}"
          next :waiting unless typeable?(pane, text) && foreground?(session[:pid], tty)

          screen = Tmux.capture_pane(pane[:pane]) or next :waiting
          box = Box.parse(screen)
          next :unrecognized if box == :unrecognized
          next :leftover if box.is_a?(Array) && box[1].start_with?("#{COMMAND} ")
          next :waiting unless box == :empty
          # The pass's snapshot can be seconds old in a multi-session workspace, and the checks
          # above take a moment: a turn can start meanwhile and open a permission prompt that our
          # keys would answer (a digit picks an option). So re-read like the Enter gate — pane,
          # box, then the status (after the capture: tmux can hand back the last frame while the
          # file already says `waiting`), not renamed again since the lock, then LAST the same
          # Claude holding the terminal.
          next :waiting unless still_typeable?(pane[:pane], tty, text) && box_empty?(pane[:pane]) &&
                               deliverable?(session[:pid]) && !SessionName.superseded?(dest, name) &&
                               still_claude?(session[:pid], session[:proc_start], tty)

          type_rename(session[:pid], session[:proc_start], pane[:pane], tty, text, name, dest)
        end || :waiting # the lock is held: another worker is typing into this session
      rescue SystemCallError
        :waiting # the lock dir is unwritable; the ceiling reports it
      end

      # Off screen, not in a tmux mode, not synchronized (tmux would copy our keys into
      # every sibling pane), and our line fits on one row of the box.
      def typeable?(pane, text)
        pane[:visible] == false && pane[:in_mode] == false && pane[:synchronized] == false &&
          pane[:width].is_a?(Integer) && text.length + BOX_CHROME <= pane[:width]
      end

      # Type, check, Enter — or back out. The ensure guarantees a crash between typing
      # and Enter still cleans up.
      def type_rename(pid, start, pane, tty, text, name, dest)
        settled = false
        unless Tmux.send_literal(pane, text)
          settled = true # send-keys failed: nothing was typed, so nothing to back out
          return :waiting
        end
        # Every gate is re-read: the box and status after the slower checks (a turn could start
        # and open a permission prompt that Enter would approve), then — last — that the same
        # Claude still holds the terminal (a ^Z or crash would hand Enter to a shell, and a dead
        # Claude's frame and file both outlive it).
        if settled_box(pane, text) == [:text, text] && !SessionName.superseded?(dest, name) &&
           safe_to_key?(pid, pane, tty, text) && box_reads?(pane, text) && deliverable?(pid) &&
           still_claude?(pid, start, tty)
          settled = true
          # gstack-shortcut(dec-32768b9c): if Claude fires UserPromptSubmit for this local command,
          # the hooked dot reads "thinking" until PRESENCE_TTL; upgrade when a sandbox rename shows it.
          Tmux.send_keys(pane, "Enter")
          return confirmed?(pid, name) ? :done : :unconfirmed
        end
        settled = true # before, not after: a raise once the backspaces are out must not send a second round
        back_out(pid, start, pane, tty, text)
      ensure
        back_out(pid, start, pane, tty, text) unless settled
      end

      # The recipient is still Claude's own pane: off screen, no tmux mode, not
      # synchronized, the same %id on its tty, and Claude holding the foreground.
      def safe_to_key?(pid, pane, tty, text)
        still_typeable?(pane, tty, text) && foreground?(pid, tty)
      end

      def still_claude?(pid, start, tty)
        ProcessIdentity.same?(pid, start) && foreground?(pid, tty)
      end

      # Backspaces would reach this pane only: the same %id on its tty, off screen (someone
      # looking may be typing), no tmux mode, not synchronized. Unreadable is no. Width
      # doesn't matter: the line is already in.
      def recipient_ok?(pane, tty)
        row = Tmux.panes_by_tty&.[](tty)
        !row.nil? && row[:pane] == pane && row[:visible] == false && row[:in_mode] == false &&
          row[:synchronized] == false
      end

      def backspaceable?(pid)
        BACKSPACEABLE.include?(current(pid)&.[](:status))
      end

      def box_empty?(pane)
        (screen = Tmux.capture_pane(pane)) && Box.parse(screen) == :empty
      end

      def box_reads?(pane, text)
        (screen = Tmux.capture_pane(pane)) && Box.parse(screen) == [:text, text]
      end

      # The box once it shows our whole line, or something that can't be on its way to
      # it. Still empty, or a prefix, is a render in flight: keep looking (~1.2 s).
      def settled_box(pane, text)
        poll_box(pane) { |box| settled?(box, text) }
      end

      # A nil capture (a transient tmux failure) is no answer: keep looking.
      def settled?(box, text)
        return false if box.nil?

        box == [:text, text] || !(box == :empty || typed_prefix?(box, text))
      end

      # Remove only what we typed: only a box holding exactly our line gets backspaces, and
      # only a box seen empty again afterwards counts as clean — the session can be tried
      # again. Anything else is left alone and spends the session: a prefix still showing
      # after the full settle can't be told from someone's own `/re…` typed during a visit,
      # nor can the user's edits, keys that never reached the box, or backspaces that didn't
      # clear it.
      def back_out(pid, start, pane, tty, text)
        box = poll_box(pane) { |b| settled?(b, text) }
        return :failed_send unless box == [:text, text]
        # Backspaces are keys too, re-read like the Enter gate: the pane (copy mode or
        # synchronize-panes would send them elsewhere, and someone who just switched in may be
        # typing), the box (anything typed meanwhile changes it), the status (never a modal or
        # an unknown one), then LAST the same Claude holding the terminal (a ^Z leaves its
        # frame above a shell). Any miss leaves the text.
        return :failed_send unless recipient_ok?(pane, tty) && box_reads?(pane, text) &&
                                   backspaceable?(pid) && still_claude?(pid, start, tty)

        Tmux.send_keys(pane, *Array.new(text.length, "BSpace"))
        poll_box(pane) { |b| b == :empty } == :empty ? :waiting : :failed_send
      end

      # Re-capture every SETTLE until `done` holds for the parsed box (or the tries run
      # out); returns the last box seen.
      def poll_box(pane, &done)
        box = nil
        SETTLE_TRIES.times do
          SessionName.pause(SETTLE)
          box = (screen = Tmux.capture_pane(pane)) && Box.parse(screen)
          break if done.call(box)
        end
        box
      end

      def typed_prefix?(box, text)
        box.is_a?(Array) && box[0] == :text && !box[1].empty? && text.start_with?(box[1])
      end

      def deliverable?(pid)
        s = current(pid)
        !s.nil? && DELIVERABLE.include?(s[:status])
      end

      # Re-read before Enter: the user may have switched to the pane or scrolled it into
      # copy mode, and tmux recycles %ids, so the tty must still name the same pane.
      def still_typeable?(pane, tty, text)
        row = Tmux.panes_by_tty&.[](tty)
        !row.nil? && row[:pane] == pane && typeable?(row, text)
      end

      def confirmed?(pid, name)
        CONFIRM_TRIES.times do
          return true if current(pid)&.dig(:name) == name

          SessionName.pause(CONFIRM_POLL)
        end
        false
      end

      # The session's file re-read now (Claude names it by pid), or nil.
      def current(pid)
        ClaudeSessions.record(ClaudeSessions.read_json(File.join(ClaudeSessions.sessions_dir, "#{pid}.json")))
      end

      # The pid's tty as ps prints it ("??" for none), or nil when ps couldn't say.
      def tty_of(pid)
        out = IO.popen(["ps", "-o", "tty=", "-p", pid.to_s], err: File::NULL, &:read).to_s
        $?.success? ? out : nil
      rescue StandardError
        nil
      end

      # Is the pid on `tty`, in that terminal's foreground process group? A suspended Claude
      # (^Z) or a program run in front of it isn't, and its last box can still be on screen.
      def foreground?(pid, tty)
        out = IO.popen(["ps", "-o", "tty=,stat=,pgid=,tpgid=", "-p", pid.to_s], err: File::NULL, &:read).to_s
        now, stat, pgid, tpgid = out.split
        # Still on OUR pane's terminal too: a Claude moved to another one (reptyr) owns that
        # terminal's foreground while its old frame still sits in the pane we'd key into. And
        # running: a Claude stopped alone (an outside SIGSTOP, a tracer) keeps its group in
        # front, but our keys would queue for whatever reads the terminal next. An allowlist of
        # run states (macOS + Linux), so one we don't know fails closed.
        $?.success? && !tty.nil? && Tmux.normalize_tty(now) == tty && stat.to_s.match?(/\A[RSDIU]/) &&
          pgid.to_s.match?(/\A\d+\z/) && pgid == tpgid
      rescue StandardError
        false
      end

      # Run the block holding this session's typing lock, or return nil without
      # running it when another worker holds it. Never waits. Locks of dead pids are
      # swept first, so the dir can't grow without bound.
      def locked(pid)
        dir = File.join(Outcome.dir, ".locks")
        FileUtils.mkdir_p(dir)
        sweep_locks(dir)
        File.open(File.join(dir, pid.to_s), File::RDWR | File::CREAT, 0o600) do |f|
          return nil unless f.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      def sweep_locks(dir)
        Dir.children(dir).each do |f|
          next if !f.match?(/\A\d+\z/) || ProcessIdentity.alive?(f.to_i)

          File.delete(File.join(dir, f))
        rescue StandardError
          nil
        end
      end
    end

    # Claude's prompt box, read from a `capture-pane -e` screen: the region between the
    # LAST two divider lines (the upper one carries the session name once set). Returns
    # :empty (bare `❯`, or only the dim placeholder), [:text, s] for one line of typed
    # text, :draft for anything longer, or :unrecognized when there's no box.
    module Box
      DIVIDER = /\A─{8,}(?: .+ ─+)?\z/
      PROMPT = "❯"
      NBSP = "\u00A0"
      VIM = /-- (?:INSERT|NORMAL|VISUAL)/ # vim editor mode: typed keys would run as commands

      module_function

      def parse(screen)
        lines = cells(screen)
        plain = lines.map { |l| l.map(&:first).join.rstrip }
        dividers = plain.each_index.select { |i| plain[i].match?(DIVIDER) }
        return :unrecognized if dividers.size < 2

        top, bottom = dividers.last(2)
        region = lines[(top + 1)...bottom]
        return :unrecognized if region.empty? || plain[top + 1][0] != PROMPT
        return :unrecognized if plain.drop(bottom + 1).any? { |l| l.match?(VIM) }
        # gstack-shortcut(dec-2679bd5a): a Claude dialog with a text input drawn like the main
        # prompt (unverified) would pass here; upgrade when a capture of one exists — then also
        # require the main prompt's footer below the bottom divider.
        return :draft if region.size > 1

        content = region.first.drop(1)
        content = content.drop(1) if [" ", NBSP].include?(content.first&.first) # Claude pads `❯` with an NBSP
        content.pop while content.last && content.last.first.match?(/[[:space:]]/)
        return :empty if content.empty? || content.all? { |_, dim| dim }
        return :draft if content.any? { |_, dim| dim }

        [:text, content.map(&:first).join]
      end

      # Each line as [[char, dim?], …], tracking SGR state ACROSS lines: tmux carries
      # attributes over a line break (the placeholder's dim is reset at the START of
      # the next line).
      def cells(screen)
        dim = false
        lines = [[]]
        # CSI, then OSC (an OSC 8 hyperlink runs to BEL or ST), then any 2-byte escape.
        screen.to_s.scan(/\e\[[0-9;:?]*[A-Za-z]|\e\][^\a\e]*(?:\a|\e\\)?|\e.|\n|./m) do |tok|
          if tok == "\n" then lines << []
          elsif tok.start_with?("\e[") && tok.end_with?("m") then dim = sgr_dim(tok[2..-2], dim)
          elsif !tok.start_with?("\e") then lines.last << [tok, dim]
          end
        end
        lines
      end

      # The dim flag after one SGR sequence's params. 38/48/58 carry a color
      # (5;n or 2;r;g;b) whose numbers aren't attributes.
      def sgr_dim(params, dim)
        list = params.split(";", -1)
        list = [""] if list.empty?
        i = 0
        while i < list.size
          case list[i]
          when "", "0", "22" then dim = false
          when "2" then dim = true
          when "38", "48", "58" then i += list[i + 1] == "5" ? 2 : 4
          end
          i += 1
        end
        dim
      end
    end

    # What a worker couldn't do, for `doctor` — one marker per workspace (realpath
    # keyed, KeyedMarkerStore like Attention): the newest worker's verdict, cleared by a
    # success. Each is decided by evidence the worker saw, so no ranking between workers:
    #   failed_send   our /rename text is in the box (it couldn't back out, or an hour
    #                 passed with a /rename — any worker's — still sitting there)
    #   unconfirmed   pressed Enter, but the session file never showed the name
    #   unrecognized  never found a prompt box it could read (Claude's UI changed?)
    #   ceiling       an hour passed without a safe moment
    #   error         the worker crashed (never a silent exit)
    module Outcome
      FAILED_SEND = "failed_send" # the kind whose retry needs the prompt cleared first
      MESSAGES = {
        FAILED_SEND => "couldn't finish typing /rename (text may be left in the prompt)",
        "unconfirmed" => "pressed Enter on /rename but Claude never showed the new name " \
                         "(did Claude change /rename?)",
        "unrecognized" => "couldn't read Claude's prompt box (its screen layout may have changed)",
        "ceiling" => "never found a safe moment within #{CEILING / 60} minutes " \
                     "(Claude idle, off screen, its prompt empty)",
        "error" => "the sync worker stopped on an unexpected error"
      }.freeze

      module_function

      def record(dest, kind, name)
        record_real(realpath(dest), kind, name)
      end

      # By an already-canonical path — the worker keys by the realpath it started with.
      def record_real(real, kind, name)
        KeyedMarkerStore.write(dir, KeyedMarkerStore.key(real), [real, kind, name].join("\t"))
      end

      def clear(dest)
        forget(realpath(dest))
      end

      # Clear by an already-canonical path, without resolving it again — Rename passes
      # the pre-move realpath, which the bridge symlink now resolves to the NEW dir.
      def forget(real)
        KeyedMarkerStore.delete(dir, KeyedMarkerStore.key(real))
      end

      # [{ path:, kind:, name: }, …] for workspaces that still exist.
      def all
        KeyedMarkerStore.scan(dir) { |c| Dir.exist?(c.split("\t").first.to_s) }.map do |c|
          path, kind, name = c.split("\t", 3)
          { path: path, kind: kind.to_s, name: name.to_s }
        end.sort_by { |o| o[:path] }
      end

      def dir
        KeyedMarkerStore.dir("SWITCHBOARD_SESSION_NAME_DIR", "session-name")
      end

      def realpath(path)
        File.realpath(path)
      rescue StandardError
        path
      end
    end

    # One worker per workspace: each claims `dest` at start, and an older worker that no
    # longer holds the claim exits — so retrying a rename (doctor's advice) replaces the
    # running worker instead of stacking another hour-long one beside it. Claims are never
    # deleted by their owner (a check-then-delete would race a newer claim); a claim whose
    # pid is dead is swept by the next claim instead.
    module Owner
      module_function

      def claim(dest)
        sweep
        token = "#{Process.pid}-#{rand(2**32)}"
        KeyedMarkerStore.write(dir, KeyedMarkerStore.key(Outcome.realpath(dest)), token) && token
      end

      # Fails open on a missing or unreadable claim (another workspace's sweep can race a
      # fresh one away): superseded? still ends a stale worker, and the per-session lock
      # keeps two from typing at once. Only a DIFFERENT live claim retires us.
      def mine?(dest, token)
        return true unless token

        File.read(file(dest)) == token
      rescue StandardError
        true
      end

      def sweep
        Dir.glob(File.join(dir, "*")).each do |f|
          pid = File.read(f)[/\A\d+/]
          File.delete(f) if pid && !ProcessIdentity.alive?(pid.to_i)
        rescue StandardError
          nil
        end
      end

      def file(dest)
        File.join(dir, KeyedMarkerStore.key(Outcome.realpath(dest)))
      end

      def dir
        File.join(Outcome.dir, ".workers")
      end
    end
  end
end
