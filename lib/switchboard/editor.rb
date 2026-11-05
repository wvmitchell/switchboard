# frozen_string_literal: true

module Switchboard
  # Resolves which editor to launch — shared by the CLI `config`/`edit` command
  # and the sidebar's `e` action so the choice can't drift between the two — and
  # runs the sidebar's `e` in its own pane in the home session.
  module Editor
    module_function

    # $VISUAL/$EDITOR, treating an exported-but-empty value as unset — an empty
    # string is truthy in Ruby, so a bare `||` chain would pick it and try to
    # exec the config file itself. Falls back to vi. Resolved in THIS process —
    # right for the CLI `config` command, which runs the editor in the shell you
    # typed it from.
    def command
      [ENV["VISUAL"], ENV["EDITOR"]].find { |e| e && !e.empty? } || "vi"
    end

    # The same precedence + empty-is-unset rule, but as a shell expression the
    # SPAWNED shell evaluates rather than this process. The sidebar's `e` runs the
    # editor in a freshly-split tmux pane; resolving there picks up an EDITOR set
    # after this long-lived sidebar process started (e.g. `tmux setenv -g`), which
    # a value baked from #command at process start would miss. `:-` is shell for
    # "unset or empty", matching #command's guard.
    SHELL_COMMAND = "${VISUAL:-${EDITOR:-vi}}"

    # Remembers `e`'s editor pane on the home session, so a second `e` before the
    # first was :q'd re-focuses that pane instead of stacking another split (the
    # editor panes would otherwise pile up, one per press). tmux never recycles a
    # %pane-id within a server's lifetime, so a stashed id present in home is the
    # same editor pane; once it's :q'd (pane closed) the id is retired and the
    # stash goes stale — live_editor_pane then reports nil and `e` spawns fresh.
    EDITOR_PANE_OPT = "@sb_editor_pane"

    # Open an editor command in its OWN throwaway pane in the home session, beside
    # the sidebar, then land on it. The pane runs `command` as its foreground
    # process (tmux execs it via the shell) and closes on exit (:q) — so editing
    # config never types into a live shell (no idle guard, no pending-input
    # corruption, no shell-history leak). `command` carries its own
    # return-to-origin + reload trailer, so this stays a dumb "run it in a home
    # pane" primitive. Array-form spawn so `command` reaches tmux as one literal
    # arg (its `;`, spaces, and any `$EDITOR` are the inner shell's to parse, not
    # ours).
    #
    # We split the WORK pane explicitly, never the active pane: after go_home the
    # sidebar is the active pane, so the old `-t "#{HOME}:"` (active-pane target)
    # nested the editor *inside* the tree, and a stray zoom toggle made it flip
    # between full-screen and split. Splitting the work pane gives a deterministic
    # layout — sidebar at left, editor stacked above the home shell on the right
    # (`-b` = above, so it aligns with the tree's top; the shell keeps the bottom
    # 20%). `-p 80` (a percentage of the work pane) not `-l 80%`: the bare-`%`
    # form on `-l` needs tmux >= 3.1, but we support 3.0 (see installer), where it
    # would silently fail the split and leave `e` a dead key.
    def edit_in_home(command)
      Tmux.ensure_home
      sidebar = Tmux.window_sidebar_pane(Tmux::HOME)

      # `e` is idempotent: if the last editor pane is still open (you came back to
      # the tree without :q-ing it), re-focus it rather than stack another split —
      # otherwise every press piled on a new editor pane in home (they accumulated,
      # and closing one still left the rest). Its own return-to-origin trailer is
      # already running in that pane, so we only land you back on it — :q then
      # returns to wherever the FIRST `e` was pressed, not this one (reuse keeps the
      # original edit's origin; moot for the common repeat-`e`-from-home case).
      if (existing = live_editor_pane)
        Tmux.pin(sidebar)
        Tmux.run("select-pane", "-t", existing)
        return Tmux.switch(Tmux::HOME)
      end

      # Only ever split the work pane. NO active-pane fallback: when home has no
      # work pane the active pane is the sidebar, and splitting it is exactly the
      # nest-in-the-tree bug this method exists to avoid.
      target = Tmux.work_pane(Tmux::HOME, sidebar)
      pane = target && Tmux.query(
        "split-window", "-b", "-t", target, "-c", Tmux.home_dir, "-p", "80", "-P", "-F", "#\{pane_id}", command
      ).to_s.strip
      if pane.nil? || pane.empty? # no work pane, or the split failed
        Tmux.notify("switchboard: couldn't open the editor pane") # not a silent dead key
        return Tmux.switch(Tmux::HOME)                                  # at least land in home
      end

      stash_editor_pane(pane) # remember it so the next `e` reuses this pane
      Tmux.pin(sidebar) # the split reflows the right column; keep the sidebar fixed-width
      Tmux.switch(Tmux::HOME) # land on the new (active) editor pane, beside the tree
    rescue StandardError
      Tmux.switch(Tmux::HOME) # never crash the `e` keypress
    end

    # Remember `e`'s editor pane on the home session (EDITOR_PANE_OPT), so the next
    # `e` can reuse it. A session option shares the session's lifetime, so a server
    # restart clears it along with the pane it names — no cross-restart staleness.
    def stash_editor_pane(pane)
      Tmux.run("set-option", "-t", Tmux::HOME, EDITOR_PANE_OPT, pane)
    end

    # The stashed editor pane iff it's still a LIVE pane in home's active window
    # (where the editor and sidebar live). nil once the editor was :q'd or on a
    # stale/foreign id — the signal to spawn a fresh editor. Two deliberate scopes:
    # (1) dead panes are filtered out (#{pane_dead}) — under a user's `remain-on-exit
    # on`, a :q'd editor lingers as a dead pane list-panes still reports, which would
    # otherwise trap `e` re-focusing the corpse instead of opening a new editor;
    # (2) active window only — home is single-window by design, so a manually-added
    # home window holding the editor just degrades to a fresh spawn (never worse than
    # pre-fix), never a wrong-pane focus.
    def live_editor_pane
      want = Tmux.query("show-options", "-v", "-t", Tmux::HOME, EDITOR_PANE_OPT).to_s.strip
      raw  = Tmux.query("list-panes", "-t", Tmux::HOME, "-F", "#\{pane_id} #\{pane_dead}").to_s
      live = raw.lines.filter_map { |l| id, dead = l.split; id if dead != "1" }
      reusable_editor_pane(want, live)
    end

    # Pure: the pane to reuse — the stashed id, but only when it's still among
    # home's live pane ids (an empty stash or a retired id yields nil). Split out
    # so the reuse gate is unit-testable without a server.
    def reusable_editor_pane(want, pane_ids)
      return if want.to_s.empty?

      want if pane_ids.include?(want)
    end
  end
end
