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
  get the magenta "waiting on you" dot and accurate done/thinking. Scoped per
  worktree (`.claude/settings.local.json` for Claude, `.codex/hooks.json` for
  Codex) — it never touches your global `~/.claude` or `~/.codex`. For Codex the
  magenta "waiting" dot rides its permission gates, so it shows whenever the agent
  blocks on you for approval; a session command that bypasses *all* approvals
  won't surface it.

## Enable exact hooks in a worktree

Worktrees switchboard *creates* get hooks automatically (when
`agent_state_hooks` is on, the default). For a worktree you made elsewhere, run
this once from inside it:

```sh
switchboard enable-hooks
```

Then restart `claude` (or `codex`) in that worktree so it picks them up. Codex
loads project-local hooks only once the project layer is **trusted** — run
`/hooks` in codex if the dot stays coarse. (`enable-hooks` wires both adapters;
each is dormant until that agent runs there, so a Claude-only worktree just
carries an unused `.codex/hooks.json`.) To undo:

```sh
switchboard disable-hooks
```

**Verify:** `switchboard doctor` reports `hooks enabled here` for the worktree
you're standing in, breaks the status out per adapter (claude / codex), and
prints the reporter script path. Start an agent and watch the dot become precise.

### Turn off auto-wiring on new worktrees

If you don't want switchboard touching `.claude/settings.local.json` or
`.codex/hooks.json` on create, set in `config.yml`:

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

Sounds ride the **same per-worktree hooks** as the exact dots. So a worktree needs
hooks enabled to make sound — automatic on switchboard-created worktrees, or
`switchboard enable-hooks` in an existing one. Observation-only agents show a dot
but stay silent (the coarse signal is too noisy to ring on).

## Troubleshooting

- **No sound at all.** Check `switchboard doctor` for "audio player" — with none
  on PATH, sounds stay silent by design. Install one (`afplay` ships with macOS).
- **Dot never goes magenta (waiting).** That state only comes from hooks. Run
  `switchboard enable-hooks` in the worktree and restart the agent.
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
