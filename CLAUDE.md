# amux Development Guide

## Build & Test

```
make dev       # Build release binary — live on next tmux keypress
make test      # Lint + fast tests + release build — runs anywhere, no tmux needed
make validate  # Full test suite including tmux integration tests (parallel-safe)
make fmt       # Auto-format code
make lint      # swift-format lint + format check
make refresh   # Re-apply tmux config (border formats, keybindings, status bar)
make clean     # Remove build artifacts
make setup     # Full environment setup (idempotent)
```

**Never use `swift build` directly to install** — it bypasses the symlink
that `make dev` manages. Always use `make dev` to build.

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
| Border format, status bar, key bindings (`Config.swift`) | No | Yes |

tmux caches config strings. Code changes are live because tmux shells out
to `amux-cli` on every keypress.

## Architecture

Swift macOS app that embeds tmux. A native terminal view (AmuxTerm)
drives a PTY running tmux; AmuxLib is the business logic layer that
shells out to tmux via the `TmuxExecutor` protocol. AmuxCLI is a
separate binary invoked from tmux key bindings and hooks.

**AmuxTerm** (`app/Sources/AmuxTerm/`) — NSApp, terminal view, PTY
- `AppDelegate.swift` — app lifecycle, window management
- `TerminalView.swift` — NSView subclass rendering VT output
- `VTerminal.swift` — vt100/xterm emulation state
- `PTY.swift` — pseudoterminal I/O
- `KeyInput.swift` — NSEvent → KeyAction translation
- `LinkDetector.swift` — Cmd-click URL/file detection
- `UNNotificationPoster.swift` — macOS notification delivery

**AmuxLib** (`app/Sources/AmuxLib/`) — tmux orchestration + pure logic
- `AppController.swift` — action dispatch (zoom, new pane, split, etc.)
- `Tmux.swift` — tmux command wrappers (live via `TmuxExecutor`)
- `TmuxExecutor.swift` — protocol for tmux process execution
- `FakeTmux.swift` — in-memory tmux for tests
- `Config.swift` — tmux configuration (borders, status bar, key bindings)
- `LayoutEngine.swift` — pure layout state machine
- `Layout.swift` / `Sticky.swift` — grid geometry + spatial matching
- `Alert.swift` / `AlertNotification.swift` / `AlertEventTransport.swift` — attention alerts
- `Bell.swift` — BEL character scanner
- `Notify.swift` — macOS notification wrappers
- `Hooks.swift` — Claude Code hook installation
- `State.swift` — state persistence
- `PaneStyle.swift` — pane visual state
- `KeyAction.swift` — pure key → action mapping
- `Util.swift` — auto-title generation
- `HelpContent.swift` / `Landing.swift` — in-app screens

**AmuxCLI** (`app/Sources/AmuxCLI/`) — CLI invoked from tmux key bindings
- `main.swift` — dispatches to AmuxLib actions

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
- When creating a pane detached (`tmux split-window -d` or `new-window -d`),
  always follow with `select-pane -t %<id>` after the layout pipeline runs.
  `LayoutEngine.computeAdd` does not set `action.selectPane`, so focus is
  the caller's responsibility. Otherwise the new pane appears but the
  cursor stays in the old one.
