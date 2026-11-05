# frozen_string_literal: true

require_relative "test_helper"

module Switchboard
  class EditorTest < SandboxTest
    SPLIT = ["split-window", "-b", "-t", "%1", "-c", "/home/x", "-p", "80", "-P", "-F", "\#{pane_id}", "vi x"].freeze

    # Value: protects=`e` splitting only the work pane, and remembering that pane; fails_when=the split
    # argv drifts, the stash is dropped, or a Tmux call breaks and the rescue swallows it (no notice,
    # no stash); why_new=callers stub edit_in_home and smoke can't drive it (switch execs); seam=none;
    # no_claim=a real tmux split
    def test_e_splits_the_work_pane_and_remembers_the_new_pane
      events = press
      assert_includes events, [:query, *SPLIT]
      assert_includes events, [:run, "set-option", "-t", Tmux::HOME, Editor::EDITOR_PANE_OPT, "%9"]
      assert_includes events, [:pin, "%0"]
      assert_equal [:switch, Tmux::HOME], events.last
      refute(events.any? { |e| e.first == :notify })
    end

    # Value: protects=a second `e` refocusing the open editor instead of stacking a split; fails_when=the
    # reuse branch stops selecting that pane or splits anyway; why_new=smoke covers only the stash read;
    # seam=none; no_claim=a real tmux focus change
    def test_e_refocuses_an_editor_that_is_still_open
      events = press(stashed: "%5\n", panes: "%0 0\n%5 0\n")
      assert_includes events, [:run, "select-pane", "-t", "%5"]
      refute(events.any? { |e| e[0, 2] == [:query, "split-window"] })
      assert_equal [:switch, Tmux::HOME], events.last
    end

    # Value: protects=`e` never being a dead key or splitting the tree; fails_when=a missing work pane or a
    # failed split goes unreported, stashes a pane, or doesn't land home; why_new=no test reached these
    # branches; seam=none; no_claim=the notice reaching a real status line
    def test_e_says_so_and_lands_home_when_it_cannot_split
      [{ work: nil }, { split: nil }].each do |failure|
        events = press(**failure)
        assert_includes events, [:notify, "switchboard: couldn't open the editor pane"], failure.inspect
        refute(events.any? { |e| e[0, 2] == [:run, "set-option"] }, failure.inspect)
        assert_equal [:switch, Tmux::HOME], events.last, failure.inspect
      end
    end

    # Value: protects=a raise never crashing the `e` keypress; fails_when=the rescue is removed or stops
    # landing home; why_new=no test reached the rescue; seam=none; no_claim=which errors tmux really raises
    def test_e_lands_home_when_something_raises
      events = press(pin: ->(_pane) { raise IOError, "gone" })
      assert_equal [:switch, Tmux::HOME], events.last
    end

    # Value: protects=the first `e`, with nothing stashed, still opening an editor; fails_when=a failed read
    # raises, which the rescue would turn into a silent no-editor; why_new=both smoke tests stash first;
    # seam=none; no_claim=how a given tmux version reports an unset option
    def test_a_failed_read_means_no_pane_to_reuse
      assert_nil stub_method(Tmux, :query, ->(*) { nil }) { Editor.live_editor_pane }
    end

    private

    # One `e` press with tmux faked, returning what it asked tmux to do, in order.
    def press(stashed: "", panes: "%0 0\n%1 0\n", work: "%1", split: "%9\n", pin: nil)
      events = []
      fakes = {
        ensure_home: -> {},
        window_sidebar_pane: ->(_target) { "%0" },
        work_pane: ->(_target, _sidebar) { work },
        home_dir: -> { "/home/x" },
        pin: pin || ->(pane) { events << [:pin, pane] },
        switch: ->(name) { events << [:switch, name] },
        notify: ->(message) { events << [:notify, message] },
        run: ->(*args) { events << [:run, *args]; true },
        query: lambda do |*args|
          events << [:query, *args]
          { "show-options" => stashed, "list-panes" => panes, "split-window" => split }.fetch(args.first)
        end
      }
      with_stubs(fakes.to_a) { Editor.edit_in_home("vi x") }
      events
    end

    def with_stubs(fakes, &block)
      return block.call if fakes.empty?

      (name, fake), *rest = fakes
      stub_method(Tmux, name, fake) { with_stubs(rest, &block) }
    end
  end
end
