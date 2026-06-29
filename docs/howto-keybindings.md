# How to customize keybindings

Change which tmux prefix key shows the sidebar, bind an optional one-key jump to
the home session, and remap the keys *inside* the sidebar. For the full key
surface, see [Reference: keybindings](reference-keybindings.md).

## Prerequisites

- switchboard installed (the `switchboard.tmux` fragment wired into your
  tmux.conf). See the [tutorial](tutorial-getting-started.md).

## What's bound by default

- `prefix-s` → show/hide the sidebar (the one summon/dismiss verb).
- The home key is **unbound** — opt in if you want it.

`prefix-s` collides with tmux's built-in `choose-tree`, which is the usual reason
to remap it. (Your tmux *prefix* is whatever you've configured, default `C-b`.)

## Change the sidebar toggle key

Edit your config (`switchboard config`, or `e` in the sidebar) and set
`tmux_keys.toggle`:

```yaml
tmux_keys:
  toggle: b     # now prefix-b shows/hides the sidebar
```

A key token is a single char (`b`), a named key (`Space`, `F1`, `BSpace`), or a
modifier combo (`C-s`, `M-x`).

**It takes effect on save.** When you edit config from inside tmux (via `e` or
`switchboard config`), switchboard rebinds the key immediately and flashes a
confirmation. It also cleans up the key it bound *last*, so the old key never
stays live.

**Verify:** press your prefix then the new key — the sidebar toggles. Or run
`switchboard doctor`, which reports `prefix-<key> bound (toggle-sidebar)`.

## Bind a one-key jump to home

Home (`sb/home`) is your anchor session. Bind a key to jump there from anywhere:

```yaml
tmux_keys:
  toggle: s
  home: S     # prefix-S jumps to home (S is freed by switchboard)
```

Leave the `home` line out entirely to keep it unbound.

## Change the in-sidebar keys

The keys you press *inside* the sidebar (move, create, rename, …) are remapped
under `sidebar_keys`, by **action name** rather than raw key — so the config says
intent, not bytes:

```yaml
sidebar_keys:
  new_workspace: c    # press c (not n) to create a workspace
  delete: x           # press x (not d) to remove a row
  down: j             # (the default — listed here only as an example)
```

The action names are in
[Reference: keybindings](reference-keybindings.md#sidebar-keys) (the **Action**
column). Omit an action to keep its default.

**Each value is a single printable character.** That rule reserves the structural
keys for free: `↵` (the context action), `Esc`, `Backspace`, the arrows, the
resize `←`/`→`, and the `Ctrl-N`/`Ctrl-P`/`Ctrl-O` aliases are all non-printable, so
a remap can never shadow them. The movement *letters* `j`/`k` are remappable; the
arrow and `Ctrl-N`/`Ctrl-P` aliases beside them always move regardless.

**It takes effect on save** — editing config from inside the sidebar (`e`) re-reads
`sidebar_keys` immediately, and the `?` overlay then shows your actual keys. (A
config edited by hand *outside* switchboard is picked up on the next reload.)

**Verify:** open the `?` overlay — the remapped key shows in place of the default.
Or run `switchboard doctor`, which confirms `sidebar_keys: N remapped, no clashes`.

## The one exception: a fresh install needs a tmux reload

Editing `tmux_keys` from a running switchboard rebinds live. But two cases need
tmux to re-source its config:

1. The very first `install` (the fragment isn't loaded into the running server
   yet).
2. Editing `config.yml` by hand *outside* switchboard, then expecting it live.

In both, reload tmux:

```sh
tmux source-file ~/.tmux.conf    # or wherever your conf lives
```

`switchboard doctor` flags a binding that's wired in config but not yet **live**
in the running server — the "prefix-s stopped working after a `git pull`" case.

## Troubleshooting

- **Key didn't change.** Run `switchboard doctor`. If it says the binding isn't
  live, reload tmux (above).
- **`doctor` says the value "isn't a usable key".** It fell back to the default.
  Tokens can't contain whitespace, quotes, or control chars. Fix the value.
- **`doctor` warns about a collision.** Your `home` key resolved to the same key
  as `toggle`; `home` is left unbound (the toggle wins). Pick a different home key.
- **`doctor` says a binding "replaced a prior binding".** Your chosen key was
  already bound to something else (yours or a plugin's); switchboard took it and
  recorded what it displaced. Choose another key if you want the old one back.
- **A malformed config.** switchboard falls back to default keys and keeps
  running; `doctor` reports the parse error and the file to fix.
- **A sidebar key didn't change.** Run `switchboard doctor`. If it says the value
  "isn't a single printable key", you used more than one character (or a named
  key) — `sidebar_keys` takes exactly one printable char. If it says the key
  "clashes with" another action, two actions resolved to the same key; the loser
  is left unbound (its arrow/ctrl aliases still work). Pick a free key.

## Related

- [Reference: keybindings](reference-keybindings.md) — the full key tables (and the `sidebar_keys` action names).
- [Reference: config](reference-config.md#tmux_keys) — the [`tmux_keys`](reference-config.md#tmux_keys) and [`sidebar_keys`](reference-config.md#sidebar_keys) schemas.
- [Reference: CLI](reference-cli.md) — `install`, `config`, `doctor`.
