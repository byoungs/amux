# amux Development Guide

## Build & Test

```
make dev       # Build release binary — live on next tmux keypress
make test      # Lint + fast tests + release build — runs anywhere, no tmux needed
make validate  # Full test suite in Docker (includes tmux integration tests)
make fmt       # Auto-format code
make lint      # clippy + format check
make refresh   # Re-apply tmux config (border formats, keybindings, status bar)
make clean     # Remove build artifacts
make setup     # Full environment setup (idempotent)
```

**Never use `cargo install --path .`** — it overwrites the symlink that
`make dev` manages. Always use `make dev` to build.

## Worktree Workflow

**All code changes happen in worktrees. Never commit directly to main.**

When asked to make any code change, create a worktree first — don't ask,
just do it. Name the branch after the work (e.g., `fix-alert-dismiss`,
`add-split-view`).

### Creating a worktree
```
git worktree add -b <branch-name> .worktrees/<branch-name> main
```

### Developing
```
make dev       # Build — binary is live on next tmux keypress
make test      # Run tests
make refresh   # Only needed if you changed tmux config strings in config.rs
```

### Completing work
```
# Squash to single commit on the branch
# Rebase onto current main (essential for parallel worktrees)
git rebase main
# Brian reviews, then from main:
git merge --ff-only <branch-name>
make dev
git worktree remove .worktrees/<branch-name>
git branch -d <branch-name>
```

## What Goes Live Instantly vs Needs Refresh

| Change type | Live on build? | Needs `make refresh`? |
|------------|---------------|----------------------|
| Zoom/alert/layout/notification logic | Yes | No |
| Border format, status bar, key bindings (config.rs) | No | Yes |

tmux caches config strings. Code changes are live because tmux shells out
to `amux` on every keypress.

## Architecture

Single Rust binary. tmux does all rendering. amux configures tmux and
handles CLI commands invoked by tmux key bindings and hooks.

- `src/main.rs` — CLI entry point, zoom state machine, picker UIs
- `src/config.rs` — tmux configuration (borders, status bar, key bindings)
- `src/tmux.rs` — tmux command wrappers
- `src/alert.rs` — pure alert decision logic
- `src/layout.rs` — grid layout engine
- `src/sticky.rs` — spatial pane matching
- `src/notify.rs` — macOS notifications
- `src/hooks.rs` — Claude Code hook installation
- `src/bell.rs` — BEL character scanner
- `src/state.rs` — state persistence
- `src/util.rs` — auto-title generation

## Testing

- `make test` — lint + fast tests + release build. Runs anywhere, no tmux needed.
- `make validate` — full suite in Docker with tmux HEAD. Reliable, isolated.

## Conventions

- TDD: write failing test first, then implement
- One concern per file, small focused modules
- tmux format strings use explicit value comparisons (`#{==:#{@amux-alert},1}`)
  not truthy checks (`#{?@amux-alert,...}`) — tmux treats "0" as truthy
