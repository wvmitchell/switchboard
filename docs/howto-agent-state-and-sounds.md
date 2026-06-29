# How to set up agent-state dots and completion sounds

Get the exact thinking/waiting/done dots, and tune the sounds that play when an
agent finishes or asks for input. For *why* it works this way, see
[Explanation: agent presence](explanation-agent-presence.md).

## Prerequisites

- switchboard installed and a worktree to work in. See the
  [tutorial](tutorial-getting-started.md).
- For exact dots: Claude Code or Codex. Other agents (Aider) get a coarser
  observed dot with zero setup.
- For sounds: an audio player on PATH — `afplay` (macOS, built in) or
  `paplay`/`aplay`/`ffplay` (Linux).

## Understand the two levels of dot

You get *something* for free and *something better* by opting in:

- **Observation (default, zero-config).** Switchboard watches the agent's tmux
  pane and infers busy-vs-idle. Works for any agent, installs nothing. It can't
  tell "waiting" from "done".
- **Hooks (exact).** Claude Code and Codex report their state precisely, so you
  get the magenta "waiting on you" dot and accurate done/thinking. Delivery splits
  by agent: **Claude** is scoped per worktree (`.claude/settings.local.json`,
  never your global `~/.claude`); **Codex** is one global block in
  `~/.codex/config.toml`, because codex can't discover project-local hooks in a
  linked worktree (and switchboard worktrees are all linked). For Codex the magenta
  "waiting" dot rides its permission gates, so it shows whenever the agent blocks on
  you for approval; a session command that bypasses *all* approvals won't surface it.

## Enable exact hooks

**Claude (per worktree).** Worktrees switchboard *creates* get the Claude hook
automatically (when `agent_state_hooks` is on, the default). For a worktree you
made elsewhere, run this once from inside it, then restart `claude` so it picks it
up:

```sh
switchboard enable-hooks
```

To undo for that worktree: `switchboard disable-hooks`.

**Codex (once, globally).** Codex hooks live in one block in your global
`~/.codex/config.toml`, so they're installed once — with your consent — not per
worktree. `switchboard install` offers it (or run it up front):

```sh
switchboard install --codex-hooks     # or just answer the install prompt
```

Codex won't run the hooks until you **trust** them: run `/hooks` in codex once and
approve the switchboard hooks (or start codex with `--dangerously-bypass-hook-trust`).
After that the dots flow for every worktree. `switchboard uninstall` removes the
block (the per-worktree `disable-hooks` leaves it — it's global).

**Verify:** `switchboard doctor` shows the Claude hook status for the worktree
you're standing in *and* the global codex block status (plus the `/hooks` trust
note), and prints the reporter script path. Start an agent and watch the dot
become precise.

### Turn off auto-wiring on new worktrees

If you don't want switchboard touching `.claude/settings.local.json` on create,
set in `config.yml`:

```yaml
agent_state_hooks: false
```

## Set completion sounds

Sounds are on by default: a two-blast train horn when an agent is **done**, a soft
two-note chime when it's **waiting**. Configure globally:

```yaml
sounds:
  enabled: true     # false mutes everything
  done: train
  waiting: chime
```

Each `done`/`waiting` value is one of:

- A **built-in** (synthesized, no files): `train`, `chime`, or the variations
  `train_1`/`train_2`/`train_3` and `chime_1`/`chime_2`/`chime_3`.
- A **file path**: `~/sounds/horn.wav` (anything with `/` or `~`).
- A **macOS system sound** name: `Glass`, `Ping`, etc. (a bare name).

```yaml
sounds:
  done: train_2                 # a different horn timbre
  waiting: ~/sounds/ping.wav    # your own file
```

## Audition a sound

```sh
switchboard sound          # plays the `done` sound
switchboard sound waiting  # plays the `waiting` sound
```

If nothing plays, it tells you why (muted / no player on PATH / unresolvable
spec) — so silence is never a mystery.

## Override sounds per project

Same shape as the global `sounds`, nested under a project. A per-state key that's
absent inherits the global one; only `enabled: false` mutes.

```yaml
sounds:
  done: train
  waiting: chime
projects:
  - name: myapp
    sounds:
      enabled: false                  # this repo stays quiet
  - name: client-work
    sounds:
      done: ~/sounds/celebrate.wav    # custom done; waiting inherits the global chime
```

A distinct horn per repo is the point — you learn to tell which project finished
without looking.

## Sounds and hooks are linked

Sounds ride the **same hooks** as the exact dots. So a worktree needs hooks
enabled to make sound — for Claude that's automatic on switchboard-created
worktrees or `switchboard enable-hooks` in an existing one; for Codex it's the
one-time global install above. Observation-only agents show a dot but stay silent
(the coarse signal is too noisy to ring on).

## Troubleshooting

- **No sound at all.** Check `switchboard doctor` for "audio player" — with none
  on PATH, sounds stay silent by design. Install one (`afplay` ships with macOS).
- **Dot never goes magenta (waiting).** That state only comes from hooks. For
  Claude, run `switchboard enable-hooks` in the worktree and restart it; for Codex,
  install the global block (`switchboard install --codex-hooks`) and `/hooks`-trust
  it. (Codex's waiting also needs a permission gate to fire — a bypass-all session
  command suppresses it.)
- **Sounds fire twice.** Usually an orphaned sidebar process — `switchboard
  doctor` flags it. See [Explanation: sidebar lifecycle](explanation-sidebar-lifecycle.md).
- **A stale dot after `quit`.** `quit` clears agent state, so this shouldn't
  happen; if a dot lingers, it ages out within the presence TTL (15 min) or when
  the agent re-reports on restart.
- **`doctor` says "no system sound named X".** That's a macOS system-sound name
  that doesn't exist (or you're not on macOS). Use a built-in or a file path.

## Related

- [Explanation: agent presence](explanation-agent-presence.md) — the two-signal merge and the edge consumers.
- [Reference: config](reference-config.md#sounds) — the full `sounds` field reference.
- [Reference: CLI](reference-cli.md) — `enable-hooks`, `disable-hooks`, `sound`.
