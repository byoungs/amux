# amux Development Guide

## Build & Test

```
make dev       # Build release binary, kill+relaunch app, re-apply tmux config
make test      # Lint + fast tests + release build — runs anywhere, no tmux needed
make validate  # Full test suite including tmux integration tests (parallel-safe)
make fmt       # Auto-format code
make lint      # swift-format lint + format check
make clean     # Remove build artifacts
make setup     # Full environment setup (idempotent)
```

**Never use `swift build` directly to install** — it bypasses the symlink
that `make dev` manages. Always use `make dev` to build.

`make dev` re-applies tmux config (border format, status bar, key
bindings, hooks) to every amux-managed session as part of startup, so
Config.swift changes go live without a separate refresh step.

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

## What Goes Live on `make dev`

Everything. `make dev` rebuilds + kills + relaunches amux-app, and
startup re-applies Config.applyConfig to every managed tmux session
(borders, status bar, key bindings, hooks). Code changes that don't
touch Config.swift are also live because tmux shells out to `amux-cli`
on every keypress.

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
- `select-pane` to a *different* pane auto-unzooms the window (verified on
  real tmux). So `select-pane` then "zoom if not zoomed" lands you full-screen
  on the target — no manual unzoom/rezoom dance needed. Before treating a
  tmux-interaction as a bug, reproduce it against real tmux (`tmux -L <sock>`
  on an isolated socket); FakeTmux models zoom as a plain window flag and does
  not capture this behavior.
- Never hold `LiveTmux.processLock` across a run-loop-pumping wait.
  `Process.waitUntilExit()` pumps the calling thread's run loop, so on the
  main thread it can fire a scheduled Timer (or drain a main-queue block)
  re-entrantly into the same non-recursive lock → self-deadlock. Wait on a
  `DispatchSemaphore` signalled from `terminationHandler` instead.
- Integration tests that `send-keys` a command into a tmux pane and read its
  rendered output back must call `TestSession.useCleanShell()` first. The
  developer's interactive `.zshrc` can be too slow to reach a prompt in a
  freshly-spawned pane, so the typed command lands before the line editor is
  live and is silently dropped — the test then flakes host-dependently.
  `zsh -f` prompts immediately and deterministically.
