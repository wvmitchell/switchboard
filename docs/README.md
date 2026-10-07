# Switchboard documentation

The full documentation set, organized by the [Diataxis](https://diataxis.fr/)
framework — four kinds of doc for four reader needs. New to switchboard? Start
with the tutorial. Looking up a specific fact? Go straight to reference.

The project [README](../README.md) is the glanceable overview; these docs are the
depth behind it.

## By reader need (Diataxis)

### 📚 Tutorial — learning by doing
- [Getting started](tutorial-getting-started.md) — install to your first worktree
  switch, with a live agent dot, in about ten minutes.

### 🔧 How-to guides — accomplish a specific task
- [Install, upgrade, or move to Homebrew](howto-install-and-upgrade.md) — brew or
  clone, upgrading either, moving a clone install to brew, uninstalling.
- [Manage projects and worktrees](howto-manage-projects.md) — add, clone, create,
  rename, remove.
- [Agent state & sounds](howto-agent-state-and-sounds.md) — enable exact dots,
  tune completion sounds.
- [Customize keybindings](howto-keybindings.md) — remap `prefix-s`, bind a home
  key.
- [Housekeeping & diagnostics](howto-housekeeping.md) — `prune`, `quit`, and the
  `doctor`.
- [Cut a release & enable the Homebrew tap](howto-release.md) — maintainers: the
  version bump, what the pipeline does after merge, and the one-time tap setup.

### 📖 Reference — the precise facts
- [Reading the sidebar](reference-sidebar.md) — every dot, badge, diff count, and
  mark the tree draws, and what each one means.
- [The `switchboard` command](reference-cli.md) — every subcommand, argument, and
  flag.
- [`config.yml`](reference-config.md) — every field, type, default, and resolution
  rule, plus filesystem locations.
- [Keybindings](reference-keybindings.md) — the tmux prefix keys and the sidebar
  keys.
- [The release pipeline](reference-release.md) — the `release` and `formula`
  workflows, the release decision table, `packaging/release.rb`, and the formula.

### 💡 Explanation — why it works this way
- [Architecture](explanation-architecture.md) — git as the source of truth, one
  model + one front-end, tmux as the window manager.
- [Agent presence](explanation-agent-presence.md) — the two-signal dots, hooks,
  and the one edge that drives the dot, the sound, and the bold name.
- [The sidebar's lifecycle](explanation-sidebar-lifecycle.md) — per-session
  visibility, off-screen dormancy, and the recycled-pane-id bug it prevents.
- [Distribution](explanation-distribution.md) — why install paths go through
  Homebrew's `opt/` link, and why only a fully-green main tip ever releases.

## By audience

- **New users** → the [tutorial](tutorial-getting-started.md), then
  [reading the sidebar](reference-sidebar.md) and the
  [how-tos](howto-manage-projects.md).
- **Power users** → the [reference](reference-cli.md) docs and
  [keybindings](howto-keybindings.md).
- **Maintainers & contributors** → [CONTRIBUTING](../CONTRIBUTING.md), the
  [explanation](explanation-architecture.md) docs, and
  [cutting a release](howto-release.md).
- **AI coding agents** → [AGENTS.md](../AGENTS.md) and [CLAUDE.md](../CLAUDE.md)
  (the canonical deep map), backed by the explanation docs.

## See also

- [README](../README.md) — feature overview and quickstart.
- [CHANGELOG](../CHANGELOG.md) — what changed per version.
- [TODOS](../TODOS.md) — deferred work, with the reasoning preserved.
