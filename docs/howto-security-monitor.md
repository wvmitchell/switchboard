# How to run the security monitor

Run a standing, agent-driven monitor over switchboard. For maintainers. There's no
running service to watch, so the monitor watches what can break switchboard without
anyone touching the repo:

- the toolchain it shells out to (Ruby, git, tmux, gh),
- the agents whose hook contracts it depends on (Claude Code, Codex),
- the release pipeline (CI, tags, the Homebrew tap),
- the maintainer's own install.

This page is the monitor's **playbook**: a Claude Code session reads it on every check
and follows it. Edit it like any other doc, in a PR.

## At a glance

| | |
|---|---|
| **Workspace name** | `switchboard-security-monitor` |
| **Schedule** | every 6 hours, cron `23 0,6,12,18 * * *` (local time, ET). The scheduler fires a recurring job late by a fixed per-job offset (up to 30 min), so the 06:xx check lands before 07:00. |
| **State file** | `monitor/state.json` in Claude Code's project directory for the switchboard checkout (`~/.claude/projects/<checkout path with / as ->/`). Local, never committed, rebuilt if lost. |
| **Monitoring TTL** | `switchboard monitoring on 25200` (7 h: one interval plus jitter) |

The sibling monitor for the dvc_deal repo runs in a workspace named
`night-watch-monitor`, with its own playbook in that repo. Don't reuse its name here.

## Prerequisites

- A Claude Code session in a switchboard workspace, left open (the schedule lives in
  that session).
- `gh` authenticated with read access to `wvmitchell/switchboard` and the tap, plus
  `claude`, `codex`, `tmux` and `switchboard` on PATH.

## Start the monitor

1. Rename the workspace: `switchboard rename switchboard-security-monitor`. If the name
   is taken, another workspace is (or was) hosting the monitor: ask the maintainer
   whether to end that one first. Run one monitor per machine; two would double-check
   and double-notify. Also check `CronList`: if this session already has the heartbeat
   job, keep it rather than adding a second.
