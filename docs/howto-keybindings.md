# How to customize keybindings

Change which tmux prefix key shows the sidebar, and bind an optional one-key jump
to the home session. For the full key surface, see
[Reference: keybindings](reference-keybindings.md).

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

## Related

- [Reference: keybindings](reference-keybindings.md) — the full key tables.
- [Reference: config](reference-config.md#tmux_keys) — the `tmux_keys` schema and key tokens.
- [Reference: CLI](reference-cli.md) — `install`, `config`, `doctor`.
