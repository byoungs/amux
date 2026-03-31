# amux Development Guide

## Build & Test

```
make dev       # Build release binary — live on next tmux keypress
make test      # Lint + fast tests + release build — runs anywhere, no tmux needed
make validate  # Full test suite including tmux integration tests (parallel-safe)
make fmt       # Auto-format code
make lint      # clippy + format check
make refresh   # Re-apply tmux config (border formats, keybindings, status bar)
make clean     # Remove build artifacts
make setup     # Full environment setup (idempotent)
```

**Never use `cargo install --path .`** — it overwrites the symlink that
`make dev` manages. Always use `make dev` to build.

## Dev Flow
Flow: worktree
- All code changes happen in worktrees, never on main
- Use /dev to start work (creates worktree automatically)
- Use /stage to wrap up (prepares clean commit for wtr landing)
- Brian reviews and lands via wtr (ff-only merge → validate → push)

## Linear
- Workspace: penfield-six
- Team: Penfield Six (key: PEN)
- Project: amux

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
- `make validate` — full suite including tmux integration tests. Parallel-safe via unique session names.
- Use `make test` for rapid iteration. Use `make validate` as the final
  verification before claiming work is complete — it catches adapter-layer
  bugs that unit tests miss.

## Conventions

- TDD: write failing test first, then implement
- One concern per file, small focused modules
- tmux format strings use explicit value comparisons (`#{==:#{@amux-alert},1}`)
  not truthy checks (`#{?@amux-alert,...}`) — tmux treats "0" as truthy
