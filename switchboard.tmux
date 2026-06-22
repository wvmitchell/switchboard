#!/usr/bin/env sh
# switchboard.tmux — self-locating tmux bindings for switchboard. Your tmux.conf
# runs this via `run-shell` (the `switchboard install` marker block adds that
# one line); it re-runs on every config reload, so it's written to apply safely
# and repeatedly. Switchboard owns these bindings — `switchboard uninstall`
# removes the marker line and clears the hook slot below.
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin/switchboard"

# prefix-s shows/hides the sidebar — switchboard's one navigator. The single
# quotes survive into the /bin/sh tmux hands the command to, so a clone path
# with spaces still resolves.
tmux bind-key s run-shell "'$BIN' toggle-sidebar"

# Refresh the sidebar tree on every session switch. Indexed slot [99] overwrites
# itself on each reload (no stacking) and coexists with any other
# client-session-changed hook; uninstall clears exactly this slot.
tmux set-hook -g 'client-session-changed[99]' "run-shell \"'$BIN' poke-sidebar\""

# Sidebar visibility is per-session: a new window (prefix-c) in a session that's
# showing the sidebar gets its own. tmux expands #{window_id} here and hands the
# new window's id to sidebar-sync, which spawns one iff the session opts in.
# (split-window — how the sidebar is spawned — fires after-split-window, not this
# hook, so there's no spawn loop.) Indexed slot [99]; uninstall clears it.
tmux set-hook -g 'after-new-window[99]' "run-shell \"'$BIN' sidebar-sync #{window_id}\""

# Optional: one-key jump to the home/anchor session. Not bound by default —
# prefix-h is a common pane-nav key. Uncomment on a key that's free for you
# (prefix-S is freed by switchboard):
#   tmux bind-key S run-shell "'$BIN' home"
