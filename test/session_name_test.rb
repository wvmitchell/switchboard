# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  # The session-name worker: the prompt-box parser (pinned by real Claude Code 2.1.310
  # captures in test/fixtures/session_name), the typing rule, and the worker loop. No
  # real Claude or tmux: a FakeClaude stands in for the pane and its session file.
  class SessionNameTest < SandboxTest
    FIXTURES = File.expand_path("fixtures/session_name", __dir__)

    def fixture(name)
      File.read(File.join(FIXTURES, "#{name}.txt"))
    end

    # One Claude pane + session file. `box` is what the prompt box holds; typing and
    # keys act on it like Claude's input would. `on_type` runs right after our text
    # lands, to stage what happens in the window before Enter.
    class FakeClaude
      attr_accessor :box, :status, :visible, :name, :screen_override, :on_type, :present, :in_mode, :foreground,
                    :width, :swallow, :synchronized, :claude_tty
      attr_reader :keys

      def initialize(status: "idle", visible: false, box: "", name: "old-xy")
        @status = status
        @visible = visible
        @box = box
        @name = name
        @keys = []
        @present = true
        @in_mode = false
        @foreground = true
        @width = 120
        @synchronized = false
        @claude_tty = "ttys001"
      end

      def screen
        return @screen_override if @screen_override

        rule = "\e[38;2;136;136;136m#{'─' * 40}"
        line = @box.empty? ? "\e[39m❯ \e[2mTry \"refactor <filepath>\"\e[0m" : "\e[39m❯ #{@box}"
        "older output\n#{rule}\n#{line}\n#{rule}\n\e[39m  ⏵⏵ auto mode on\n"
      end

      # `swallow`: the keys went to something else in front of Claude (they never reach the box).
      def type(text)
        @keys << [:literal, text]
        @box += text unless swallow
        on_type&.call(self)
        true
      end

      def press(*keys)
        @keys << keys
        keys.each do |k|
          case k
          when "BSpace" then @box = @box[0...-1]
          when "Enter"
            @name = @box.delete_prefix("/rename ") if @box.start_with?("/rename ")
            @box = ""
          end
        end
        true
      end

      def typed?
        !@keys.empty?
      end

      def session
        { pid: 4242, proc_start: "start", status: @status, name: @name, kind: "interactive" }
      end
    end

    def with_fake(fake, panes: :default, same: true, &blk)
      panes = { "ttys001" => { pane: "%1" } } if panes == :default
      stubs = [
        [ClaudeSessions, :sessions_in, ->(_) { fake.present ? [fake.session] : [] }],
        [SessionName::Claude, :current, ->(_) { fake.status && { status: fake.status, name: fake.name } }],
        [SessionName::Claude, :tty_of, ->(_) { "ttys001\n" }],
        [ProcessIdentity, :same?, ->(*) { same }],
        [SessionName::Claude, :foreground?, ->(_, tty) { fake.foreground && tty == fake.claude_tty }],
        [Tmux, :panes_by_tty, lambda {
          next panes.call if panes.is_a?(Proc)

          panes&.transform_values { |v| { visible: fake.visible, in_mode: fake.in_mode, synchronized: fake.synchronized, width: fake.width }.merge(v) }
        }],
        [Tmux, :capture_pane, ->(_) { fake.screen }],
        [Tmux, :send_literal, ->(_, text) { fake.type(text) }],
        [Tmux, :send_keys, ->(_, *keys) { fake.press(*keys) }],
        [SessionName, :pause, ->(_) {}]
      ]
      stubs.reverse.reduce(blk) { |inner, (recv, name, impl)| -> { stub_method(recv, name, impl, &inner) } }.call
    end

    def ws(name = "named-it")
      d = path("worktrees", "proj", name)
      FileUtils.mkdir_p(d)
      d
    end

    def deliver(fake, name = "named-it")
      with_fake(fake) { SessionName::Claude.sync(ws(name), name) }
    end

    # --- Box: the prompt-box parser, on real captures ---

    def test_box_reads_real_claude_captures
      assert_equal :empty, SessionName::Box.parse(fixture("idle")), "dim placeholder, reset on the same line"
      assert_equal :empty, SessionName::Box.parse(fixture("idle_crossline")), "dim carried over the line break"
      assert_equal :empty, SessionName::Box.parse(fixture("renamed")), "bare ❯ under a divider carrying the name"
      assert_equal [:text, "half typed draft"], SessionName::Box.parse(fixture("draft"))
      assert_equal [:text, "/rena"], SessionName::Box.parse(fixture("prefix")), "the slash menu above the box is ignored"
      assert_equal [:text, "/rename fixture-a"], SessionName::Box.parse(fixture("typed_rename"))
      assert_equal :draft, SessionName::Box.parse(fixture("multiline"))
    end

    # Value: protects=a modal (whose cursor also draws ❯) never reads as an empty box;
    # fails_when=the parser anchors on ❯ instead of the dividers; why_new=new parser; seam=none
    def test_box_without_two_dividers_or_a_prompt_line_is_unrecognized
      assert_equal :unrecognized, SessionName::Box.parse("Do you want to proceed?\n❯ 1. Yes\n  2. No\n")
      assert_equal :unrecognized, SessionName::Box.parse("#{'─' * 20}\n  Allow this command?\n#{'─' * 20}\n")
      assert_equal :unrecognized, SessionName::Box.parse("#{'─' * 20}\n#{'─' * 20}\n")
      assert_equal :unrecognized, SessionName::Box.parse("")
    end

    def test_box_uses_the_last_divider_pair
      older = "#{'─' * 20}\n❯ old echoed prompt\n#{'─' * 20}\n"
      assert_equal :empty, SessionName::Box.parse("#{older}text\n#{'─' * 20}\n❯ \n#{'─' * 20}\n")
    end

    # Value: protects=a dim placeholder is told from text by its SGR, not its look;
    # fails_when=color params (38;2;r;g;b with a 2) read as dim; why_new=new; seam=none
    def test_box_color_numbers_are_not_the_dim_attribute
      rule = "─" * 20
      assert_equal [:text, "hi"], SessionName::Box.parse("#{rule}\n❯ \e[38;2;2;2;2mhi\n#{rule}\n")
      assert_equal [:text, "hi"], SessionName::Box.parse("#{rule}\n❯ \e[38;5;2mhi\n#{rule}\n")
      assert_equal :empty, SessionName::Box.parse("#{rule}\n❯ \e[1;2mTry this\n#{rule}\n")
      assert_equal :draft, SessionName::Box.parse("#{rule}\n❯ typed\e[2m ghost\n#{rule}\n"), "mixed dim + text"
      # Value: protects=text after a 22 (normal intensity) or bare \e[m reset reads as typed, so a
      # user's draft is never mistaken for an empty box; fails_when=either reset stops clearing dim;
      # why_new=the real captures only ever reset with \e[0m; seam=none; no_claim=which reset Claude/tmux emit
      assert_equal :draft, SessionName::Box.parse("#{rule}\n❯ \e[2mghost\e[22mtyped\n#{rule}\n"), "22 ends dim"
      assert_equal :draft, SessionName::Box.parse("#{rule}\n❯ \e[2mghost\e[mtyped\n#{rule}\n"), "bare SGR resets"
    end

    # --- Claude.deliver: the typing rule ---

    def test_idle_hidden_empty_box_types_the_rename_and_presses_enter
      fake = FakeClaude.new
      assert_equal :done, deliver(fake)
      assert_equal "named-it", fake.name
      assert_equal [[:literal, "/rename named-it"], ["Enter"]], fake.keys
    end

    def test_a_shell_status_is_between_turns_too
      fake = FakeClaude.new(status: "shell")
      assert_equal :done, deliver(fake)
    end

    # Value: protects=Enter can never approve a permission modal; fails_when=busy/waiting/
    # unknown statuses are typed into; why_new=D11; seam=none
    def test_mid_turn_a_modal_or_an_unknown_status_types_nothing
      ["busy", "waiting", "pondering", nil].each do |status|
        fake = FakeClaude.new(status: status)
        assert_equal :waiting, deliver(fake), status.inspect
        refute fake.typed?, "typed during #{status.inspect}"
      end
    end

    def test_a_watched_or_maybe_watched_pane_types_nothing
      [true, nil].each do |visible|
        fake = FakeClaude.new(visible: visible)
        assert_equal :waiting, deliver(fake)
        refute fake.typed?
      end
    end

    def test_a_draft_in_the_box_is_never_touched
      fake = FakeClaude.new(box: "half typed")
      assert_equal :waiting, deliver(fake)
      refute fake.typed?
    end

    def test_an_unreadable_box_types_nothing_and_says_so
      fake = FakeClaude.new
      fake.screen_override = "no box here\n"
      assert_equal :unrecognized, deliver(fake)
      refute fake.typed?
    end

    def test_an_already_named_session_or_one_outside_tmux_needs_nothing
      assert_equal :done, deliver(FakeClaude.new(name: "named-it"))
      fake = FakeClaude.new
      assert_equal :done, with_fake(fake, panes: {}) { SessionName::Claude.sync(ws, "named-it") }
      refute fake.typed?
    end

    def test_a_recycled_pid_or_an_unreadable_pane_list_types_nothing
      fake = FakeClaude.new
      assert_equal :waiting, with_fake(fake, same: false) { SessionName::Claude.sync(ws, "named-it") }
      assert_equal :waiting, with_fake(fake, panes: nil) { SessionName::Claude.sync(ws, "named-it") }
      refute fake.typed?
    end

    # Value: protects=no Enter once the agent wakes (D11's pre-Enter re-read); fails_when=
    # the status is read only before typing; why_new=D11; seam=none
    def test_a_turn_starting_while_typing_backs_out_exactly_our_text
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.status = "busy" }
      assert_equal :waiting, deliver(fake)
      assert_equal "", fake.box
      assert_equal "old-xy", fake.name
      assert_equal ["BSpace"] * "/rename named-it".length, fake.keys.last
      refute_includes fake.keys.flatten, "Enter"
    end

    # Value: protects=no backspace lands on a pane someone just switched to (they may be
    # typing); fails_when=back_out ignores visibility; why_new=run-3 state-machine review; seam=none
    def test_switching_to_the_pane_while_typing_leaves_the_text_for_whoever_is_looking
      [true, nil].each do |seen|
        fake = FakeClaude.new
        fake.on_type = ->(f) { f.visible = seen }
        assert_equal :failed_send, deliver(fake), "visible=#{seen.inspect}"
        assert_equal "/rename named-it", fake.box
        assert_equal [[:literal, "/rename named-it"]], fake.keys, "no key follows the text"
      end
    end

    # Value: protects=a key typed (or a backspace on our text) during back_out's checks isn't
    # erased; fails_when=back_out sends backspaces off its first read; why_new=run-3 review; seam=none
    def test_a_box_that_changes_during_the_back_out_checks_gets_no_backspaces
      { "/rename named-itx" => ->(f) { f.box += "x" }, "/rename named-i" => ->(f) { f.box = f.box[0...-1] } }.each do |left, change|
        fake = FakeClaude.new
        fake.on_type = ->(f) { f.status = "busy" }
        reads = 0
        panes = lambda {
          reads += 1
          change.call(fake) if reads == 4 # snapshot, pre-type, pre-Enter, then back_out's pane check
          { "ttys001" => { pane: "%1", visible: false, in_mode: false, synchronized: false, width: 120 } }
        }
        assert_equal :failed_send, with_fake(fake, panes: panes) { SessionName::Claude.sync(ws, "named-it") }
        assert_equal left, fake.box
        assert_equal [[:literal, "/rename named-it"]], fake.keys
      end
    end

    # Value: protects=a raise after the backspaces went out doesn't send a second round from the
    # ensure; fails_when=settled is set only after back_out returns; why_new=run-3 review; seam=none
    def test_a_crash_after_the_back_out_keys_sends_no_second_round
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.status = "busy" }
      with_fake(fake) do
        stub_method(Tmux, :send_keys, lambda { |_, *keys|
          next fake.press(*keys) unless keys.include?("BSpace")

          fake.keys << keys # sent, but not drawn yet: the box still shows our line
          raise "tmux went away"
        }) { assert_raises(RuntimeError) { SessionName::Claude.sync(ws, "named-it") } }
      end
      assert_equal 1, fake.keys.count { |k| k.include?("BSpace") }
    end

    # Value: protects=user input is never erased; fails_when=cleanup backspaces a box that
    # isn't exactly (a prefix of) our text; why_new=new; seam=none
    def test_user_keys_glued_to_ours_are_left_alone_and_reported
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.box += "zz" }
      assert_equal :failed_send, deliver(fake)
      assert_equal "/rename named-itzz", fake.box
      assert_equal [[:literal, "/rename named-it"]], fake.keys
    end

    # Value: protects=someone's own `/re…` typed during a visit isn't erased as if it were our
    # half-drawn line; fails_when=back_out backspaces a prefix; why_new=run-3 Codex; seam=none
    def test_a_prefix_at_back_out_is_left_alone
      fake = FakeClaude.new(box: "/rena")
      with_fake(fake) { assert_equal :failed_send, SessionName::Claude.back_out(4242, "start", "%1", "ttys001", "/rename named-it") }
      assert_equal "/rena", fake.box
      assert_empty fake.keys
    end

    # Value: protects=Enter never reaches whatever owns the terminal after Claude died or was
    # suspended during the last checks; fails_when=same?/foreground? aren't the LAST gate;
    # why_new=run-3 Codex P1 + Claude adversarial; seam=none
    def test_claude_gone_or_suspended_during_the_last_checks_gets_no_enter_and_no_backspaces
      gone = FakeClaude.new
      typed = false
      gone.on_type = ->(_) { typed = true }
      with_fake(gone) do
        stub_method(ProcessIdentity, :same?, ->(*) { !typed }) { assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it") }
      end
      assert_equal [[:literal, "/rename named-it"]], gone.keys
      stopped = FakeClaude.new
      after = 0
      stopped.on_type = ->(_) { after = 1 }
      with_fake(stopped) do
        stub_method(SessionName::Claude, :foreground?, lambda { |*|
          next true if after.zero?

          after += 1
          after <= 2 # the pre-Enter recipient check passes; the ^Z lands before the final one
        }) { assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it") }
      end
      assert_equal [[:literal, "/rename named-it"]], stopped.keys
    end

    # Value: protects=no keystroke reaches a permission prompt that opened (or a status that
    # left idle) during the pre-typing checks; fails_when=deliver types on the status/box it read
    # before the slower ps/tmux calls; why_new=run-3 Claude adversarial + Codex round B; seam=none
    def test_a_turn_starting_during_the_pre_typing_checks_types_nothing
      modal = "#{'─' * 20}\n  Do you want to proceed?\n#{'─' * 20}\n❯ 1. Yes\n"
      { "status" => ->(f) { f.status = "waiting" }, "modal" => ->(f) { f.screen_override = modal } }.each do |what, change|
        fake = FakeClaude.new
        reads = 0
        panes = lambda {
          reads += 1
          change.call(fake) if reads == 2 # the pass snapshot, then the pre-typing re-read
          { "ttys001" => { pane: "%1", visible: false, in_mode: false, synchronized: false, width: 120 } }
        }
        assert_equal :waiting, with_fake(fake, panes: panes) { SessionName::Claude.sync(ws, "named-it") }, what
        refute fake.typed?, "typed after the #{what} changed"
      end
    end

    # Value: protects=a Claude moved to another terminal (reptyr) can't route our keys into its
    # old pane, where its last frame still reads like ours; fails_when=foreground? checks the
    # terminal Claude owns NOW, not the pane's; why_new=run-3 Codex round C; seam=none
    def test_claude_moved_to_another_terminal_gets_no_keys_in_its_old_pane
      moved = FakeClaude.new
      moved.on_type = ->(f) { f.claude_tty = "ttys009" }
      assert_equal :failed_send, deliver(moved)
      assert_equal [[:literal, "/rename named-it"]], moved.keys, "no Enter, no backspace"
      early = FakeClaude.new
      reads = 0
      panes = lambda {
        reads += 1
        early.claude_tty = "ttys009" if reads == 2 # moved during the pre-typing checks
        { "ttys001" => { pane: "%1", visible: false, in_mode: false, synchronized: false, width: 120 } }
      }
      assert_equal :waiting, with_fake(early, panes: panes) { SessionName::Claude.sync(ws, "named-it") }
      refute early.typed?
    end

    # Value: protects=a permission dialog opening during the pre-typing box capture (tmux still
    # handing back the old empty frame) gets no keystrokes; fails_when=the status is read before
    # that capture; why_new=run-3 Codex round E; seam=none
    def test_a_modal_status_during_the_pre_typing_capture_types_nothing
      fake = FakeClaude.new
      orig = SessionName::Claude.method(:box_empty?)
      with_fake(fake) do
        stub_method(SessionName::Claude, :box_empty?, lambda { |pane|
          orig.call(pane).tap { fake.status = "waiting" }
        }) { assert_equal :waiting, SessionName::Claude.sync(ws, "named-it") }
      end
      refute fake.typed?
    end

    # Value: protects=a worker whose workspace was renamed again during its pre-typing checks
    # types nothing (a stale name would be backed out or left, stalling the newest sync);
    # fails_when=superseded? is checked only when the lock is taken; why_new=run-3 Claude round E
    def test_a_rename_landing_during_the_pre_typing_checks_types_nothing
      fake = FakeClaude.new
      calls = 0
      with_fake(fake) do
        stub_method(SessionName, :superseded?, ->(*) { (calls += 1) > 1 }) do # the lock passes, then the rename lands
          assert_equal :waiting, SessionName::Claude.sync(ws, "named-it")
        end
      end
      refute fake.typed?
    end

    # Value: protects=a ^Z during back_out's last capture can't hand the backspaces to a shell;
    # fails_when=identity/foreground aren't re-checked after that capture; why_new=run-3 Codex
    # round B; seam=none
    def test_claude_suspended_during_the_back_out_capture_gets_no_backspaces
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.status = "busy" }
      after = 0
      with_fake(fake) do
        stub_method(SessionName::Claude, :foreground?, lambda { |*|
          next true unless fake.typed?

          after += 1
          after <= 1 # the pre-Enter gate passes; the ^Z lands during back_out's box re-read
        }) { assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it") }
      end
      assert_equal [[:literal, "/rename named-it"]], fake.keys
    end

    # Value: protects=a permission dialog that opens while back_out re-reads the box (the old
    # frame still drawn) gets no backspaces; fails_when=back_out reads the status before the box,
    # unlike the Enter gate; why_new=run-3 round D (Claude + Codex); seam=none
    def test_a_modal_status_during_the_back_out_box_read_gets_no_backspaces
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.status = "busy" }
      reads = 0
      orig = SessionName::Claude.method(:box_reads?)
      with_fake(fake) do
        stub_method(SessionName::Claude, :box_reads?, lambda { |pane, text|
          reads += 1
          fake.status = "waiting" if reads == 2 # the pre-Enter read, then back_out's
          orig.call(pane, text)
        }) { assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it") }
      end
      assert_equal [[:literal, "/rename named-it"]], fake.keys
    end

    # Value: protects=backspaces never go to a permission modal drawn while our line still
    # shows; fails_when=back_out skips the status; why_new=run-3 Claude adversarial; seam=none
    def test_a_modal_status_at_back_out_gets_no_backspaces
      ["waiting", nil, "weird"].each do |status|
        fake = FakeClaude.new
        fake.on_type = ->(f) { f.status = status }
        assert_equal :failed_send, deliver(fake), "status=#{status.inspect}"
        assert_equal [[:literal, "/rename named-it"]], fake.keys
      end
    end

    def test_a_crash_between_typing_and_enter_still_backs_out
      fake = FakeClaude.new
      boom = ->(*) { raise "mid-send" }
      assert_raises(RuntimeError) do
        with_fake(fake) { stub_method(SessionName::Claude, :settled_box, boom) { SessionName::Claude.sync(ws, "named-it") } }
      end
      assert_equal "", fake.box
      refute_includes fake.keys.flatten, "Enter"
    end

    def test_a_second_worker_holding_the_session_lock_types_nothing
      fake = FakeClaude.new
      dir = File.join(SessionName::Outcome.dir, ".locks")
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "4242"), File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        stub_method(ProcessIdentity, :alive?, ->(_) { true }) { assert_equal :waiting, deliver(fake) }
      end
      refute fake.typed?
    end

    # Value: protects=a box that renders our text in stages still gets Enter, no backspaces;
    # fails_when=settled_box stops at the first capture and backs out a partial render;
    # why_new=every other fake renders at once; seam=none; no_claim=real render timing (fake pane)
    def test_a_box_that_renders_our_text_in_stages_still_gets_enter
      fake = FakeClaude.new
      lagging = 2
      fake.define_singleton_method(:screen) do
        next super() unless typed? && lagging.positive?

        lagging -= 1
        full = @box
        @box = full[0, 5]
        super().tap { @box = full }
      end
      assert_equal :done, deliver(fake)
      assert_equal [[:literal, "/rename named-it"], ["Enter"]], fake.keys
    end

    # Value: protects=an unreadable pane list after typing means no Enter AND no backspaces (the
    # recipient can't be verified); fails_when=either check reads nil as safe; why_new=run-2 Step 11;
    # seam=none; no_claim=real tmux list-panes failure (stubbed)
    def test_an_unreadable_pane_list_after_typing_sends_no_more_keys
      fake = FakeClaude.new
      reads = 0
      row = { pane: "%1", visible: false, in_mode: false, synchronized: false, width: 120 }
      panes = -> { (reads += 1) <= 2 ? { "ttys001" => row } : nil } # pass snapshot + pre-type read, then gone
      assert_equal :failed_send, with_fake(fake, panes: panes) { SessionName::Claude.sync(ws, "named-it") }
      assert_operator reads, :>=, 3, "the pre-Enter re-read must actually run"
      assert_equal [[:literal, "/rename named-it"]], fake.keys, "typed once, then nothing"
    end

    # Value: protects=an Enter Claude never confirms isn't reported done; fails_when=type_rename
    # returns :done after Enter without re-reading the session name; why_new=fakes always
    # honor /rename; seam=none; no_claim=real Claude session-file timing (stubbed reader)
    def test_an_enter_the_session_file_never_confirms_is_not_done
      fake = FakeClaude.new
      def fake.press(*keys)
        @keys << keys
        @box = "" if keys.include?("Enter") # the box clears but the name never changes
        true
      end
      assert_equal :unconfirmed, deliver(fake)
      assert_equal "old-xy", fake.name
      assert_includes fake.keys, ["Enter"]
    end

    def test_sync_reports_the_most_telling_pending_state
      done = { pid: 1, proc_start: "s", status: "idle", name: "named-it" }
      stub_method(ClaudeSessions, :sessions_in, ->(_) { [done, done.merge(pid: 2), done.merge(pid: 3)] }) do
        stub_method(Tmux, :panes_by_tty, -> { {} }) do
          states = { 1 => :waiting, 2 => :failed_send, 3 => :unrecognized }
          spent = {}
          stub_method(SessionName::Claude, :deliver, ->(s, *) { states[s[:pid]] }) do
            assert_equal :unrecognized, SessionName::Claude.sync(ws, "named-it", spent)
            assert_equal({ [2, "s"] => :failed_send }, spent)
            states[3] = :done
            states[1] = :skip
            assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it", spent), "nothing left to try"
          end
        end
      end
      stub_method(ClaudeSessions, :sessions_in, ->(_) { [] }) { assert_equal :none, SessionName::Claude.sync(ws, "x") }
      # Value: protects=our leftover /rename outranks another session's wait, so the ceiling tells
      # doctor failed_send (clear the prompt first); fails_when=:waiting is checked before :leftover;
      # why_new=single-session leftover tests can't see the ordering; seam=none; no_claim=none beyond protects
      stub_method(ClaudeSessions, :sessions_in, ->(_) { [done, done.merge(pid: 2)] }) do
        stub_method(Tmux, :panes_by_tty, -> { {} }) do
          stub_method(SessionName::Claude, :deliver, ->(s, *) { s[:pid] == 1 ? :waiting : :leftover }) do
            assert_equal :leftover, SessionName::Claude.sync(ws, "named-it")
          end
        end
      end
    end

    # Value: protects=keys never go to tmux (copy mode), a program in front of Claude, or a
    # box too narrow for one line; fails_when=any of the new gates is dropped; why_new=red-team
    # findings; seam=none; no_claim=real ps/tmux (stubbed)
    def test_copy_mode_a_suspended_claude_or_a_narrow_pane_types_nothing
      { in_mode: [true, nil], synchronized: [true, nil], foreground: [false], width: [10, nil] }.each do |attr, values|
        values.each do |v|
          fake = FakeClaude.new
          fake.public_send("#{attr}=", v)
          assert_equal :waiting, deliver(fake), "#{attr}=#{v.inspect}"
          refute fake.typed?, "typed with #{attr}=#{v.inspect}"
        end
      end
    end

    # Value: protects=no backspace reaches a shell (^Z), tmux (copy mode) or sibling panes
    # (synchronize) after the recipient changed mid-type; fails_when=back_out sends keys without
    # re-checking the recipient; why_new=run-2 Codex P1 (two passes); seam=none
    def test_a_recipient_changing_mid_type_gets_no_enter_and_no_backspaces
      [->(f) { f.in_mode = true }, ->(f) { f.foreground = false }, ->(f) { f.synchronized = true }].each do |change|
        fake = FakeClaude.new
        fake.on_type = change
        assert_equal :failed_send, deliver(fake)
        assert_equal [[:literal, "/rename named-it"]], fake.keys, "the text is left; no key follows it"
      end
    end

    # Value: protects=Enter never lands on a permission prompt that opened during the slower
    # pre-Enter checks; fails_when=the box/status are read before the ps/tmux calls, not after;
    # why_new=run-2 Codex P1 + native; seam=none; no_claim=real Claude modal timing (fake)
    def test_a_modal_opening_during_the_pre_enter_checks_gets_no_enter
      fake = FakeClaude.new
      armed = false
      fake.on_type = ->(_) { armed = true }
      modal = "#{'─' * 20}\n  Do you want to proceed?\n#{'─' * 20}\n❯ 1. Yes\n"
      with_fake(fake) do
        stub_method(SessionName::Claude, :foreground?, lambda { |*|
          if armed # the turn starts while we ask ps: the modal replaces the box
            fake.screen_override = modal
            fake.status = "waiting"
          end
          true
        }) { SessionName::Claude.sync(ws, "named-it") }
      end
      refute_includes fake.keys.flatten, "Enter"
    end

    # Value: protects=the box re-read right before Enter catches a modal on its own, while Claude's
    # file still says idle (its status write lags the screen); fails_when=box_reads? is dropped or
    # moved before the slower checks; why_new=run-3 testing review (mutant survived); seam=none
    def test_a_modal_the_status_hasnt_caught_up_with_gets_no_enter_and_no_backspaces
      fake = FakeClaude.new
      armed = false
      fake.on_type = ->(_) { armed = true }
      with_fake(fake) do
        stub_method(SessionName::Claude, :foreground?, lambda { |*|
          fake.screen_override = "#{'─' * 20}\n  Do you want to proceed?\n#{'─' * 20}\n❯ 1. Yes\n" if armed
          true
        }) { assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it") }
      end
      assert_equal "idle", fake.status
      assert_equal [[:literal, "/rename named-it"]], fake.keys
    end

    # Value: protects=a recycled %id can't receive our Enter; fails_when=the pre-Enter check
    # matches the pane by id only; why_new=red-team finding; seam=none; no_claim=real tmux id reuse
    def test_a_pane_id_handed_to_another_pane_mid_type_gets_no_enter
      fake = FakeClaude.new
      reads = 0
      panes = lambda {
        reads += 1
        { "ttys001" => { pane: reads == 1 ? "%1" : "%9", visible: false, in_mode: false, synchronized: false, width: 120 } }
      }
      assert_equal :waiting, with_fake(fake, panes: panes) { SessionName::Claude.sync(ws, "named-it") }
      refute_includes fake.keys.flatten, "Enter"
    end

    def test_a_session_renamed_since_the_scan_or_a_newer_rename_types_nothing
      fake = FakeClaude.new
      fake.name = "named-it" # the file says so now; the scan saw the old name
      stale = fake.session.merge(name: "old-xy")
      with_fake(fake) do
        stub_method(ClaudeSessions, :sessions_in, ->(_) { [stale] }) { assert_equal :done, SessionName::Claude.sync(ws, "named-it") }
      end
      refute fake.typed?
      other = FakeClaude.new
      dest = ws("named-it")
      stub_method(SessionName, :superseded?, ->(*) { true }) do
        assert_equal :waiting, with_fake(other) { SessionName::Claude.sync(dest, "named-it") }
      end
      refute other.typed?
    end

    def test_an_unreadable_box_after_typing_never_presses_enter
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.screen_override = "a modal\n" }
      assert_equal :failed_send, deliver(fake)
      assert_equal [[:literal, "/rename named-it"]], fake.keys, "no Enter, no backspace"
    end

    # Value: protects=a transient lsof/ps/lock-dir failure waits instead of quitting silently;
    # fails_when=nil answers read as "no session" (:done/:skip); why_new=red-team; seam=none
    def test_couldnt_tell_answers_wait_instead_of_giving_up
      fake = FakeClaude.new
      with_fake(fake) do
        stub_method(ClaudeSessions, :sessions_in, ->(_) {}) { assert_equal :waiting, SessionName::Claude.sync(ws, "named-it") }
        stub_method(SessionName::Claude, :tty_of, ->(_) {}) { assert_equal :waiting, SessionName::Claude.sync(ws, "named-it") }
        stub_method(SessionName::Claude, :locked, ->(_) { raise Errno::EACCES }) do
          assert_equal :waiting, SessionName::Claude.sync(ws, "named-it")
        end
      end
      refute fake.typed?
    end

    def test_box_in_vim_mode_is_unrecognized
      rule = "─" * 20
      assert_equal :unrecognized, SessionName::Box.parse("#{rule}\n❯ \n#{rule}\n  -- NORMAL --\n")
      assert_equal :unrecognized, SessionName::Box.parse("#{rule}\n❯ \n#{rule}\n  -- INSERT -- ⏵⏵ auto mode\n")
      assert_equal :empty, SessionName::Box.parse("#{rule}\n❯ \n#{rule}\n  ⏵⏵ auto mode on\n")
    end

    # Value: protects=a slow redraw (box still empty after typing) is waited out, not read
    # as lost keys; fails_when=settle stops on the first empty capture; why_new=pass-2 red team
    # (pass-1 made empty-after-typing a failed_send); seam=none; no_claim=real render timing
    def test_a_box_still_empty_right_after_typing_is_waited_out
      fake = FakeClaude.new
      lag = 3
      fake.define_singleton_method(:screen) do
        next super() unless typed? && lag.positive?

        lag -= 1
        full = @box
        @box = ""
        super().tap { @box = full }
      end
      assert_equal :done, deliver(fake)
      assert_equal [[:literal, "/rename named-it"], ["Enter"]], fake.keys
    end

    # Value: protects=a back-out only counts as clean when the box is seen empty again;
    # fails_when=back_out returns :waiting after BSpace without re-reading; why_new=pass-2
    # security + state-machine finding; seam=none
    def test_backspaces_that_dont_clear_the_box_spend_the_session
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.status = "busy" }
      def fake.press(*keys)
        @keys << keys
        true # the backspaces never land
      end
      assert_equal :failed_send, deliver(fake)
      refute_includes fake.keys.flatten, "Enter"
    end

    def test_a_rename_landing_while_we_type_gets_no_enter
      fake = FakeClaude.new
      moved = false
      fake.on_type = ->(_) { moved = true }
      stub_method(SessionName, :superseded?, ->(*) { moved }) do
        assert_equal :waiting, deliver(fake)
      end
      assert_equal "", fake.box
      refute_includes fake.keys.flatten, "Enter"
    end

    # Value: protects=Claude applying /rename after our ~3 s confirm window still ends as done;
    # fails_when=a spent :unconfirmed is never re-checked; why_new=pass-2 state machine; seam=none
    def test_an_unconfirmed_session_that_catches_up_later_is_done
      fake = FakeClaude.new
      spent = { [4242, "start"] => :unconfirmed }
      fake.name = "named-it"
      stale_scan = fake.session
      with_fake(fake) do
        stub_method(ClaudeSessions, :sessions_in, ->(_) { [stale_scan] }) do
          assert_equal :done, SessionName::Claude.sync(ws, "named-it", spent)
        end
      end
      assert_empty spent
    end

    # Value: protects=the foreground gate reads real ps output; fails_when=foreground?/tty_of
    # parsing breaks and every pid reads as foreground; why_new=every unit test stubs them;
    # seam=none; no_claim=tmux panes (a bare PTY stands in)
    def test_foreground_and_tty_read_real_process_groups
      require "pty"
      PTY.spawn("sleep", "5") do |_r, _w, pid|
        tty = Tmux.normalize_tty(SessionName::Claude.tty_of(pid))
        refute_nil tty
        assert SessionName::Claude.foreground?(pid, tty), "a pty's own process owns its terminal"
        refute SessionName::Claude.foreground?(pid, "ttys999"), "another terminal's pane isn't its"
        refute SessionName::Claude.foreground?(pid, nil)
        Process.kill("STOP", pid) # stopped alone: its group stays in front, but nothing reads
        assert(5.times.any? { sleep 0.05 unless _1.zero?; !SessionName::Claude.foreground?(pid, tty) }, "a stopped process isn't foreground")
      ensure
        Process.kill("CONT", pid) # a stopped child holds TERM pending; never hang the suite
        Process.kill("TERM", pid)
        Process.wait(pid)
      end
      # Its own session, so no controlling terminal even when the suite runs in one.
      r, w = IO.pipe
      bg = fork do
        r.close
        Process.setsid
        w.close
        $stdin.reopen(File::NULL)
        begin
          exec("sleep", "5")
        rescue StandardError
          exit!(127) # never fall back into the test runner's at_exit
        end
      end
      w.close
      r.read # setsid has happened before ps looks
      refute SessionName::Claude.foreground?(bg, "ttys001"), "no terminal, not foreground"
      assert_nil Tmux.normalize_tty(SessionName::Claude.tty_of(bg))
    ensure
      if bg
        Process.kill("TERM", bg)
        Process.wait(bg)
      end
    end

    def test_dead_pids_lock_files_are_swept_and_live_ones_kept
      dir = File.join(SessionName::Outcome.dir, ".locks")
      FileUtils.mkdir_p(dir)
      dead = (2**22 + 12_345).to_s
      FileUtils.touch(File.join(dir, dead))
      FileUtils.touch(File.join(dir, Process.pid.to_s))
      assert_equal :ran, SessionName::Claude.locked(Process.pid) { :ran }
      refute File.exist?(File.join(dir, dead))
      assert File.exist?(File.join(dir, Process.pid.to_s))
    end

    def test_owner_claims_keep_the_newest_and_sweep_dead_workers
      dest = ws
      old = SessionName::Owner.claim(dest)
      newer = SessionName::Owner.claim(dest)
      refute SessionName::Owner.mine?(dest, old)
      assert SessionName::Owner.mine?(dest, newer)
      ghost = File.join(SessionName::Owner.dir, "deadbeef")
      File.write(ghost, "#{2**22 + 12_345}-1")
      SessionName::Owner.claim(ws("other"))
      refute File.exist?(ghost), "a dead worker's claim is swept by the next claim"
      assert SessionName::Owner.mine?(dest, newer), "a live worker's claim survives the sweep"
    end

    # --- work: the loop ---

    # A clock that advances by whatever the worker sleeps.
    def run_worker(dest, name, &each_poll)
      now = 0.0
      slept = []
      result = SessionName.work(dest, name, clock: -> { now },
                                            sleeper: lambda { |s|
                                              slept << s
                                              now += s
                                              each_poll&.call(now)
                                            })
      [result, slept]
    end

    def test_work_stops_once_the_session_is_named_and_clears_old_outcomes
      dest = ws
      SessionName::Outcome.record(dest, :ceiling, "named-it")
      fake = FakeClaude.new(status: "busy")
      result, slept = with_fake(fake) { run_worker(dest, "named-it") { |t| fake.status = "idle" if t >= 6 } }
      assert_equal :done, result
      assert_equal [2, 2, 2], slept
      assert_equal "named-it", fake.name
      assert_empty SessionName::Outcome.all
    end

    def test_work_backs_off_then_gives_up_at_the_ceiling_and_tells_doctor
      dest = ws
      result, slept = with_fake(FakeClaude.new(status: "busy")) { run_worker(dest, "named-it") }
      assert_equal :ceiling, result
      assert_equal [2] * 15 + [4, 8, 16], slept.first(18)
      assert_equal [30], slept.drop(18).uniq
      assert_equal [{ path: File.realpath(dest), kind: "ceiling", name: "named-it" }], SessionName::Outcome.all
    end

    def test_work_reports_an_unreadable_box_at_the_ceiling
      dest = ws
      fake = FakeClaude.new
      fake.screen_override = "?"
      with_fake(fake) { run_worker(dest, "named-it") }
      assert_equal ["unrecognized"], SessionName::Outcome.all.map { |o| o[:kind] }
    end

    # Value: protects=a failed capture types nothing and an untty'd agent isn't retried forever;
    # fails_when=a nil capture falls through to the parser or an empty tty reads as waiting;
    # why_new=capture and tty always succeed in the fake; seam=none; no_claim=real ps/tmux failures (stubbed)
    def test_a_failed_capture_waits_and_an_agent_without_a_tty_is_skipped
      fake = FakeClaude.new
      with_fake(fake) do
        stub_method(Tmux, :capture_pane, ->(_) {}) { assert_equal :waiting, SessionName::Claude.sync(ws, "named-it") }
        stub_method(SessionName::Claude, :tty_of, ->(_) { "??\n" }) { assert_equal :done, SessionName::Claude.sync(ws, "named-it") }
      end
      refute fake.typed?
    end

    # Value: protects=at most one Enter, and never a retype onto text we couldn't remove;
    # fails_when=the worker keeps polling a spent session (types again into leftovers or
    # re-presses Enter every poll); why_new=the one-attempt rule is new; seam=none; no_claim=real Claude
    def test_a_spent_session_is_never_typed_into_again_and_doctor_is_told
      { glued: ->(f) { f.on_type = ->(g) { g.box += "zz" } },
        swallowed: ->(f) { f.swallow = true },
        unconfirmed: lambda { |f|
          def f.press(*keys)
            @keys << keys
            @box = "" if keys.include?("Enter")
            true
          end
        } }.each do |label, setup|
        dest = ws("named-it")
        fake = FakeClaude.new
        setup.call(fake)
        result, = with_fake(fake) { run_worker(dest, "named-it") }
        kind = label == :unconfirmed ? "unconfirmed" : "failed_send"
        assert_equal kind.to_sym, result, label.to_s
        assert_equal 1, fake.keys.count { |k| k.first == :literal }, "typed once (#{label})"
        assert_equal [kind], SessionName::Outcome.all.map { |o| o[:kind] }
        SessionName::Outcome.clear(dest)
      end
    end

    # Value: protects=a spent session stays spent while another session keeps the worker
    # polling; fails_when=sync re-delivers to a session in `spent`; why_new=single-session tests
    # return before a second pass; seam=none
    def test_sync_never_redelivers_to_a_spent_session
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.box += "zz" }
      spent = {}
      with_fake(fake) do
        assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it", spent)
        fake.box = "" # even if the box clears, that session is done for this worker
        assert_equal :failed_send, SessionName::Claude.sync(ws, "named-it", spent)
      end
      assert_equal 1, fake.keys.count { |k| k.first == :literal }
    end

    # Value: protects=a clean back-out may retry; fails_when=the one-attempt rule also spends a
    # session we restored; why_new=new rule; seam=none; no_claim=real Claude
    def test_a_clean_back_out_tries_again_later
      fake = FakeClaude.new
      fake.on_type = lambda { |f|
        f.status = "busy"
        f.on_type = nil
      }
      result, = with_fake(fake) { run_worker(ws, "named-it") { fake.status = "idle" } }
      assert_equal :done, result
      assert_equal 2, fake.keys.count { |k| k.first == :literal }
      assert_equal "named-it", fake.name
    end

    # Value: protects=latest rename wins with no record; fails_when=an old worker keeps
    # typing its stale name after a newer rename; why_new=D4; seam=none
    def test_work_exits_when_a_newer_rename_moved_the_workspace
      dest = ws("first")
      fake = FakeClaude.new(status: "busy")
      result, = with_fake(fake) do
        run_worker(dest, "first") do
          FileUtils.mv(dest, "#{dest}-2")
          File.symlink("#{dest}-2", dest)
        end
      end
      assert_equal :superseded, result
      refute fake.typed?
      assert SessionName.superseded?(path("nope"), "nope")
      assert SessionName.superseded?(ws("x"), "y")
      refute SessionName.superseded?(ws("x"), "x")
    end

    def test_work_with_no_live_session_is_done_at_once
      fake = FakeClaude.new
      fake.present = false
      assert_equal [:gone, [2]], with_fake(fake) { run_worker(ws, "named-it") }, "one empty scan could be a torn read"
    end

    def test_work_succeeding_on_the_ceiling_poll_is_done_and_superseded_records_nothing
      dest = ws
      SessionName::Outcome.record(dest, :unrecognized, "named-it")
      times = [0, SessionName::CEILING + 1]
      result = with_fake(FakeClaude.new) { SessionName.work(dest, "named-it", clock: -> { times.shift || 9e9 }, sleeper: ->(_) {}) }
      assert_equal :done, result
      assert_empty SessionName::Outcome.all, "a success clears even an unrecognized marker"

      first = ws("first")
      fake = FakeClaude.new(status: "busy")
      result, = with_fake(fake) do
        run_worker(first, "first") do |t|
          next unless t >= SessionName::CEILING - 30

          FileUtils.mv(first, "#{first}-2")
          File.symlink("#{first}-2", first)
        end
      end
      assert_equal :superseded, result
      assert_empty SessionName::Outcome.all
    end

    # Value: protects=a retried rename replaces the running worker; fails_when=Owner claim is
    # ignored and workers stack; why_new=red-team; seam=none
    def test_a_newer_worker_for_the_same_workspace_retires_the_older
      dest = ws
      fake = FakeClaude.new(status: "busy")
      result, = with_fake(fake) { run_worker(dest, "named-it") { SessionName::Owner.claim(dest) } }
      assert_equal :superseded, result
      refute fake.typed?
    end

    def test_work_refuses_a_name_rename_would_never_hand_it
      fake = FakeClaude.new
      ["bad\nname", "-x", ".hidden", "a b", ""].each do |name|
        assert_equal :invalid, with_fake(fake) { SessionName.work(ws("x"), name) }
      end
      refute fake.typed?
    end

    # Value: protects=a retry you run behaves per D2 — never types onto leftover text, may press
    # once more after an unconfirmed Enter; fails_when=a fresh worker ignores the leftover box or
    # the retry can't try at all; why_new=pass-2 state machine; seam=none
    def test_a_retry_worker_skips_leftover_text_but_retries_an_unconfirmed_enter
      dest = ws("named-it")
      glued = FakeClaude.new
      glued.on_type = ->(f) { f.box += "zz" }
      with_fake(glued) { run_worker(dest, "named-it") }
      glued.on_type = nil
      result, = with_fake(glued) { run_worker(dest, "named-it") }
      assert_equal :ceiling, result, "the leftover keeps a retry waiting"
      assert_equal 1, glued.keys.count { |k| k.first == :literal }
      assert_equal ["failed_send"], SessionName::Outcome.all.map { |o| o[:kind] }, "and doctor keeps saying why"
      SessionName::Outcome.clear(dest)

      deaf = FakeClaude.new
      def deaf.press(*keys)
        @keys << keys
        @box = "" if keys.include?("Enter")
        true
      end
      2.times { with_fake(deaf) { run_worker(dest, "named-it") } }
      assert_equal 2, deaf.keys.count { |k| k.include?("Enter") }, "one Enter per worker"
    end

    def test_superseded_mid_pass_leaves_the_new_workspaces_outcome_alone
      first = ws("first")
      fake = FakeClaude.new
      fake.define_singleton_method(:press) do |*keys|
        super(*keys).tap do
          next unless keys.include?("Enter") # the rename lands right after our Enter succeeds

          FileUtils.mv(first, "#{first}-2")
          File.symlink("#{first}-2", first)
        end
      end
      SessionName::Outcome.record("#{first}-2", :ceiling, "first-2")
      result, = with_fake(fake) { run_worker(first, "first") }
      assert_equal :superseded, result
      assert_equal ["ceiling"], SessionName::Outcome.all.map { |o| o[:kind] }, "the bridge didn't let us clear it"
    end

    # Value: protects=doctor's marker is the newest worker's evidence; fails_when=a stale verdict
    # survives a later attempt, or an hour of leftover /rename text reads as "never idle";
    # why_new=pass-3 rework (ranking replaced by evidence); seam=none; no_claim=real Claude
    def test_the_newest_verdict_wins_and_leftover_text_at_the_ceiling_is_a_failed_send
      d = ws
      SessionName::Outcome.record(d, :failed_send, "n")
      SessionName::Outcome.record(d, :unconfirmed, "n")
      assert_equal ["unconfirmed"], SessionName::Outcome.all.map { |o| o[:kind] }, "a later attempt's verdict replaces it"
      SessionName::Outcome.clear(d)

      leftover = FakeClaude.new(box: "/rename some-old-name") # another worker's text, still there
      result, = with_fake(leftover) { run_worker(d, "named-it") }
      assert_equal :ceiling, result
      refute leftover.typed?, "never types onto it"
      assert_equal ["failed_send"], SessionName::Outcome.all.map { |o| o[:kind] }
      draft = FakeClaude.new(box: "a user draft")
      SessionName::Outcome.clear(d)
      with_fake(draft) { run_worker(d, "named-it") }
      assert_equal ["ceiling"], SessionName::Outcome.all.map { |o| o[:kind] }, "a user's draft is just no safe moment"
    end

    def test_a_late_confirmation_within_the_window_is_done
      fake = FakeClaude.new
      polls = 0
      def fake.press(*keys)
        @keys << keys
        @box = "" if keys.include?("Enter") # Claude applies it a few seconds later
        true
      end
      reader = lambda { |_|
        polls += 1
        { status: fake.status, name: polls > 20 ? "named-it" : fake.name }
      }
      with_fake(fake) do
        stub_method(SessionName::Claude, :current, reader) { assert_equal :done, SessionName::Claude.sync(ws, "named-it") }
      end
    end

    def test_a_missing_claim_never_retires_its_worker
      dest = ws
      token = SessionName::Owner.claim(dest)
      File.delete(SessionName::Owner.file(dest))
      assert SessionName::Owner.mine?(dest, token), "another workspace's sweep can race it away"
    end

    # --- one worker's verdict (ship-2 state-machine matrix) ---

    def two_session_worker(dest, states)
      a = { pid: 1, proc_start: "s", status: "idle", name: "old" }
      stub_method(ClaudeSessions, :sessions_in, ->(_) { [a, a.merge(pid: 2)] }) do
        stub_method(Tmux, :panes_by_tty, -> { {} }) do
          stub_method(SessionName::Claude, :deliver, ->(sess, *) { states[sess[:pid]] }) { run_worker(dest, "named-it").first }
        end
      end
    end

    # Value: protects=doctor keeps "text may be left in the prompt" while another session is
    # still pending or also spent; fails_when=the marker is last-written or the ceiling overwrites
    # it; why_new=ship-2 state machine; seam=none
    def test_leftover_text_stays_the_verdict_past_the_ceiling_and_over_unconfirmed
      d = ws
      assert_equal :failed_send, two_session_worker(d, { 1 => :failed_send, 2 => :waiting })
      assert_equal ["failed_send"], SessionName::Outcome.all.map { |o| o[:kind] }
      SessionName::Outcome.clear(d)
      assert_equal :failed_send, two_session_worker(d, { 1 => :failed_send, 2 => :unconfirmed })
      assert_equal ["failed_send"], SessionName::Outcome.all.map { |o| o[:kind] }
    end

    def test_nobody_left_clears_the_verdict_and_never_reads_as_a_ceiling
      d = ws
      SessionName::Outcome.record(d, :failed_send, "named-it")
      gone = FakeClaude.new
      gone.present = false
      assert_equal :gone, with_fake(gone) { run_worker(d, "named-it") }.first
      assert_empty SessionName::Outcome.all, "a retry with Claude closed clears the stale advice"

      times = [0, SessionName::CEILING + 1]
      assert_equal :gone, with_fake(gone) { SessionName.work(d, "named-it", clock: -> { times.shift || 9e9 }, sleeper: ->(_) {}) }
      assert_empty SessionName::Outcome.all, "one empty scan at the very end is not 'never a safe moment'"
    end

    def test_empty_scans_must_be_consecutive_to_end_the_worker
      fake = FakeClaude.new(status: "busy")
      seq = [false, true, false]
      result, = with_fake(fake) do
        run_worker(ws, "named-it") do
          if seq.empty?
            fake.present = true
            fake.status = "idle"
          else
            fake.present = seq.shift
          end
        end
      end
      assert_equal :done, result, "two empty scans with a session between them are not 'nobody here'"
    end

    def test_a_worker_retired_mid_pass_writes_no_verdict
      dest = ws
      fake = FakeClaude.new
      def fake.press(*keys)
        @keys << keys
        @box = "" if keys.include?("Enter")
        true
      end
      fake.on_type = ->(_) { SessionName::Owner.claim(dest) }
      assert_equal :superseded, with_fake(fake) { run_worker(dest, "named-it") }.first
      assert_empty SessionName::Outcome.all
    end

    # Value: protects=a render still partial after the full settle is left (it reads like a
    # user's prefix), never half-erased; fails_when=back_out backspaces a prefix; why_new=ship-2
    # red team, reversed by run-3 Codex; seam=none; no_claim=real render timing
    def test_a_render_still_partial_at_back_out_is_left_alone
      fake = FakeClaude.new
      fake.on_type = ->(f) { f.status = "busy" }
      fake.define_singleton_method(:screen) do
        next super() unless typed? && !@box.empty?

        full = @box
        @box = full[0, 5] # only "/rena" is drawn
        super().tap { @box = full }
      end
      assert_equal :failed_send, deliver(fake)
      assert_equal [[:literal, "/rename named-it"]], fake.keys
    end

    def test_a_flaky_capture_is_waited_out_and_a_failed_send_types_nothing_back
      fake = FakeClaude.new
      flaky = 2
      real_capture = ->(_) { fake.screen }
      with_fake(fake) do
        stub_method(Tmux, :capture_pane, ->(p) { fake.typed? && (flaky -= 1) >= 0 ? nil : real_capture.call(p) }) do
          assert_equal :done, SessionName::Claude.sync(ws, "named-it")
        end
      end
      dead = FakeClaude.new
      with_fake(dead) do
        stub_method(Tmux, :send_literal, ->(*) { false }) { assert_equal :waiting, SessionName::Claude.sync(ws, "named-it") }
      end
      assert_empty dead.keys, "send-keys failed: no backspaces into a box we never typed in"
    end

    def test_the_line_must_fit_the_box_with_its_chrome
      edge = "/rename named-it".length + SessionName::Claude::BOX_CHROME
      fake = FakeClaude.new
      fake.width = edge
      assert_equal :done, deliver(fake)
      fake = FakeClaude.new
      fake.width = edge - 1
      assert_equal :waiting, deliver(fake)
      refute fake.typed?
    end

    def test_box_skips_osc_hyperlinks
      rule = "─" * 20
      link = "\e]8;;https://example.com\e\\"
      assert_equal :empty, SessionName::Box.parse("#{link}#{rule}\n❯ \n#{rule}\n  footer #{link}docs\e]8;;\a\n")
    end

    # --- run 2, pass 2 cells ---

    def test_unconfirmed_with_a_session_still_pending_is_the_verdict_at_the_ceiling
      d = ws
      assert_equal :unconfirmed, two_session_worker(d, { 1 => :unconfirmed, 2 => :waiting })
      assert_equal ["unconfirmed"], SessionName::Outcome.all.map { |o| o[:kind] }
    end

    # Value: protects=a lone session Claude confirms late ends as done, not a stale doctor line;
    # fails_when=the worker returns at the first unconfirmed; why_new=raised three passes running; seam=none
    def test_a_lone_session_confirming_after_the_window_still_ends_done
      d = ws("named-it")
      fake = FakeClaude.new
      def fake.press(*keys)
        @keys << keys
        @box = "" if keys.include?("Enter")
        true
      end
      result, = with_fake(fake) { run_worker(d, "named-it") { |t| fake.name = "named-it" if t >= 6 } }
      assert_equal :done, result
      assert_equal 1, fake.keys.count { |k| k.include?("Enter") }, "watched, never re-typed"
      assert_empty SessionName::Outcome.all
    end

    def test_a_spent_session_that_exited_no_longer_drives_the_verdict
      d = ws
      a = { pid: 1, proc_start: "s", status: "idle", name: "old" }
      sessions = [a, a.merge(pid: 2)]
      stub_method(ClaudeSessions, :sessions_in, ->(_) { sessions }) do
        stub_method(Tmux, :panes_by_tty, -> { {} }) do
          stub_method(SessionName::Claude, :deliver, ->(sess, *) { sess[:pid] == 1 ? :failed_send : :waiting }) do
            run_worker(d, "named-it") { sessions = [a.merge(pid: 2)] }
          end
        end
      end
      assert_equal ["ceiling"], SessionName::Outcome.all.map { |o| o[:kind] }
    end

    # Value: protects=a worker booting after a second rename leaves the newest worker's claim;
    # fails_when=it claims through the bridge first; why_new=run-2 state machine; seam=none
    def test_a_worker_booting_after_its_dest_became_a_bridge_leaves_the_new_claim_alone
      first = ws("first")
      FileUtils.mv(first, "#{first}-2")
      File.symlink("#{first}-2", first)
      newer = SessionName::Owner.claim("#{first}-2")
      assert_equal :superseded, with_fake(FakeClaude.new) { SessionName.work(first, "first") }
      assert SessionName::Owner.mine?("#{first}-2", newer)
    end

    # Value: protects=a rename landing between the superseded check and the claim can't make the
    # old worker claim the NEW workspace; fails_when=the claim keys off realpath without checking
    # its name; why_new=run-2 Codex adversarial; seam=none
    def test_a_rename_racing_the_claim_never_claims_the_new_workspace
      first = ws("first")
      FileUtils.mv(first, "#{first}-2")
      File.symlink("#{first}-2", first)
      newer = SessionName::Owner.claim("#{first}-2")
      result = stub_method(SessionName, :superseded?, ->(*) { false }) do # the check ran just before the move
        with_fake(FakeClaude.new) { SessionName.work(first, "first") }
      end
      assert_equal :superseded, result
      assert SessionName::Owner.mine?("#{first}-2", newer)
    end

    def test_a_crash_in_a_pass_leaves_doctor_a_verdict
      d = ws
      result = stub_method(SessionName::Claude, :sync, ->(*) { raise "boom" }) do
        SessionName.work(d, "named-it", clock: -> { 0 }, sleeper: ->(_) {})
      end
      assert_equal :error, result
      assert_equal ["error"], SessionName::Outcome.all.map { |o| o[:kind] }
    end

    def test_superseded_by_a_newer_claim_near_the_ceiling_records_nothing
      d = ws
      fake = FakeClaude.new(status: "busy")
      result, = with_fake(fake) { run_worker(d, "named-it") { |t| SessionName::Owner.claim(d) if t >= SessionName::CEILING - 30 } }
      assert_equal :superseded, result
      assert_empty SessionName::Outcome.all
    end

    def test_an_unreadable_box_records_nothing_until_the_ceiling
      d = ws
      fake = FakeClaude.new
      fake.screen_override = "?"
      seen = []
      with_fake(fake) { run_worker(d, "named-it") { |t| seen << SessionName::Outcome.all.size if t < SessionName::CEILING } }
      assert_equal [0], seen.uniq
      refute fake.typed?
    end

    def test_the_statuses_we_type_on_are_ones_doctor_knows
      assert_empty SessionName::DELIVERABLE - RemoteLink::STATUSES
    end

    # --- Outcome: doctor's markers ---

    def test_outcomes_are_listed_per_workspace_and_gc_with_it
      a = ws("a")
      b = ws("b")
      SessionName::Outcome.record(a, :failed_send, "a")
      SessionName::Outcome.record(b, :ceiling, "b")
      SessionName::Outcome.record(b, :unrecognized, "b")
      assert_equal [%w[a failed_send], %w[b unrecognized]], SessionName::Outcome.all.map { |o| [o[:name], o[:kind]] }
      FileUtils.rm_rf(b)
      SessionName::Outcome.clear(a)
      assert_empty SessionName::Outcome.all
    end
  end
end
