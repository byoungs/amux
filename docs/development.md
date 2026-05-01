# Development Guide

## Setup

```bash
git clone https://github.com/byoungs/amux.git
cd amux
make setup
```

`make setup` is idempotent — safe to re-run anytime.

## Build & Run

```bash
make dev       # Build debug app + CLI, kill+relaunch AmuxTerm
make test      # Unit tests (no tmux needed)
make validate  # Full suite: unit + tmux integration tests
make clean     # Remove build artifacts
```

### What Goes Live When

| Change type | Live on `make dev`? |
|------------|---------------------|
| App logic (zoom, alert, layout, keyboard) | Yes (kill + relaunch) |
| CLI commands (spaces, send, help, hooks) | Yes (next tmux hook/popup) |
| Border format, status bar, key bindings (Config.swift) | Yes (re-applied at startup) |

`make dev` kills and relaunches amux-app, and startup re-applies
Config.applyConfig to every managed tmux session — so Config.swift
changes go live without a separate refresh step. CLI changes are live
immediately because tmux shells out to `amux-cli` on every hook
invocation.

## Project Structure

```
app/
  Sources/
    AmuxTerm/         # macOS GUI app (TerminalView, KeyInput, AppDelegate)
    AmuxLib/          # Shared library (AppController, Tmux, Layout, etc.)
    AmuxCLI/          # CLI tool for tmux hooks and popups
    CVterm/           # C bridge to libvterm
  Tests/              # Integration tests (need tmux)
  Resources/          # App icon, Info.plist
docs/                 # Architecture and feature documentation
Makefile              # Build, test, release targets
```

## Worktree Development

All changes happen on branches in git worktrees. Main stays clean.

```bash
# Create a worktree (or use Claude Code's /dev command)
git worktree add -b fix-something .claude/worktrees/fix-something main
```

Develop in the worktree:

```bash
make dev        # Build and launch
make test       # Unit tests
make validate   # Full test suite (before claiming done)
```

Merge via `wtr` (ff-only merge → validate → push).

## Testing

### Unit tests (`make test`)

Run via `amux-app --run-tests`. No tmux needed. Tests use FakeTmux
(in-memory executor) so they run fast and don't affect live tmux.

Covers: KeyInput, Layout, LayoutEngine, Sticky, Bell, AppController,
PaneStyle, LinkDetector, FakeTmux, SplitRestore.

### Integration tests (`make validate`)

Run via `amux-integration-tests`. Requires tmux. Tests run on an isolated
tmux server (custom socket via `-L`) so they can't leak sessions or
messages to the user's live tmux.

Covers: smoke tests, config, zoom, alert, attention, send, split mode,
session resolution, border formats, Cmd-L scenarios, help content.

## Release

```bash
make release    # Build + validate + create DMG
make publish    # Tag + push + GitHub release
```

## Make Targets

| Target | What it does |
|--------|-------------|
| `make dev` | Build and launch app in debug mode |
| `make test` | Unit tests (fast, no tmux) |
| `make validate` | Full test suite (unit + integration) |
| `make release` | Build release DMG |
| `make publish` | Tag and publish to GitHub |
| `make clean` | Remove build artifacts |
| `make setup` | Full environment setup (idempotent) |
