# amux Development Guide

## Build & Test

```
make dev       # Build debug dev bundle, kill+relaunch app, re-apply tmux config
make test      # Fast unit tests — runs anywhere, no tmux needed
make validate  # Full test suite including tmux integration tests (parallel-safe)
make clean     # Remove build artifacts
make setup     # Full environment setup (idempotent)
```

**Never use `swift build` directly to install** — it bypasses the symlink
that `make dev` manages. Always use `make dev` to build.

`make dev` re-applies tmux config (border format, status bar, key
bindings, hooks) to every amux-managed session as part of startup, so
Config.swift changes go live without a separate refresh step.

## Dev Flow
Flow: trunk
- Work directly on main (switched from worktree flow 2026-09-28)
- Run `make validate` before committing; commit only when Brian says so
- Push only when Brian says so; never amend a pushed commit

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
- `LinkDetector.swift` — Cmd-click URL/file detection (plain text, wrap-joining)
- `Hyperlinks.swift` — OSC 8 hyperlink tracking (per-cell stamps + URI table)
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

- `make test` — fast unit tests. Runs anywhere, no tmux needed.
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
- To create panes in a fixed order, split the pane you just created
  (`split-window -t <sess>:0.<n-1>`), never the window. tmux inserts the new
  pane immediately after the target, and a detached split (`-d`) leaves pane 0
  active — so splitting the window inserts at index 1 every time and reverses
  the intended order. Verified against real tmux 2026-09-01.
- Never put a possibly-empty field last in a `list-*` `-F` format string.
  `LiveTmux.execute` trims trailing whitespace off stdout, so an unset trailing
  option takes its tab separator with it and the row fails the field-count
  guard — silently dropping the session (hit with `@amux-parked-from`).
- A foreground `run-shell` hook holds the command that fired it until the
  hook exits AND every process holding its stdin closes it. A child spawned
  from a hook must get `standardInput = nullDevice`, and per-keypress hooks
  (`after-select-pane`) use `run-shell -b`. Violating this made every
  Cmd-1..9 wait ~700ms on a snapshot capture (fixed 2026-09-28; guarded by
  `HookLatencyTests`).
- `pipe-pane` jobs do NOT get `$TMUX` (run-shell jobs do). Anything a
  pipe-pane runs that talks back to tmux must be told the server explicitly
  (`TMUX='#{socket_path},#{pid},0'`), or it silently hits the
  default server — which, from a test socket, is the developer's live one.
- Interpolate tmux formats into hook shell commands with the `q` modifier
  (`#{q:session_name}`, `#{q:pane_current_path}`), never bare or in single
  quotes: names and paths can contain spaces, quotes, and `$`.
- A raw-mode CLI TUI (the restore prompt, the pickers) is testable without a
  human: run it in a real pane, read it back with `capture-pane`, send keys,
  assert the resulting tmux state — see `app/Tests/PromptHarness.swift`. Point
  it at a scratch `$AMUX_HOME` (all state paths resolve through `AmuxPaths`);
  `amux-cli` follows `$TMUX` to the server that spawned it, so a pane on the
  test socket keeps the test off the developer's live amux.
- Integration tests that `send-keys` a command into a tmux pane and read its
  rendered output back must call `TestSession.useCleanShell()` first. The
  developer's interactive `.zshrc` can be too slow to reach a prompt in a
  freshly-spawned pane, so the typed command lands before the line editor is
  live and is silently dropped — the test then flakes host-dependently.
  `zsh -f` prompts immediately and deterministically.
