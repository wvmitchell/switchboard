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

# Optional: one-key jump to the home/anchor session. Not bound by default —
# prefix-h is a common pane-nav key. Uncomment on a key that's free for you
# (prefix-S is freed by switchboard):
#   tmux bind-key S run-shell "'$BIN' home"
