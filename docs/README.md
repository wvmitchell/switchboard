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
- [Manage projects and worktrees](howto-manage-projects.md) — add, clone, create,
  rename, remove.
- [Agent state & sounds](howto-agent-state-and-sounds.md) — enable exact dots,
  tune completion sounds.
- [Customize keybindings](howto-keybindings.md) — remap `prefix-s`, bind a home
  key.
- [Housekeeping & diagnostics](howto-housekeeping.md) — `prune`, `quit`, and the
  `doctor`.

### 📖 Reference — the precise facts
- [The `switchboard` command](reference-cli.md) — every subcommand, argument, and
  flag.
- [`config.yml`](reference-config.md) — every field, type, default, and resolution
  rule, plus filesystem locations.
- [Keybindings](reference-keybindings.md) — the tmux prefix keys and the sidebar
  keys.

### 💡 Explanation — why it works this way
- [Architecture](explanation-architecture.md) — git as the source of truth, one
  model + one front-end, tmux as the window manager.
- [Agent presence](explanation-agent-presence.md) — the two-signal dots, hooks,
  and the one edge that drives the dot, the sound, and the bold name.
- [The sidebar's lifecycle](explanation-sidebar-lifecycle.md) — per-session
  visibility, off-screen dormancy, and the recycled-pane-id bug it prevents.

## By audience

- **New users** → the [tutorial](tutorial-getting-started.md), then the
  [how-tos](howto-manage-projects.md).
- **Power users** → the [reference](reference-cli.md) docs and
  [keybindings](howto-keybindings.md).
- **Maintainers & contributors** → [CONTRIBUTING](../CONTRIBUTING.md) and the
  [explanation](explanation-architecture.md) docs.
- **AI coding agents** → [AGENTS.md](../AGENTS.md) and [CLAUDE.md](../CLAUDE.md)
  (the canonical deep map), backed by the explanation docs.

## See also

- [README](../README.md) — feature overview and quickstart.
- [CHANGELOG](../CHANGELOG.md) — what changed per version.
- [TODOS](../TODOS.md) — deferred work, with the reasoning preserved.
