#!/usr/bin/env sh
# switchboard.tmux — self-locating tmux bindings for switchboard. Your tmux.conf
# runs this via `run-shell` (the `switchboard install` marker block adds that
# one line); it re-runs on every config reload, so it's written to apply safely
# and repeatedly. Switchboard owns these bindings — `switchboard uninstall`
# removes the marker line and clears the hook slots below.
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin/switchboard"

# Bind switchboard's keys from config (`tmux_keys:` — toggle, default prefix-s;
# optional home). tmux-bind reads config.yml, binds the configured keys, and cleans
# up the ones IT bound last (tracked in @switchboard-*-key options), so remapping a
# key in config takes effect on the next reload without leaving the old key bound.
# It does all the tmux calls itself (same nested-run-shell pattern the hooks use).
"$BIN" tmux-bind

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

# Poke the sidebar on a same-session window switch. Moving BETWEEN windows of one
# session is not a client-session-changed, so the newly-active window's sidebar —
# which sleeps on a long idle backstop while off screen — would otherwise lag before
# it refreshes. tmux hands the now-active window's id; poke-window gates to sb/
# sessions, so this global hook is a cheap no-op on unrelated windows. Indexed slot
# [99]; uninstall clears it.
tmux set-hook -g 'session-window-changed[99]' "run-shell \"'$BIN' poke-window #{window_id}\""

# One-key jump to the home/anchor session is configurable too: set `tmux_keys:
#   home: S` in config.yml and tmux-bind (above) binds it. Unset by default.
