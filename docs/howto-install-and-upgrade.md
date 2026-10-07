# How to install, upgrade, or move to Homebrew

Install switchboard with Homebrew or from a git clone, keep it up to date, move a
clone install over to Homebrew, or remove it cleanly.

## Prerequisites

- macOS or Linux with **tmux ≥ 3.0**, **git**, and **gh**. Homebrew installs all
  three (plus Ruby) for you; for a clone install on macOS, `brew install tmux git gh`.
- For a clone install, **Ruby ≥ 3.0** (`ruby -v`). No gems.

## Install with Homebrew

1. Install the formula from the tap:

   ```sh
   brew install wvmitchell/switchboard/switchboard
   ```

   This puts `switchboard` and the short alias `sb` on your PATH.

2. Wire it into tmux and write a starter config:

   ```sh
   switchboard install
   ```

   Under Homebrew, `install` reports `on PATH via Homebrew` and skips the
   `~/.local/bin` symlinks.

## Install from a git clone

```sh
git clone https://github.com/wvmitchell/switchboard
cd switchboard && bin/switchboard install
```

`install` symlinks `switchboard` and `sb` into `~/.local/bin`. If it warns that
`~/.local/bin` isn't on your PATH, add the line it prints to your shell profile.

## Upgrade

**Homebrew:**

```sh
brew upgrade switchboard
switchboard install        # or: tmux source-file ~/.tmux.conf
```

**Clone:**

```sh
git -C <your clone> pull --ff-only
switchboard install        # or: tmux source-file ~/.tmux.conf
```

Either way the new code runs immediately, but a running tmux server keeps the key
bindings and hooks it loaded at startup. Re-running `install` (idempotent) or
reloading tmux picks up any new ones. Under Homebrew every path switchboard wrote
into your config points at `$(brew --prefix)/opt/switchboard`, which brew moves to
the new version, so nothing goes stale when the old version is cleaned up. See
[Explanation: distribution](explanation-distribution.md).

## Move from a git clone to Homebrew

1. From the clone, remove its wiring (PATH symlinks, the tmux.conf line, live key
   bindings and hooks, and the global codex block if you installed it):

   ```sh
   <your clone>/bin/switchboard uninstall
   ```

   Your config and agent state are left alone.

2. Install with Homebrew and wire it up. Run `switchboard install` from inside
   tmux (step 1 unbound the old keys in the running server, and install only
   reloads tmux when it runs inside it), or reload tmux afterwards with
   `tmux source-file ~/.tmux.conf`:

   ```sh
   brew install wvmitchell/switchboard/switchboard
   switchboard install
   ```

   Add `--codex-hooks` if you used the codex agent dots before. If the shell says
   `switchboard: No such file or directory`, it remembered the clone's deleted
   link: run `hash -r` (bash) or `rehash` (zsh), or open a new shell.

3. Point each existing worktree's Claude hooks at the new install. Hooks are
   written per worktree with the install path baked in, so re-enable them in
   every worktree that had them:

   ```sh
   switchboard enable-hooks <worktree path>
   ```

   For every worktree of a repo that already had switchboard's hooks:

   ```sh
   git -C <repo> worktree list --porcelain | sed -n 's/^worktree //p' |
     while read -r wt; do
       grep -qs switchboard "$wt/.claude/settings.local.json" && switchboard enable-hooks "$wt"
     done
   ```

   `enable-hooks` replaces switchboard's own entries and leaves yours alone.

4. Restart the sidebars so they run the Homebrew copy. A running sidebar keeps the
   path of the binary that started it, and would keep spawning the clone's
   sidebars (and wiring new worktrees to it). In each switchboard session, press
   your sidebar toggle key (`prefix-s` unless you remapped it) twice: once to
   dismiss its sidebars, once to bring them back from the new install. (If a
   session's sidebar was hidden, the first press brings back a new one, so press
   it once more if you want it hidden again.) Then restart `claude` in each workspace (or run `/hooks`) so it
   picks up the hooks from step 3.

   To restart everything at once instead, `switchboard quit` closes every
   switchboard session. **This kills every agent, editor and shell running in
   them**, so finish or save your work first; `switchboard` brings you back.

