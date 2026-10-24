# How to install, upgrade, or move to Homebrew

Install switchboard with Homebrew or from a git clone, keep it up to date, move a
clone install over to Homebrew, or remove it cleanly.

## Prerequisites

- macOS or Linux with **tmux ≥ 3.0**, **git**, and **gh**. Homebrew installs all
  three (plus Ruby) for you; for a clone install on macOS, `brew install tmux git gh`.
- For a clone install, **Ruby ≥ 3.0** (`ruby -v`). No gems.

## Install with Homebrew

1. Add the tap once, trust it, then install by the short name:

   ```sh
   brew tap wvmitchell/switchboard
   brew trust wvmitchell/switchboard
   brew install switchboard
   ```

   Recent Homebrew refuses to load formulas from a third-party tap until you trust
   it. If yours says `Unknown command: trust`, it's older and doesn't need the step.

   This puts `switchboard` and the short alias `sb` on your PATH. With the tap
   added, `brew upgrade switchboard` and `brew uninstall switchboard` work by the
   short name too.

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

```sh
switchboard upgrade
```

`upgrade` fetches the new version the way you installed it:

- **Homebrew:** `brew update`, then `brew upgrade switchboard`. A `--HEAD` install
  runs `brew upgrade --fetch-HEAD switchboard` and follows `main`.
- **Clone:** `git fetch`, then a fast-forward-only merge of the upstream of the
  branch your clone tracks (`git merge --no-overwrite-ignore --ff-only @{upstream}`).
  It refuses if tracked files have uncommitted changes. Untracked and ignored files
  are fine, unless the update would overwrite one: then git refuses and names the file.

Then the new version finishes the setup:

- reloads switchboard's tmux bindings and hooks in the running server, even from a
  shell outside tmux (only if your tmux.conf sources this install);
- updates the agent hooks in every worktree of your configured projects that already
  has them, including primary checkouts. A running Claude picks the change up on its own;
- refreshes the global codex hooks if you installed them. If their commands changed it
  tells you to run `/hooks` in codex once.

Running sidebars keep the old code until they restart: press your sidebar toggle key
(`prefix-s` unless you remapped it) twice in each switchboard session.

If you're already on the newest release, `upgrade` says so and stops. If an earlier
upgrade was interrupted before it finished, running `upgrade` again finishes it. The
version that first ships `upgrade` (0.52.0) still has to be installed the old way:
`brew upgrade switchboard` (or `git pull`), then `switchboard install`.

`switchboard install` does the same worktree-hook update, so it still works as a
manual repair. Under Homebrew every path switchboard wrote into your config points at
`$(brew --prefix)/opt/switchboard`, which brew moves to the new version, so nothing
goes stale when the old version is cleaned up. See
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
   brew tap wvmitchell/switchboard
   brew trust wvmitchell/switchboard
   brew install switchboard
   switchboard install
   ```

   Add `--codex-hooks` if you used the codex agent dots before. If the shell says
   `switchboard: No such file or directory`, it remembered the clone's deleted
   link: run `hash -r` (bash) or `rehash` (zsh), or open a new shell.

3. Check that each existing worktree's Claude hooks point at the new install.
   Hooks are written per worktree with the install path baked in. Step 2's
   `install` already repointed every worktree of the projects in your config that
   had them (it prints `worktree hooks: updated N`). For a repo you hooked that
   isn't in your config, run:

   ```sh
   switchboard enable-hooks <worktree path>
   ```

   `enable-hooks` replaces switchboard's own entries and leaves yours alone.

4. Restart the sidebars so they run the Homebrew copy. A running sidebar keeps the
   path of the binary that started it, and would keep spawning the clone's
   sidebars (and wiring new worktrees to it). In each switchboard session, press
   your sidebar toggle key (`prefix-s` unless you remapped it) twice: once to
   dismiss its sidebars, once to bring them back from the new install. (If a
   session's sidebar was hidden, the first press brings back a new one, so press
   it once more if you want it hidden again.) A running `claude` picks up the
   hooks from step 3 on its own.

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

- **`Refusing to load formula … from untrusted tap wvmitchell/switchboard`.**
  Homebrew wants the tap trusted first: run `brew trust wvmitchell/switchboard`,
  then `brew install switchboard` again.
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
  after the move.** That worktree's hooks still call the old install (or nothing, if
  the clone is gone): it isn't in a project in your config, or `install` reported it
  as not updated. The status dots keep working either way. Run `switchboard
  enable-hooks <worktree path>` there.
- **Codex dots stopped after the move.** The codex hook commands changed path, so
  codex wants them approved again. Run `/hooks` in codex once. (`doctor`'s
  `N/M trusted` can't help here: the old approvals are still on file, so it counts
  them even though codex no longer accepts them.)
- **`install` ends with `Done, except the codex hooks (✗ above)` and exits 1.**
  Everything else was installed; the codex block in `~/.codex/config.toml` was left
  as it was. Do what the ✗ line says (merge your own `[hooks]` into one place, move
  or restore the lines it names, or just re-run if codex wrote the file mid-install),
  then run `switchboard install` again.
- **`uninstall` says `Stopped before removing anything else` and exits 1.** It
  removes the codex block first and stopped there, so nothing (not even the PATH
  command) was removed. Fix what the ✗ line names, then re-run
  `switchboard uninstall`. Don't delete the block by hand: codex may have written
  some of its own settings inside it.
- **`prefix-s` does nothing after an upgrade.** tmux still has the old bindings.
  Run `switchboard upgrade` (it finishes a setup an earlier upgrade left undone) or
  `tmux source-file ~/.tmux.conf`; `doctor` confirms with `prefix-s bound (toggle-sidebar)`.
- **`– claude hooks here are out of date`.** This worktree's hooks were written by an
  older release. Run `switchboard upgrade`, or `switchboard enable-hooks` in it. If the
  worktree isn't in a configured project, `upgrade` skips it (doctor says so): run
  `switchboard enable-hooks` there.
- **`upgrade` says a version is tagged but Homebrew doesn't have it yet.** The release
  is published before the Homebrew formula is updated. Try again in a few minutes.
- **`upgrade` says `` `brew update` failed `` and exits 1.** `brew update` failed and
  nothing was upgraded, so Homebrew may not know about the newest switchboard. Read
  brew's output above the message. An untrusted tap is a common cause
  (`brew trust wvmitchell/switchboard`). Then re-run `switchboard upgrade`. (If
  `brew update` fails but the upgrade still lands, it's only a note.)
- **`upgrade` stops at `git merge` in a clone.** The update would overwrite an
  untracked or ignored file in your clone, and git names it. Move that file aside,
  then re-run `switchboard upgrade`.
- **`worktree hooks: not refreshed — … isn't the switchboard on your PATH`.** You ran
  a different copy of switchboard (a clone's `bin/switchboard`, say). It leaves the hooks
  alone so they don't end up pointing at that copy. Run `switchboard upgrade` instead.

## Related

- [Tutorial: getting started](tutorial-getting-started.md)
- [CLI reference](reference-cli.md): `install`, `uninstall`, `enable-hooks`, `doctor`
- [Explanation: distribution](explanation-distribution.md)
- [How-to: housekeeping & diagnostics](howto-housekeeping.md)
