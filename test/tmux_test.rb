# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # Tmux is almost all shell-outs, so the unit-testable surface is the pure
  # parse (sb_sessions), the name builders (session_name/session_prefix sharing
  # one sanitization), and the orchestration whose ORDER matters (kill_all kills
  # the current session last). The raw `tmux ...` calls themselves are covered by
  # the manual verification in the plan, not here.
  class TmuxTest < SandboxTest
    # --- sb_sessions: the pure list parse ------------------------------------

    def test_sb_sessions_keeps_only_sb_prefixed_and_parses_created
      raw = "sb/app/feat\t1700000000\nother\t1700000001\nsb/home\t1700000002\n"
      got = Tmux.sb_sessions(raw)
      assert_equal [{ name: "sb/app/feat", created: 1_700_000_000 },
                    { name: "sb/home", created: 1_700_000_002 }], got
    end

    def test_sb_sessions_drops_blank_lines_and_handles_missing_created
      raw = "\nsb/app/x\t\n"
      assert_equal [{ name: "sb/app/x", created: 0 }], Tmux.sb_sessions(raw)
    end

    def test_sb_sessions_does_not_match_bare_sb_without_slash
      # "sbx/..." must not be mistaken for one of ours — the boundary is "sb/".
      assert_empty Tmux.sb_sessions("sbx/app/x\t1\n")
    end

    def test_sb_sessions_empty_input
      assert_empty Tmux.sb_sessions("")
    end

    # --- count_sidebar_panes: the pure pane-title tally (drives doctor's orphan
    # check). Counts only panes titled exactly SIDEBAR_TITLE across `list-panes -a`.

    def test_count_sidebar_panes_counts_only_exact_sidebar_titles
      raw = "#{Tmux::SIDEBAR_TITLE}\n✳ Claude Code\n#{Tmux::SIDEBAR_TITLE}\nmy-host\n"
      assert_equal 2, Tmux.count_sidebar_panes(raw)
    end

    def test_count_sidebar_panes_ignores_titles_that_merely_contain_the_marker
      # An exact match only — a work pane whose title embeds the marker can't inflate it.
      raw = "#{Tmux::SIDEBAR_TITLE}-stale\nnot-#{Tmux::SIDEBAR_TITLE}\n"
      assert_equal 0, Tmux.count_sidebar_panes(raw)
    end

    def test_count_sidebar_panes_empty_input
      assert_equal 0, Tmux.count_sidebar_panes("")
    end

    # --- parse_work_panes: the pure [id, path] extraction that finds an agent's
    # WORK pane (every NON-sidebar pane). AgentState capture-hashes it for liveness;
    # sidebar panes are dropped by exact title so the sidebar is never hashed.

    def test_parse_work_panes_drops_sidebars_keeps_agent_panes
      raw = "%1\t#{Tmux::SIDEBAR_TITLE}\t/wt/a\n" \
            "%2\t✳ Fix the thing\t/wt/a\n" \
            "%3\t2.1.201\t/wt/b\n" # agent pane names its version, not "claude"
      assert_equal [["%2", "/wt/a"], ["%3", "/wt/b"]], Tmux.parse_work_panes(raw)
    end

    def test_parse_work_panes_is_tab_delimited_and_exact_on_the_marker
      # A path with spaces survives (tab split); a title merely embedding the marker
      # is still a work pane (exact match only, like count_sidebar_panes).
      raw = "%1\tnot-#{Tmux::SIDEBAR_TITLE}\t/wt/with a space\n"
      assert_equal [["%1", "/wt/with a space"]], Tmux.parse_work_panes(raw)
    end

    def test_parse_work_panes_empty_input
      assert_empty Tmux.parse_work_panes("")
    end

    # --- parse_ttys / parse_sidebar_processes / normalize_tty: the pure inputs to
    # prune's orphaned-sidebar reap (a THIS-SERVER sidebar process whose tty is no live
    # pane — parse_sidebar_processes scopes to our server's children by parent pid).

    # --- parse_panes_by_tty: SessionName's pane lookup + the tri-state keyboard gates ---

    NOW = 1_000_000

    # A list-panes row: window_active, session_attached, pane_active, and its session.
    def pane_row(id, tty, active, attached, pane_active, session = "s", mode: "0", width: "120", synced: "0")
      "#{id}\t/dev/#{tty}\t#{active}\t#{attached}\t#{mode}\t#{width}\t#{synced}\t#{pane_active}\t#{session}\n"
    end

    def client_row(session, activity: NOW - 60, control: "0", flags: "attached,focused,UTF-8")
      "#{activity}\t#{control}\t#{flags}\t#{session}\n"
    end

    # One session, quiet since well before NOW: last_input then reads the clients' newest.
    def parse_rows(raw, clients = nil, now = NOW, sessions: "$0\t#{NOW - 120}\n")
      Tmux.parse_panes_by_tty(raw, clients, now, sessions: sessions)
    end

    # Value: protects=last_input counts session activity, which outlives a client that typed and then
    # detached (client_activity leaves with it); each row lists every session id so a killed one reads
    # missing; unreadable is unknown; fails_when=sessions are ignored or a garbled row reads as known;
    # why_new=ship 6 Codex adversarial (a detach erased the key from last_input); seam=none
    def test_parse_panes_by_tty_counts_session_activity_a_detach_cant_erase
      raw = pane_row("%1", "ttys001", "1", "1", "0")
      sessions = "$3\t#{NOW - 5}\n$1\t#{NOW - 90}\n"
      row = parse_rows(raw, "", NOW, sessions: sessions)["ttys001"] # nobody attached now
      assert_equal NOW - 5, row[:last_input], "the detached client's key is still on its session"
      assert_equal %w[$1 $3], row[:sessions]
      assert_nil parse_rows(raw, "", NOW, sessions: "$1\tsoon\n")["ttys001"][:last_input]
      assert_nil parse_rows(raw, "", NOW, sessions: "%1\t#{NOW}\n")["ttys001"][:sessions]
      assert_nil parse_rows(raw, "", NOW, sessions: nil)["ttys001"][:last_input], "unreadable list"
    end

    def test_parse_panes_by_tty_maps_each_tty_to_its_pane_and_gates
      raw = pane_row("%1", "ttys001", "1", "1", "1") + pane_row("%2", "ttys002", "0", "1", "1", mode: "1", width: "80", synced: "1") +
            pane_row("%3", "ttys003", "1", "0", "1", "t", width: "40")
      assert_equal({ "ttys001" => { pane: "%1", focused: true, recent_input: false, last_input: NOW - 60, sessions: ["$0"], in_mode: false, synchronized: false, width: 120 },
                     "ttys002" => { pane: "%2", focused: false, recent_input: false, last_input: NOW - 60, sessions: ["$0"], in_mode: true, synchronized: true, width: 80 },
                     "ttys003" => { pane: "%3", focused: false, recent_input: false, last_input: NOW - 60, sessions: ["$0"], in_mode: false, synchronized: false, width: 40 } },
                   parse_rows(raw, client_row("s"), NOW))
    end

    # Value: protects=an unreadable copy-mode flag or width never reads as "safe to type";
    # fails_when=a garbled field becomes false/0; why_new=new fields; seam=none
    def test_parse_panes_by_tty_reads_garbled_mode_and_width_as_unknown
      row = parse_rows("%1\t/dev/ttys001\t0\t1\tx\t\n")["ttys001"]
      assert_nil row[:in_mode]
      assert_nil row[:width]
      assert_nil row[:synchronized], "a missing synchronize-panes flag is unknown, not off"
    end

    # Value: protects=keys are never typed into a pane someone may be at; fails_when=a garbled
    # row reads as hidden (Tmux.visible?'s fail-open); why_new=new parser; seam=none
    def test_parse_panes_by_tty_reads_a_garbled_row_as_unknown_not_clear
      raw = "%1\t/dev/ttys001\t\t\n%2\t/dev/ttys002\tx\t1\n"
      rows = parse_rows(raw, client_row("s"), NOW).values_at("ttys001", "ttys002")
      assert_equal [nil, nil], rows.map { |h| h[:focused] }
      assert_empty parse_rows("junk\n\t/dev/ttys009\t1\t1\n"), "no %id, no row"
    end

    # Value: protects=keys only reach a pane no client is keying into; fails_when=a shown pane
    # reads unfocused without its own flag, or a garbled flag reads as unfocused; why_new=focus gate; seam=none
    def test_parse_panes_by_tty_focus_is_the_active_pane_of_a_shown_window
      raw = pane_row("%1", "ttys001", "1", "1", "0") + pane_row("%2", "ttys002", "1", "1", "x") +
            pane_row("%3", "ttys003", "0", "1", "x") + pane_row("%4", "ttys004", "?", "1", "0")
      rows = parse_rows(raw, client_row("s"), NOW)
      assert_equal [false, nil, false, nil], rows.values_at("ttys001", "ttys002", "ttys003", "ttys004").map { |h| h[:focused] }
    end

    def test_parse_panes_by_tty_a_grouped_pane_is_focused_if_any_session_focuses_it
      row = ->(active, pane_active) { pane_row("%1", "ttys001", active, "1", pane_active) }
      focused = ->(raw) { parse_rows(raw, client_row("s"), NOW)["ttys001"][:focused] }
      assert focused.call(row["0", "1"] + row["1", "1"])
      assert_nil focused.call(row["0", "1"] + row["1", "x"])
      assert_equal false, focused.call(row["0", "1"] + row["1", "0"])
      assert_nil focused.call(row["1", "x"] + row["0", "1"]), "unknown first stays unknown"
      assert focused.call(row["1", "1"] + row["1", "0"]), "focused first stays focused"
    end

    # Value: protects=a click or scroll (or a keystroke about to move focus) on a pane in view
    # holds the typing; fails_when=client activity is ignored, read from the wrong session, or
    # unknown reads as quiet; why_new=ship 4 mouse review; seam=none
    def test_parse_panes_by_tty_recent_input_is_any_clients_activity
      shown = pane_row("%1", "ttys001", "1", "1", "0")
      input = ->(clients) { parse_rows(shown, clients, NOW)["ttys001"][:recent_input] }
      assert input.call(client_row("s", activity: NOW - 1)), "input a second ago"
      assert input.call(client_row("s", activity: NOW - Tmux::INPUT_QUIET)), "whole seconds: the boundary still counts, so the quiet is at least INPUT_QUIET"
      assert_equal false, input.call(client_row("s", activity: NOW - Tmux::INPUT_QUIET - 1))
      assert input.call(client_row("s", activity: NOW - 60) + client_row("s", activity: NOW)), "the newest client wins"
      assert input.call(client_row("other", activity: NOW) + client_row("s")),
             "server-wide: a send-keys binding in another session can type into this pane"
      assert_nil input.call(client_row("s", activity: "x")), "garbled activity is unknown"
      assert_nil input.call(client_row("s", activity: "x") + client_row("s")), "a garbled client isn't outvoted by a quiet one"
      assert_nil input.call(client_row("s") + client_row("s", activity: "x")), "nor in the other order"
      assert_equal false, input.call(""), "no client at all: nobody's input"
      hidden = pane_row("%1", "ttys001", "0", "1", "1")
      assert parse_rows(hidden, client_row("s", activity: NOW), NOW)["ttys001"][:recent_input],
             "a pane nobody sees can still be typed into by send-keys"
    end

    # Value: protects=a click in any session showing a grouped pane counts, whichever row lists first;
    # fails_when=the merge keeps the last row's input; why_new=ship 4 pass 2 testing; seam=none
    def test_parse_panes_by_tty_a_grouped_pane_has_recent_input_if_any_session_does
      rows = [pane_row("%1", "ttys001", "1", "1", "0", "s"), pane_row("%1", "ttys001", "1", "1", "0", "t")]
      clients = client_row("s") + client_row("t", activity: NOW)
      [rows.join, rows.reverse.join].each do |raw|
        assert parse_rows(raw, clients, NOW)["ttys001"][:recent_input]
      end
    end

    # Value: protects=a control-mode client (tmux -CC), which keys any pane by %id, makes every
    # pane of its session unknown; fails_when=control mode is ignored; why_new=ship 4 security; seam=none
    def test_parse_panes_by_tty_a_control_mode_client_makes_its_session_unknown
      raw = pane_row("%1", "ttys001", "0", "1", "0") + pane_row("%2", "ttys002", "0", "1", "0", "t")
      rows = parse_rows(raw, client_row("s", control: "1") + client_row("t"), NOW)
      assert_equal [nil, nil], [rows["ttys001"][:focused], rows["ttys001"][:recent_input]]
      assert_equal [false, false], [rows["ttys002"][:focused], rows["ttys002"][:recent_input]], "other sessions unaffected"
      [client_row("s", control: "1") + client_row("s"), client_row("s") + client_row("s", control: "1")].each do |clients|
        row = parse_rows(raw, clients, NOW)["ttys001"]
        assert_equal [nil, nil], [row[:focused], row[:recent_input]], "a normal client beside it doesn't clear it: #{clients.inspect}"
      end
      garbled = parse_rows(raw, client_row("s", control: "?"), NOW)["ttys001"]
      assert_nil garbled[:focused], "an unreadable control flag is unknown"
      own = parse_rows(raw, client_row("s", flags: "attached,active-pane,focused") + client_row("t"), NOW)
      assert_equal [nil, nil], [own["ttys001"][:focused], own["ttys001"][:recent_input]],
                   "a client with its own active pane (some tmux 3.x) keys a pane the window doesn't call active"
    end

    # Value: protects=a client row cut short (no session field) makes the whole list unknown, not a
    # client of session ""; fails_when=the row is filed under ""; why_new=ship 5 coverage audit; seam=none
    def test_parse_panes_by_tty_a_truncated_client_row_is_unknown
      row = parse_rows(pane_row("%1", "ttys001", "0", "1", "0"), "#{NOW - 60}\t0\n" + client_row("s"), NOW)["ttys001"]
      assert_equal [nil, nil], [row[:focused], row[:recent_input]]
    end

    # Value: protects=an unreadable client list never reads as "nobody there"; fails_when=nil
    # clients parse as empty; why_new=ship 4; seam=none
    def test_parse_panes_by_tty_an_unreadable_client_list_is_unknown
      row = parse_rows(pane_row("%1", "ttys001", "0", "1", "0"), nil, NOW)["ttys001"]
      assert_equal [nil, nil], [row[:focused], row[:recent_input]]
    end

    # Value: protects=a tmux without the client_flags format (it expands to "") still lets an
    # unfocused pane be typed into; fails_when=an empty flags field reads as unknown, holding every
    # pane until the ceiling; why_new=only full flag strings were covered; seam=none; no_claim=which tmux release added client_flags
    def test_parse_panes_by_tty_an_empty_client_flags_field_is_not_unknown
      row = parse_rows(pane_row("%1", "ttys001", "1", "1", "0"), client_row("s", flags: ""), NOW)["ttys001"]
      assert_equal [false, false], [row[:focused], row[:recent_input]]
    end

    # Value: protects=notices never get shorter than the user's own display-time, and their
    # 0 (until a key) is kept; fails_when=a fixed hold overrides it; why_new=ship 4 red team; seam=none
    def test_notify_hold_is_never_shorter_than_display_time
      assert_equal Tmux::NOTIFY_MS, Tmux.notify_hold("750\n")
      assert_equal 10_000, Tmux.notify_hold("10000")
      assert_equal 0, Tmux.notify_hold("0")
      assert_equal Tmux::NOTIFY_MS, Tmux.notify_hold("")
      assert_equal Tmux::NOTIFY_MS, Tmux.notify_hold("x")
    end

    def test_parse_ttys_strips_dev_prefix_and_dedupes
      raw = "/dev/ttys001\n/dev/ttys002\n/dev/ttys001\n"
      assert_equal Set["ttys001", "ttys002"], Tmux.parse_ttys(raw)
    end

    def test_parse_ttys_drops_no_tty_markers_and_blanks
      # A pane with no tty ("??"/"-") must not seed a tty that a no-tty process matches.
      assert_equal Set["pts/3"], Tmux.parse_ttys("/dev/pts/3\n??\n-\n\n")
    end

    def test_parse_sidebar_processes_keeps_only_this_servers_sidebar_rows
      raw = +"  101 900 ttys005 ruby /x/bin/switchboard sidebar\n"    # ours (parent = server 900)
      raw << "  202 900 ttys006 ruby /x/bin/switchboard prune\n"      # ours but not a sidebar
      raw << "  303 900 ?? ruby /x/bin/switchboard sidebar\n"         # ours, no tty -> tty nil
      raw << "  404 111 ttys007 ruby /x/bin/switchboard sidebar\n"    # a DIFFERENT server's sidebar
      # Only sidebar rows whose parent is OUR server (900) survive; the foreign 404
      # (another server — e.g. the dev's real one during a throwaway prune) is filtered
      # out. That ppid scope is the structural guard against reaping a real sidebar.
      assert_equal [[101, "ttys005"], [303, nil]], Tmux.parse_sidebar_processes(raw, 900)
    end

    def test_parse_sidebar_processes_excludes_everything_when_server_pid_unknown
      # nil owner_pid (server unreachable) matches no parent -> reap nothing: the fail-safe
      # direction, never a mass-reap on a bad read.
      raw = "101 900 ttys005 ruby /x/bin/switchboard sidebar\n"
      assert_empty Tmux.parse_sidebar_processes(raw, nil)
    end

    def test_parse_sidebar_processes_ignores_a_header_or_garbled_line
      raw = "PID PPID TTY COMMAND\n\nnotanumber 900 ttys001 switchboard sidebar\n"
      assert_empty Tmux.parse_sidebar_processes(raw, 900)
    end

    def test_normalize_tty_bridges_dev_prefix_and_no_tty_markers
      assert_equal "ttys048", Tmux.normalize_tty("/dev/ttys048")
      assert_equal "pts/3", Tmux.normalize_tty("pts/3")
      assert_nil Tmux.normalize_tty("??")
      assert_nil Tmux.normalize_tty("  ")
    end

    # --- parse_window_panes: the pure count parse behind the #64 lone-pane check.
    # A confirmed integer drives the "am I the only pane?" decision; anything
    # empty/garbled is "unknown" -> nil -> the caller keeps running (degrade, never
    # self-terminate on a flaky shell-out — the owns_pane? house rule).

    def test_parse_window_panes_reads_a_count
      assert_equal 1, Tmux.parse_window_panes("1\n")
      assert_equal 2, Tmux.parse_window_panes("  2  ")
    end

    def test_parse_window_panes_is_nil_on_empty_or_garbled_input
      assert_nil Tmux.parse_window_panes(""), "no reply (no server / dead pane) -> unknown"
      assert_nil Tmux.parse_window_panes("\n")
      assert_nil Tmux.parse_window_panes("nonsense"), "a non-numeric reply rescues to nil, never raises"
      assert_nil Tmux.parse_window_panes("2 panes"), "a partial/garbled line is not a usable count"
    end

    # --- parse_window_size / new_session_cmd: build a detached session at the
    # client's size so switching into it never reflows 80x24 -> client (the
    # "creating" flash). The parse is pure; the argv assembly is testable via the
    # current_window_size seam.

    def test_parse_window_size_reads_a_width_height_pair
      assert_equal [220, 50], Tmux.parse_window_size("220,50\n")
      assert_equal [80, 24], Tmux.parse_window_size("  80,24  ")
    end

    def test_parse_window_size_is_a_nil_pair_on_empty_or_garbled_input
      assert_equal [nil, nil], Tmux.parse_window_size(""), "no reply -> unknown, fall back to default sizing"
      assert_equal [nil, nil], Tmux.parse_window_size("220"), "a half pair is not a usable size"
      assert_equal [nil, nil], Tmux.parse_window_size("x,y"), "a non-numeric reply rescues to the nil pair, never raises"
    end

    def test_new_session_cmd_sizes_the_session_to_the_current_window
      stub_method(Tmux, :current_window_size, -> { [220, 50] }) do
        cmd = Tmux.new_session_cmd("sb/app/x", "/wt/x")
        assert_equal ["tmux", "new-session", "-d", "-s", "sb/app/x", "-c", "/wt/x", "-x", "220", "-y", "50"], cmd
      end
    end

    def test_new_session_cmd_omits_the_size_when_unknown
      # Off-tmux (no current window): no -x/-y, so the exec-attach path sizes the
      # window on attach exactly as before.
      stub_method(Tmux, :current_window_size, -> { [nil, nil] }) do
        cmd = Tmux.new_session_cmd("sb/app/x", "/wt/x")
        assert_equal ["tmux", "new-session", "-d", "-s", "sb/app/x", "-c", "/wt/x"], cmd
      end
    end

    def test_new_session_cmd_omits_a_zero_dimension
      # A 0 dim (an openpty that came up 0x0) would make `new-session -x 0` fail
      # ("width too small") and create NOTHING — worse than the 80x24 default.
      # Only a positive pair is applied; otherwise fall back to the default.
      stub_method(Tmux, :current_window_size, -> { [0, 50] }) do
        cmd = Tmux.new_session_cmd("sb/app/x", "/wt/x")
        assert_equal ["tmux", "new-session", "-d", "-s", "sb/app/x", "-c", "/wt/x"], cmd,
                     "a non-positive dimension is dropped, not passed as -x 0"
      end
    end

    # --- ensure_work_pane: only splits a shell when the sidebar is the SOLE pane
    # (#64 home self-heal / fall-home landing). The two short-circuits are the
    # testable guards; the actual split is a raw shell-out, covered by the smoke layer.

    def test_ensure_work_pane_noops_when_a_work_pane_already_exists
      stub_method(Tmux, :window_sidebar_pane, ->(*) { "%1" }) do
        stub_method(Tmux, :window_panes, ->(*) { 2 }) do # already has a work sibling
          assert_nil Tmux.ensure_work_pane("sb/home"), "a healthy window is left untouched"
        end
      end
    end

    def test_ensure_work_pane_noops_when_there_is_no_sidebar_pane
      stub_method(Tmux, :window_sidebar_pane, ->(*) { nil }) do
        assert_nil Tmux.ensure_work_pane("sb/home"), "nothing to sit a work pane beside"
      end
    end

    # --- poke_sidebar_of: the config-reload / switch poke by session name ------
    # It resolves the sidebar pane via window_sidebar_pane and send-keys the poke.
    # Regression: it once called a nonexistent `sidebar_pane`, so EVERY real call
    # (the `e`-editor reload trailer, remove_project's home poke) raised
    # NoMethodError — invisible offline because unit tests always stub the method.

    def test_poke_sidebar_of_sends_the_reload_config_key_to_the_resolved_pane
      sent = nil
      stub_method(Tmux, :window_sidebar_pane, ->(s) { s == "sb/app/x" ? "%7" : nil }) do
        stub_method(Tmux, :system, ->(*args, **) { sent = args }) do
          Tmux.poke_sidebar_of("sb/app/x", reload_config: true)
        end
      end
      assert_equal ["tmux", "send-keys", "-t", "%7", "C-r"], sent,
                   "resolves the pane via window_sidebar_pane and pokes it with C-r (not the old NoMethodError)"
    end

    def test_poke_sidebar_of_defaults_to_the_c_l_switch_key
      sent = nil
      stub_method(Tmux, :window_sidebar_pane, ->(*) { "%3" }) do
        stub_method(Tmux, :system, ->(*args, **) { sent = args }) do
          Tmux.poke_sidebar_of("sb/app/x")
        end
      end
      assert_equal "C-l", sent&.last, "the plain poke is the switch-reload key"
    end

    def test_poke_sidebar_of_noops_without_a_sidebar_pane
      sent = false
      stub_method(Tmux, :window_sidebar_pane, ->(*) { nil }) do
        stub_method(Tmux, :system, ->(*) { sent = true }) do
          assert_nil Tmux.poke_sidebar_of("sb/app/x", reload_config: true),
                     "no sidebar in that session -> nil so the caller can fall back"
        end
      end
      refute sent, "and nothing is send-keys'd"
    end

    # Value: protects=a notice stays up long enough to read (tmux's 750 ms default was gone
    # first); fails_when=-d is dropped; why_new=rename notice unreadable; seam=none
    def test_notify_holds_the_message_on_the_status_line
      calls = []
      stub_method(Tmux, :system, ->(*args, **) { calls << args }) { Tmux.notify("hello") }
      assert_equal [["tmux", "display-message", "-d", Tmux::NOTIFY_MS.to_s, "hello"]], calls
    end

    # Value: protects=a tmux older than 3.2 (no -d) still shows the notice; fails_when=the
    # refused -d call isn't retried; why_new=-d needs tmux 3.2, switchboard supports 3.0; seam=none
    def test_notify_falls_back_to_a_plain_message_when_tmux_refuses_d
      calls = []
      stub_method(Tmux, :system, ->(*args, **) { calls << args; calls.size > 1 }) { Tmux.notify("hello") }
      assert_equal ["tmux", "display-message", "hello"], calls.last
      assert_equal 2, calls.size
    end

    # Value: protects=a notice carrying error text shows it literally (display-message's text is
    # a format: #{} expands, #() runs a command); fails_when=the # escape is dropped on either
    # call; why_new=ship 4 security review; seam=none
    def test_notify_shows_hash_sequences_literally
      calls = []
      stub_method(Tmux, :system, ->(*args, **) { calls << args; false }) { Tmux.notify('bad #(touch x) #{pane_id} 100%y') }
      assert_equal ['bad ##(touch x) ##{pane_id} 100%%y'], calls.map(&:last).uniq, "strftime reads % too"
    end

    # Value: protects=a worker's notice reaches every attached client (its own "current client" may
    # be a session nobody is in), held for the caller's display_time; fails_when=-c is dropped, only
    # one client gets it, or the hold is ignored; why_new=ship 5 red team; seam=none
    def test_notify_everyone_targets_each_attached_client
      sent = []
      popen = lambda do |_argv, **, &blk|
        system(RbConfig.ruby, "-e", "exit 0")
        blk.call(StringIO.new("/dev/ttys001\n/dev/ttys002\n"))
      end
      stub_method(IO, :popen, popen) do
        stub_method(Tmux, :system, ->(*args, **) { sent << args; true }) { Tmux.notify_everyone("hi", display_time: "10000") }
      end
      assert_equal [["tmux", "display-message", "-c", "/dev/ttys001", "-d", "10000", "hi"],
                    ["tmux", "display-message", "-c", "/dev/ttys002", "-d", "10000", "hi"]], sent
    end

    # Value: protects=notify_everyone still shows the notice (untargeted) when there's no client
    # list, it fails, or it raises; fails_when=a fallback is dropped; why_new=ship 5 testing; seam=none
    def test_notify_everyone_falls_back_to_a_plain_notice
      ruby = RbConfig.ruby
      { "empty" => ->(*, &blk) { system(ruby, "-e", "exit 0"); blk.call(StringIO.new("")) },
        "failed" => ->(*, &blk) { system(ruby, "-e", "exit 1"); blk.call(StringIO.new("/dev/ttys001\n")) },
        "raised" => ->(*, **) { raise IOError } }.each do |what, popen|
        plain = []
        stub_method(IO, :popen, popen) do
          stub_method(Tmux, :notify, ->(msg, **kw) { plain << [msg, kw] }) { Tmux.notify_everyone("hi", display_time: "10000") }
        end
        assert_equal ["hi"], plain.map(&:first), what
        refute plain.first.last.key?(:client), "#{what}: untargeted"
        assert_equal "10000", plain.first.last[:display_time], "#{what}: the caller's hold survives the fallback"
      end
    end

    # Value: protects=back-out's "nobody touched a key since our send" proof: the newest input of ANY
    # client, 0 with none, nil when unknown (garbled activity, unreadable list, a control-mode or
    # active-pane session); fails_when=per-session, or unknown reads as 0; why_new=ship 5; seam=none
    def test_parse_panes_by_tty_last_input_is_the_newest_client_input
      row = ->(clients, raw = pane_row("%1", "ttys001", "0", "1", "0")) { parse_rows(raw, clients, NOW)["ttys001"][:last_input] }
      assert_equal NOW - 5, row.call(client_row("s", activity: NOW - 60) + client_row("other", activity: NOW - 5))
      assert_equal NOW - 120, row.call(""), "no client: the sessions' newest still counts"
      assert_nil row.call(client_row("s", activity: "x"))
      assert_nil row.call(nil)
      assert_nil row.call(client_row("s", control: "1"))
      grouped = pane_row("%1", "ttys001", "0", "1", "0", "s") + pane_row("%1", "ttys001", "0", "1", "0", "t")
      assert_nil row.call(client_row("s") + client_row("t", control: "1"), grouped), "unknown in any grouped session wins"
    end

    # Value: protects=no notice ever carries -N, which DISCARDS the client's keys until it expires
    # (verified on tmux 3.8); fails_when=-N comes back; why_new=ship 6 security review; seam=none
    def test_a_notice_never_swallows_keys
      sent = []
      stub_method(Tmux, :system, ->(*args, **) { sent << args; false }) { Tmux.notify("hi", client: "/dev/ttys001", display_time: "10000") }
      assert_equal [["tmux", "display-message", "-c", "/dev/ttys001", "-d", "10000", "hi"],
                    ["tmux", "display-message", "-c", "/dev/ttys001", "hi"]], sent
      refute_includes sent.flatten, "-N"
    end

    # Value: protects=a caller that omits the client list fails closed (unknown), like every other
    # unreadable input; fails_when=the default reads as "no clients"; why_new=ship 5 security; seam=none
    def test_parse_panes_by_tty_without_a_client_list_is_unknown
      row = parse_rows(pane_row("%1", "ttys001", "0", "1", "0"))["ttys001"]
      assert_equal [nil, nil], [row[:focused], row[:recent_input]]
    end

    # Value: protects=a per-session display-time counts (inside a pane), and outside a session the
    # global is read; fails_when=only -g is read; why_new=ship 4 pass 3 red team; seam=none
    def test_display_time_prefers_the_session_value_then_the_global
      replies = { "tmux show-options -Aqv display-time 2>/dev/null" => "9000\n",
                  "tmux show-options -gqv display-time 2>/dev/null" => "750\n" }
      stub_method(Tmux, :`, ->(cmd) { replies.fetch(cmd) }) { assert_equal "9000", Tmux.display_time }
      replies["tmux show-options -Aqv display-time 2>/dev/null"] = ""
      stub_method(Tmux, :`, ->(cmd) { replies.fetch(cmd) }) { assert_equal "750", Tmux.display_time }
    end

    # Value: protects=a failed list-clients reads as unknown (never as no control client, no input);
    # fails_when=its output is used without checking the exit status; why_new=ship 4 coverage; seam=none
    def test_panes_by_tty_reads_a_failed_client_list_as_unknown
      row = pane_row("%1", "ttys001", "0", "1", "0")
      clients = client_row("s") # outside the lambda: as the stubbed method its self is IO
      popen = lambda do |argv, **, &blk|
        ok = argv[1] == "list-panes"
        system(RbConfig.ruby, "-e", ok ? "exit 0" : "exit 1")
        out = ok ? row : clients
        blk ? blk.call(StringIO.new(out)) : out
      end
      got = stub_method(IO, :popen, popen) { Tmux.panes_by_tty["ttys001"] }
      assert_equal [nil, nil], [got[:focused], got[:recent_input]]
    end

    # --- work_dir: the pure pane-cwd pick (drives the sidebar's -c) -----------
    # spawn_sidebar pins the sidebar pane's cwd to the worktree by reading the
    # window's work-pane path; if it picked the client's path instead the "you
    # are here" highlight wouldn't fire (locate matches the pane path to a node).

    def test_work_dir_picks_the_first_non_sidebar_panes_cwd
      raw = "#{Tmux::SIDEBAR_TITLE}\t/repo/primary\nbash\t/wt/feature\n"
      assert_equal "/wt/feature", Tmux.work_dir(raw)
    end

    def test_work_dir_preserves_paths_with_spaces
      raw = "vim\t/wt/feature one\n#{Tmux::SIDEBAR_TITLE}\t/repo/primary\n"
      assert_equal "/wt/feature one", Tmux.work_dir(raw)
    end

    def test_work_dir_is_nil_when_only_the_sidebar_is_present
      assert_nil Tmux.work_dir("#{Tmux::SIDEBAR_TITLE}\t/repo/primary\n")
      assert_nil Tmux.work_dir(""), "no panes (server gone) -> nil, so -c is just omitted"
    end

    # --- reusable_editor_pane: the pure `e` reuse gate ------------------------
    # `e` stashes its editor pane on home; the next `e` reuses it iff it's still
    # a live home pane, so editor panes can't pile up (the accumulation bug).

    def test_reusable_editor_pane_returns_the_stashed_id_when_still_live
      assert_equal "%3", Tmux.reusable_editor_pane("%3", ["%0", "%1", "%3"])
    end

    def test_reusable_editor_pane_is_nil_when_the_editor_pane_is_gone
      # :q closed the pane; the retired id is absent -> spawn a fresh editor.
      assert_nil Tmux.reusable_editor_pane("%3", ["%0", "%1"])
    end

    def test_reusable_editor_pane_is_nil_when_nothing_is_stashed
      # Option unset -> show-options -v yields "" -> no pane to reuse.
      assert_nil Tmux.reusable_editor_pane("", ["%0", "%1"])
      assert_nil Tmux.reusable_editor_pane("", [])
    end

    # --- pane_switch_keys: the user's own select-pane bindings, surfaced in the ?
    # overlay (issue #62). Pure given the `tmux list-keys -T prefix` output.

    def test_pane_switch_keys_collapses_arrows_and_keeps_letters
      raw = <<~KEYS
        bind-key -T prefix Left select-pane -L
        bind-key -T prefix Right select-pane -R
        bind-key -T prefix Up select-pane -U
        bind-key -T prefix Down select-pane -D
        bind-key -T prefix o select-pane -t :.+
        bind-key -T prefix h select-pane -L
        bind-key -T prefix C-Left resize-pane -L
        bind-key -T prefix x kill-pane
      KEYS
      # all four arrows collapse to one glyph token; o + h kept; resize/kill excluded
      assert_equal ["↑↓←→", "o", "h"], Tmux.pane_switch_keys(raw)
    end

    def test_pane_switch_keys_does_not_collapse_a_partial_arrow_set
      raw = "bind-key -T prefix Left select-pane -L\nbind-key -T prefix Right select-pane -R\n"
      assert_equal ["←", "→"], Tmux.pane_switch_keys(raw), "only ←→ bound -> shown separately, not collapsed"
    end

    def test_pane_switch_keys_empty_when_none_or_unparseable
      assert_empty Tmux.pane_switch_keys(""), "no server / no output -> [] (overlay omits the row)"
      assert_empty Tmux.pane_switch_keys("bind-key -T prefix o next-window\n"), "non-select-pane bindings ignored"
    end

    # Only MOVEMENT select-pane counts — mark/unmark (-m/-M) are select-pane commands
    # but not "move between panes", so they're excluded from the overlay row.
    def test_pane_switch_keys_excludes_mark_and_unmark
      raw = "bind-key -T prefix m select-pane -m\nbind-key -T prefix M select-pane -M\n" \
            "bind-key -T prefix Left select-pane -L\n"
      assert_equal ["←"], Tmux.pane_switch_keys(raw), "mark/unmark dropped; the directional move kept"
    end

    def test_pane_switch_keys_caps_the_list
      raw = %w[a b c d e f g].map { |k| "bind-key -T prefix #{k} select-pane -t :.+" }.join("\n")
      assert_equal 5, Tmux.pane_switch_keys(raw).size, "capped so the overlay row can't overrun the pane"
    end

    def test_pane_switch_keys_collapses_the_vim_cluster
      raw = %w[h j k l].map { |k| "bind-key -T prefix #{k} select-pane -L" }.join("\n")
      assert_equal ["hjkl"], Tmux.pane_switch_keys(raw), "a full hjkl set shows as one token, not four"
    end

    # --- spawn width clamp: a saved width can't starve the work pane (issue #78) ---

    def test_fit_width_returns_the_saved_width_on_a_roomy_window
      assert_equal 76, Tmux.fit_width(76, 200)
    end

    def test_fit_width_clamps_to_leave_room_for_the_work_pane
      assert_equal 68, Tmux.fit_width(76, 80), "80-col client, 76 saved -> 68 so the work pane keeps 12"
    end

    def test_fit_width_uses_the_saved_width_when_cols_is_unknown
      assert_equal 76, Tmux.fit_width(76, nil), "no window size -> the historic behavior"
    end

    def test_fit_width_stays_positive_on_a_tiny_window
      assert_operator Tmux.fit_width(40, 8), :>=, 1, "never emit a non-positive -l"
    end

    # --- name builders share one sanitization --------------------------------

    def test_session_prefix_matches_session_name_under_sanitization
      wt = Worktree.new(project: "app.dev", path: "/wt/feature one")
      prefix = Tmux.session_prefix("app.dev")
      assert_equal "sb/app-dev/", prefix
      assert Tmux.session_name(wt).start_with?(prefix),
             "session_name must start with its project's prefix (collision-safe diffing depends on it)"
    end

    def test_session_prefix_trailing_slash_disambiguates_app_from_app2
      refute Tmux.session_prefix("app2").start_with?(Tmux.session_prefix("app")),
             "the trailing / keeps app from prefix-matching app2"
    end

    # --- kill delegates to the single kill path ------------------------------

    def test_kill_delegates_to_kill_session_with_the_session_name
      wt = Worktree.new(project: "app", path: "/wt/feat")
      killed = nil
      stub_method(Tmux, :kill_session, ->(name) { killed = name; true }) do
        Tmux.kill(wt)
      end
      assert_equal "sb/app/feat", killed
    end

    # --- kill_all: current session dies LAST ---------------------------------

    def test_kill_all_kills_current_session_last_and_returns_all
      live = [{ name: "sb/app/x", created: 1 },
              { name: "sb/home", created: 2 },
              { name: "sb/cur/here", created: 3 }]
      order = []
      result = with_tmux_stubs(live, current: "sb/cur/here",
                               recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_equal %w[sb/app/x sb/home sb/cur/here], order, "current killed last"
      assert_equal %w[sb/app/x sb/home sb/cur/here], result
    end

    def test_kill_all_outside_a_session_kills_all_without_a_trailing_current
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/home", created: 2 }]
      order = []
      with_tmux_stubs(live, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_equal %w[sb/app/x sb/home], order
    end

    def test_kill_all_does_not_double_kill_when_current_is_not_a_switchboard_session
      # Run from a non-sb session: `current` is set but absent from the sb/ list,
      # so the "current last" branch must NOT fire (no second kill of a name).
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/home", created: 2 }]
      order = []
      result = with_tmux_stubs(live, current: "misc/scratch", recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_equal %w[sb/app/x sb/home], order, "a non-sb current session is never killed/double-killed"
      assert_equal %w[sb/app/x sb/home], result
    end

    def test_kill_all_is_empty_when_no_server
      order = []
      result = with_tmux_stubs(nil, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_all
      end
      assert_empty result
      assert_empty order, "nothing killed when tmux is unreachable"
    end

    # --- kill_project_sessions: only one project's sessions, current LAST -----

    def test_kill_project_sessions_kills_only_that_projects_sessions
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/app/y", created: 2 },
              { name: "sb/other/z", created: 3 }, { name: "sb/home", created: 4 }]
      order = []
      result = with_tmux_stubs(live, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_project_sessions("app")
      end
      assert_equal %w[sb/app/x sb/app/y], order, "leaves other projects and home alone"
      assert_equal %w[sb/app/x sb/app/y], result
    end

    def test_kill_project_sessions_kills_current_last
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/app/here", created: 2 }]
      order = []
      with_tmux_stubs(live, current: "sb/app/here", recorder: ->(name) { order << name }) do
        Tmux.kill_project_sessions("app")
      end
      assert_equal %w[sb/app/x sb/app/here], order, "the session we're in dies last"
    end

    # The trailing-slash prefix means project "app" never claims "app2"'s sessions.
    def test_kill_project_sessions_does_not_over_kill_a_prefix_sibling
      live = [{ name: "sb/app/x", created: 1 }, { name: "sb/app2/y", created: 2 }]
      order = []
      with_tmux_stubs(live, current: nil, recorder: ->(name) { order << name }) do
        Tmux.kill_project_sessions("app")
      end
      assert_equal %w[sb/app/x], order, "app2 is a different project, untouched"
    end

    def test_kill_project_sessions_is_empty_when_no_server
      result = with_tmux_stubs(nil, current: nil, recorder: ->(_n) {}) do
        Tmux.kill_project_sessions("app")
      end
      assert_empty result
    end

    # --- toggle_sidebar: prefix-s is the one summon/dismiss verb --------------

    # Visible in the current window → dismiss session-wide: persist @sb_sidebar
    # off and reconcile the session closed. No focus move (nothing to focus).
    def test_toggle_sidebar_dismisses_when_the_tree_is_visible
      flag = nil
      reconciled = nil
      focused = false
      with_toggle_stubs(current_pane: "%9", on_flag: ->(s, v) { flag = [s, v] },
                        on_reconcile: ->(s, on) { reconciled = [s, on] },
                        on_focus: -> { focused = true }) do
        Tmux.toggle_sidebar
      end
      assert_equal ["sb/app/x", "off"], flag, "persists the off intent on the session"
      assert_equal ["sb/app/x", false], reconciled, "reconciles the session closed"
      refute focused, "dismiss never moves focus"
    end

    # Hidden in the current window → summon every window AND focus the new tree,
    # so prefix-s is the whole round-trip (the retired `h` left focus on the work
    # pane).
    def test_toggle_sidebar_summons_and_focuses_when_the_tree_is_hidden
      flag = nil
      reconciled = nil
      focused = false
      with_toggle_stubs(current_pane: nil, on_flag: ->(s, v) { flag = [s, v] },
                        on_reconcile: ->(s, on) { reconciled = [s, on] },
                        on_focus: -> { focused = true }) do
        Tmux.toggle_sidebar
      end
      assert_equal ["sb/app/x", "on"], flag, "persists the on intent on the session"
      assert_equal ["sb/app/x", true], reconciled, "reconciles the session open"
      assert focused, "summon drops focus into the tree"
    end

    # --- poke_window: the same-session window-switch poke (gated to sb/) --------

    def test_poke_window_pokes_an_sb_windows_sidebar
      poked = :unset
      stub_method(Tmux, :session_of_window, ->(_w) { "sb/app/x" }) do
        stub_method(Tmux, :window_sidebar_pane, ->(_w) { "%9" }) do
          stub_method(Tmux, :poke, ->(pane) { poked = pane }) do
            Tmux.poke_window("@3")
          end
        end
      end
      assert_equal "%9", poked, "an sb/ window's sidebar gets the C-l reload poke"
    end

    # The hook is global — it fires on EVERY window switch in EVERY session. It must
    # do ~nothing on unrelated windows: one session lookup, then bail before any poke.
    def test_poke_window_is_a_noop_for_a_non_sb_session
      poked = false
      stub_method(Tmux, :session_of_window, ->(_w) { "work" }) do
        stub_method(Tmux, :poke, ->(*) { poked = true }) do
          Tmux.poke_window("@3")
        end
      end
      refute poked, "the global hook never pokes a non-sb/ window"
    end

    def test_poke_window_is_a_noop_on_a_blank_window
      poked = false
      stub_method(Tmux, :poke, ->(*) { poked = true }) do
        Tmux.poke_window("")
      end
      refute poked
    end

    private

    # Stub the seams toggle_sidebar drives: the session it reads, whether the
    # current window already shows a sidebar, and the three effects.
    def with_toggle_stubs(current_pane:, on_flag:, on_reconcile:, on_focus:)
      stub_method(Tmux, :current_session, -> { "sb/app/x" }) do
        stub_method(Tmux, :current_sidebar_pane, -> { current_pane }) do
          stub_method(Tmux, :set_sidebar_flag, ->(s, v) { on_flag.call(s, v) }) do
            stub_method(Tmux, :reconcile_sidebars, ->(s, on) { on_reconcile.call(s, on) }) do
              stub_method(Tmux, :focus_current_sidebar, -> { on_focus.call }) do
                return yield
              end
            end
          end
        end
      end
    end

    # Stub the three Tmux seams kill_all leans on, then run the block.
    def with_tmux_stubs(live, current:, recorder:)
      stub_method(Tmux, :sessions, -> { live }) do
        stub_method(Tmux, :session_of, ->(*) { current }) do
          stub_method(Tmux, :kill_session, ->(name) { recorder.call(name); true }) do
            return yield
          end
        end
      end
    end
  end
end