## Uninstall

Run `switchboard uninstall` **first**, while the command still exists:

```sh
switchboard uninstall                     # tmux wiring, live bindings, codex block
brew uninstall switchboard                # Homebrew installs
brew untap wvmitchell/switchboard         # optional
```

If you already ran `brew uninstall`, tmux will complain about a missing
`switchboard.tmux` on every reload. Delete the block between
`# >>> switchboard install >>>` and `# <<< switchboard install <<<` in your
tmux.conf by hand, then reload tmux. Worktrees whose Claude hooks you enabled keep
switchboard entries in `.claude/settings.local.json`; they no-op once the command
is gone, or run `switchboard disable-hooks <worktree>` first to remove them.

For a clone install, `switchboard uninstall` also removes the `~/.local/bin`
symlinks; delete the clone afterwards if you like. Your config
(`~/.config/switchboard/config.yml`) is kept either way.

## Verification

```sh
switchboard version
switchboard doctor
```

`doctor` should show:

- `✓ on PATH via Homebrew: …` (Homebrew) or `✓ PATH symlink: ~/.local/bin/switchboard` (clone);
- `✓ tmux bindings wired (switchboard.tmux)`;
- `✓ tmux hooks live`, when you run it inside tmux.

## Troubleshooting

- **`– tmux is wired to another install (…)`.** Your tmux.conf still sources a
  different copy, usually the clone you moved from. Run `switchboard install`
  from the install you want to keep.
- **`✗ tmux is wired to a missing install (…)`.** The install tmux.conf points at
  is gone (a deleted clone). Run `switchboard install`.
- **`✗ … on PATH is …/.local/bin/switchboard, which shadows Homebrew's`.** A
  clone-era symlink comes first on your PATH (doctor checks `sb` the same way).
  Delete just the links it names (usually
  `rm ~/.local/bin/switchboard ~/.local/bin/sb`). Don't run the clone's
  `uninstall` now: it would also remove the tmux and codex wiring the Homebrew
  install is using (if you already did, run `switchboard install` again).
- **`✗ … which shadows Homebrew's — take <dir> off your PATH`.** A clone's own
  `bin/` directory is on your PATH ahead of Homebrew's. Remove it from your shell
  profile. Don't delete the file: it's the clone's launcher.
- **`✗ switchboard on PATH is …, another program`.** Something else named
  `switchboard` comes first. Put `$(brew --prefix)/bin` earlier on your PATH.
- **`✗ Homebrew install, but switchboard isn't on PATH`.** Run
  `brew link switchboard`. If brew reports a conflict on `sb`, another program
  owns that name; `brew link --overwrite switchboard` takes it over.
- **Workspaces stopped getting auto-named, or the ∞ monitoring dot doesn't clear,
  after the move.** Step 3 wasn't run for that worktree, so its hooks still call
  the old install (or nothing, if the clone is gone). The status dots keep working
  either way. Run `switchboard enable-hooks` there.
- **Codex dots stopped after the move.** The codex hook commands changed path, so
  codex wants them approved again. Run `/hooks` in codex once.
- **`prefix-s` does nothing after an upgrade.** tmux still has the old bindings.
  Run `switchboard install` or `tmux source-file ~/.tmux.conf`; `doctor` confirms
  with `prefix-s bound (toggle-sidebar)`.

## Related

- [Tutorial: getting started](tutorial-getting-started.md)
- [CLI reference](reference-cli.md): `install`, `uninstall`, `enable-hooks`, `doctor`
- [Explanation: distribution](explanation-distribution.md)
- [How-to: housekeeping & diagnostics](howto-housekeeping.md)