2. Run one check by hand (the [cycle](#every-check) below). It also confirms every tool
   answers.
3. Schedule the check with `CronCreate`, using the cron from [At a glance](#at-a-glance)
   and this heartbeat prompt:

   > Switchboard security monitor heartbeat. Read `docs/howto-security-monitor.md` from
   > the switchboard checkout (or `gh api repos/wvmitchell/switchboard/contents/docs/howto-security-monitor.md -H 'Accept: application/vnd.github.raw'`
   > when there's no checkout) and the state file it names, then run the cycle it
   > prescribes. Stay silent unless something crosses a threshold. Persist state
   > BEFORE reporting.

4. Record the job id and the time you armed it in the state file (`cron.id`,
   `cron.armed_at`).

### Keep it armed

`CronCreate` jobs live only in the session and **expire after 7 days**. So the monitor
re-arms itself: every check, if `cron.armed_at` is more than 6 days old (or `CronList`
no longer shows `cron.id`), it creates a fresh job with the same schedule and prompt,
deletes the old one, and records the new id. After a session restart, start the monitor
again from step 1.

The schedule only fires while the session is idle. After a long working session in the
monitor's workspace, run a check by hand instead of assuming one ran.

## Every check

1. `switchboard monitoring on 25200`, silently, at the top. That is a bit more than
   the 6-hour interval, so the workspace reads as monitoring between checks.
2. Re-arm the schedule if it's due ([Keep it armed](#keep-it-armed)).
3. Fast-forward the workspace's checkout to `main` ([Sync the
   checkout](#sync-the-checkout)). If that changed this playbook, re-read it before
   going on: the heartbeat read it from the checkout before the sync.
4. Read the state file. **If it's missing or unreadable, rebuild it**: run every check,
   record what you see as the new baselines, and report nothing except that state was
   rebuilt. A lost state file must never turn into a wall of false alarms.
5. Run the checks below and **compare against the baselines**. Report what changed, not
   absolute state.
6. **Stay silent** if nothing crossed a threshold. Routine checks are silent by design.
7. If something needs the maintainer: write it up in the workspace, each item with a
   proposed next step (never a bare metric), then run `switchboard monitoring notify`.
8. **Write the state file BEFORE reporting.** The report is gone when the session is;
   the state file is the memory.

Escalate by time of day and week:

- **Morning digest**: on the 06:xx check, summarize
  what surfaced overnight, even items below the notify bar on their own.
- **Weekly deep**: once a week (Monday morning), the [weekly checks](#weekly-checks).

Use **`gh` for all repo state, never `git fetch`.** An SSH remote can need interactive
auth (a hardware key, a password-manager agent) that fails unattended, and git then
silently serves the cached ref: a monitor that reports a stale `main` as current.
The one exception is the sync below, which fetches over HTTPS and checks the result
against `gh`.

### Sync the checkout

The monitor's session is long-lived, so its workspace's checkout falls behind `main`
with every merge. The checks read repo state through `gh`, so they don't depend on the
checkout. But the heartbeat reads this playbook from it, and the smoke runs
(`bin/test-smoke`, the real-Codex smoke) run its code: a stale checkout would pass an
old switchboard as the current one. So every check fast-forwards it:

```sh
branch=...  # sync.branch from the state file (see below)
main=$(gh api repos/wvmitchell/switchboard/commits/main --jq .sha)
if ! GIT_TERMINAL_PROMPT=0 git fetch -q https://github.com/wvmitchell/switchboard.git main ||
   [ "$(git rev-parse FETCH_HEAD)" != "$main" ]; then
  echo "couldn't sync"
elif [ "$(git symbolic-ref -q --short HEAD)" != "$branch" ] ||
     [ -n "$(git status --porcelain --untracked-files=normal)" ] ||
     ! git merge-base --is-ancestor HEAD FETCH_HEAD ||
     ! git merge -q --ff-only FETCH_HEAD; then
  echo "checkout not syncable"
fi
```

- **Fetch over HTTPS, never the `origin` remote.** The repo is public, so the fetch
  needs no credentials and can't hang on SSH auth. It also leaves `origin/main`
  untouched.
- **Trust `gh`.** If `FETCH_HEAD` isn't the `main` that `gh` reports, or the fetch
  fails, record "couldn't sync" in `last_error` and skip the smoke runs this check. The
  other checks still run.
- **Only a fast-forward.** Sync only on the monitor's own branch, with a clean working
  tree and no commits of its own. Anything else (local changes, a diverged branch, a
  different branch checked out) prints "checkout not syncable": that's a finding,
  report it, leave the checkout alone, and skip the smoke runs this check. Never reset,
  stash or force anything.
- **The monitor's own branch** is `sync.branch` in the state file. This step runs
  before the state file is read, so read just that key here. When it's missing (the
  first check, or a rebuilt state), record the branch checked out now
  (`git symbolic-ref --short HEAD`). `--untracked-files=normal` keeps a
  `status.showUntrackedFiles=no` config from hiding new files.

## The checks

### 1. Security

Alert on high or critical advisories that reach a version a user could run.

- **Dependabot alerts** (covers GitHub Actions only; there are no gems):

  ```sh
  gh api repos/wvmitchell/switchboard/dependabot/alerts --jq '[.[]|select(.state=="open")]|length'
  ```

  A 403 means alerts were turned off: that's a finding, not "zero alerts".
- **Secret scanning**: any open alert means notify right away (the repo is public).

  ```sh
  gh api repos/wvmitchell/switchboard/secret-scanning/alerts --jq '[.[]|select(.state=="open")]|length'
  ```

- **git**, the core dependency (worktrees, reflog, branch renames). New advisories and
  tags against the baseline:

  ```sh
  gh api 'repos/git/git/security-advisories?per_page=5' --jq '.[]|[.ghsa_id,.severity,.published_at]|@tsv'
  gh api repos/git/git/tags --jq '.[0].name'
  ```

- **Ruby**: new posts on <https://www.ruby-lang.org/en/security/>. Switchboard is
  stdlib-only, so what matters is a CVE in **Psych/YAML** (config parsing), **JSON**
  (hook payloads, Claude's sessions files), **Open3/Process**, or **PTY** (the smoke
  layer). A Rails or rack advisory isn't relevant.
- **tmux**: new releases and security notes (`gh release list -R tmux/tmux -L 2`).
- **gh**: advisories only (`gh api 'repos/cli/cli/security-advisories?per_page=3'`).

### 2. Upstream contract drift

The highest-value check. Switchboard's subtle parts sit on agent behavior that is
lightly documented or not documented at all. CLAUDE.md records the exact version each
contract was last verified against; the baselines track those lines, one per contract:

- the Claude and Codex **hook contract** ("Agent-state dots"),
- the sessions-file **⇅ remote link** (`bridgeSessionId`, `procStart`; "Remote-link
  glyph"),
- the sessions-file **◷ `status`** field ("Waiting on background work"),
- the **session-name sync**, which types `/rename` into Claude's pane after reading its
  screen ("Session-name sync"). It was last verified against recorded 2.1.310 screens
  in `test/fixtures/session_name`, not in a live run.

Re-verifying one doesn't advance the others.

- **Claude Code**: the installed version (`claude --version`) and the changelog head:

  ```sh
  gh api repos/anthropics/claude-code/contents/CHANGELOG.md -H 'Accept: application/vnd.github.raw' | grep -m1 '^## '
  ```

  For every version past the reviewed baseline, grep its entries for:
  `hook|SessionStart|SessionEnd|Stop|stop_hook_active|PermissionRequest|Notification|additionalContext|settings.local.json|sessions/|bridgeSessionId|procStart|remote.control|CLAUDECODE|CLAUDE_CODE_SESSION_ID|worktree|status|busy|background agent|background task|rename|session name|prompt box|prompt input|input box|divider|placeholder|vim mode`.
  Skip `[VSCode]`, `[Cloud sessions]`, `[Claude Tag]`, `[Code Review]`, Windows,
  PowerShell, self-hosted runner and mod-only entries. Then advance the baseline.

  The last four terms cover the sessions-file `status` contract the ◷ reads (CLAUDE.md,
  "Waiting on background work"). It's undocumented, and a changelog entry about it may
  not name the file ("background agents now report their status"). What switchboard
  relies on, in `~/.claude/sessions/<pid>.json`:

  - `status` stays `busy` after a turn that started a background agent ends (Claude
    doesn't rewrite it at the Stop), and reads `shell` while a background shell runs.
  - It reads `idle` once that work is done. A held chime matures only on an `idle`
    that has settled (`ClaudeSessions::SETTLE`).
  - On a normal turn end Claude writes `done` 13–29 ms before `idle`, and a finished
    background agent reads `idle` for about 15 ms before its follow-up turn reads
    `busy`. The settle logic depends on those windows staying short.

  An entry that touches any of these is a drift finding even when the grep terms only
  half match.

  The terms from `rename` on cover the session-name sync. It depends on how Claude
  draws its screen, which no changelog promises to keep. What it relies on:

  - `/rename <name>` stays a local command that renames the session and records the
    new `name` in the sessions file. The sync confirms the rename by that field.
  - The main prompt box sits between the last two divider lines on screen, starts with
    `❯` padded by an NBSP, and draws its placeholder dim. A vim-mode footer reads as no
    box.
  - `kind` keeps naming interactive sessions the way `RemoteLink::KINDS` expects.

  A redesign of the prompt box or theme, a new input mode, or a change to `/rename` is a
  drift finding even when its entry doesn't say "prompt box".

  When the **installed** version moves, check the sessions-file readers and the
  session-name sync live:

  - **⇅ remote link**: `switchboard doctor`'s "remote links (⇅)" line must still show
    `N linked` with no warning while a `/rc` session is open (`RemoteLink.health` is
    the canary).
  - **◷ background work**: in a hooked workspace, start a background agent and end the
    turn. The row must show `◷` once the turn settles, with no chime yet, then a
    resting dot and one chime once the agent's follow-up turn ends. A `●` and a chime
    at the hand-off means the `status` contract moved. (A `run_in_background` shell
    also shows `◷`, but its chime rings at the hand-off by design, so it can't test the
    hold.) There's no
    `doctor` canary for this yet; if one is added (a `status` health line like
    `RemoteLink.health`), check that instead of the manual run.
  - **Session-name sync**: rename a workspace that has an idle Claude session, then
    switch away so its pane is off screen. Within a minute the Claude session must
    carry the new name (the `name` in its sessions file, or the `/resume` picker), and
    `doctor` must show no `session name:` line. Any `session name:` line (`unrecognized`,
    `unconfirmed`, `failed_send`, `ceiling`) means the screen contract moved. `doctor`'s
    canaries for `status`, `name` and `kind` read only the sessions file, never the
    screen, so this run is the only check on the screen. A placeholder workspace that's
    due for a name is the natural one to use.
- **Codex**: the installed version (`codex --version`) and
  `gh release list -R openai/codex -L 3 --exclude-pre-releases`. Grep release notes for
  `hook|trust|config.toml|worktree|linked|PermissionRequest|SessionStart|toml_edit|env snapshot`.
  The crux (CLAUDE.md, "Codex is global"): codex must keep firing the global `[hooks]`
  block inside a **linked** worktree and keep filing approvals as
  `[hooks.state."…"]` tables. When the installed codex moves, run the real-Codex smoke
  from the [synced](#sync-the-checkout) checkout:

  ```sh
  SWITCHBOARD_CODEX_SMOKE=1 bin/test-smoke test/smoke/codex_hook_smoke_test.rb
  ```

- **tmux**: `tmux -V` against the latest release. On a new release, read its CHANGES
  for the hooks switchboard sets (`client-session-changed`, `after-new-window`,
  `session-window-changed`), the format variables it reads (`#{config_files}`,
  `#{pane_tty}`; for the session-name sync also `#{pane_in_mode}`,
  `#{pane_synchronized}`, `#{pane_width}`, `#{session_attached}` and
  `#{window_active}`), `split-window` / `resize-pane`, and `send-keys` /
  `capture-pane -e`. When the installed tmux moves, run `bin/test-smoke`.

A drift finding proposes the follow-up: "re-verify X live, then update the 'last
verified' line in CLAUDE.md", or "open an issue".

### 3. Repo health

```sh
gh api repos/wvmitchell/switchboard/commits/main --jq '.sha[0:7] + " " + (.commit.message|split("\n")[0])'
gh run list -R wvmitchell/switchboard --branch main -L 6 --json workflowName,conclusion,event,headSha,createdAt
gh pr list -R wvmitchell/switchboard --json number,title,author
gh issue list -R wvmitchell/switchboard -L 100 --json number,title
```

- **CI red on main** (`test`, `formula`, or the weekly `schedule` run of `test`) means
  notify. A scheduled run that fails with no code change is drift outside the repo
  (runner image, setup-ruby, apt): say which.
- **Release drift**: `lib/switchboard/version.rb` on main, against the newest tag
  (`gh api repos/wvmitchell/switchboard/tags --jq '.[0].name'`), against the tap
  formula's `url`:

  ```sh
  gh api repos/wvmitchell/homebrew-switchboard/contents/Formula/switchboard.rb -H 'Accept: application/vnd.github.raw' | grep url
  ```

  A version on main with no tag or formula an hour after a green push means the
  release job broke ([Reference: the release pipeline](reference-release.md)).
- New PRs and issues against the baseline go in the morning digest. A Dependabot PR is
  routine unless it's a security update.

### 4. Local install

- `switchboard --version` against the newest tag. Behind means suggest
  `switchboard upgrade`.
- `switchboard doctor 2>&1 | grep -v '✓'`, against the baselined warnings. Only a NEW
  warning is a finding; a known one the maintainer has chosen to live with (say, codex
  hooks not yet trusted in `/hooks`) stays in the baseline and isn't re-reported.

## Weekly checks

On top of a normal check, once a week:

- **Ruby support floor** (#35): CI's Ruby 3.0 job is pinned to `ubuntu-24.04` because
  setup-ruby has no 3.0 build for newer images. Watch for GitHub's retirement notice for
  that image and for setup-ruby dropping 3.0. Either one forces the decision in #35.
- **Action pins**: are the SHA pins in `.github/workflows/*.yml` still the newest release
  of their major? Dependabot should be proposing bumps; weeks of silence means check
  `.github/dependabot.yml` still parses.
- **Ruby security baseline**: record the newest post on the Ruby security page if the
  baseline has none.
- **New surfaces**: read the week's merges to main for anything that adds a new
  external tool, shell-out, agent contract or background process, and update this page
  ([below](#keep-this-page-current)).

## Keep this page current

A stale playbook is worse than none: the monitor decays into theater. On every merge to
main (the repo-health check is the trigger), ask whether it adds something to watch:

- a new shell-out or external tool (a new outage or drift surface),
- a new agent-contract dependency (a hook event, a payload field, a file Claude or Codex
  writes): add it to the drift grep lists above,
- a change to the CI, release or tap workflows,
- a new "last verified against X" line in CLAUDE.md: update the baselines to match.

Make the change as a PR to this page; the monitor proposes it, the maintainer merges it.
Ask the maintainer first when it's a judgment call: a new notify threshold, a change in
schedule, scope or cost, or two defensible options.

## Rules for the monitor

- **A check that fails open is worse than none.** A 403, 404 or empty answer from `gh`
  or a web fetch means "couldn't check", never "all clear". Record it in the state file
  (`last_error`) and surface it if it persists across two checks.
- **Never touch the maintainer's real tmux server.** `bin/test-smoke` boots its own
  isolated server and is safe; the monitor never runs `switchboard quit` or `prune`.
- **A check doesn't change the repo.** Findings become a write-up and a notify (then an
  issue or PR if the maintainer agrees). A check writes only the state file, plus the
  fast-forward of its own checkout ([Sync the checkout](#sync-the-checkout)).
