# Architecture

## Overview

amux is a native macOS app (AmuxTerm) with an embedded terminal emulator
built on libvterm. tmux handles all pane/session management and rendering;
the Swift app provides the GUI shell, keyboard dispatch, and visual overlays.

The app connects to tmux via a PTY running `tmux attach-session`. All user
input flows through the Swift app's key handler, which either dispatches
amux commands or forwards raw bytes to the PTY. A separate CLI binary
(amux-cli) handles tmux hook callbacks and interactive popups.

## Key Components

### AmuxTerm (GUI app)

- **AppDelegate** — App lifecycle, PTY creation, NSEvent key monitor
- **TerminalView** — Renders vterm cells with CoreText, handles mouse
  events, Cmd-click link detection, and Cmd-held status bar highlighting
- **KeyInput** — Pure function: `(NSEvent, InputMode) → KeyAction`.
  Maps Cmd-key combos to AmuxCommands, testable without GUI
- **AppController** — Business logic for all user actions. Reads tmux
  state and executes effects through the Tmux executor
- **PTY** — Manages the pseudo-terminal connected to tmux

### AmuxLib (shared library)

- **Tmux** — tmux command wrappers, routed through TmuxExecutor
- **TmuxExecutor** — Protocol with LiveTmux (real) and FakeTmux (test)
  implementations. Tests inject FakeTmux to run without tmux
- **Config** — Applies border formats, status bar, and hooks to sessions
- **Layout / LayoutEngine** — Grid layout computation and tmux layout
  string generation
- **Sticky** — Spatial pane matching (panes stay in their grid position
  when others are added/removed)
- **HelpContent** — Keyboard shortcut reference data (used by help TUI)
- **PaneStyle** — Visual state management for pane borders and status bar
- **Bell** — BEL character scanner for attention alerts

### AmuxCLI (command-line tool)

- Called by tmux hooks (`after-select-pane`, `pane-exited`, etc.)
- Runs interactive TUI popups (spaces picker, send picker, help screen)
- Commands: `layout`, `update-title`, `alert-pane`, `bell-watch`,
  `spaces`, `send`, `help`, `hook-install`

## Keyboard Handling

All key bindings are handled natively by the Swift app via
`NSEvent.addLocalMonitorForEvents`. tmux's prefix key is disabled entirely.

```
NSEvent → KeyInput.action(for:mode:) → KeyAction
  ├── .amux(command) → AppController.handleAction()
  ├── .sendToPTY(data) → pty.write()
  ├── .system → let macOS handle (⌘Q, ⌘C, ⌘V)
  └── .ignore → drop
```

### Shortcuts

| Key | Action |
|-----|--------|
| ⌘+/= | Zoom in (full screen) |
| ⌘- | Zoom out (grid or spaces) |
| ⌘[/] | Cycle panes |
| ⌘1-9 | Focus pane by number |
| ⌘N | New pane (inherits cwd) |
| ⌘L | Split-pick mode |
| ⌘S | Send pane to another space |
| ⌘P | Spaces picker |
| ⌘/ | Help screen |

## Grid Layout Engine

`LayoutEngine.computeLayout()` takes current state and an event, returns
a `LayoutAction` describing what tmux commands to run. The layout pipeline
is: gather state → compute → execute.

| Panes | Grid shape |
|-------|-----------|
| 1 | Full screen |
| 2 | Left/right split |
| 3 | Left full-height + right column split into 2 |
| 4 | 2×2 |
| 5 | Left 2-high + right 3-high |
| 6 | 3×2 |
| 7+ | 2 rows, ceil(n/2) columns |

## Spatial Stickiness

When panes are added or removed, existing panes stay in their grid
position. Each pane's center coordinates are tracked in tmux pane options
(`@amux-cx`, `@amux-cy`). On layout changes, panes are matched to grid
slots by minimum Euclidean distance and swapped into place.

## Spaces (tmux sessions)

Each "space" is a tmux session marked with `AMUX_MANAGED=1`. The spaces
picker (⌘P) lists managed sessions with alert indicators. Smart landing
focuses the alerting pane when switching to a space with one alert.

## Split View

⌘L enters split-pick mode: select two panes to view side by side in a
second tmux window. Red border overlay highlights the first selection.
Status bar shows pick instructions. Esc cancels. Requires 3+ panes.

## Attention Management

Alert pipeline uses both Claude Code's Notification hook and tmux's BEL
character detection via `pipe-pane`:

1. Alert source fires → `amux-cli alert-pane N`
2. Sets `@amux-alert=1` on the pane, updates `@amux-alert-count`
3. Sends macOS notification if terminal not frontmost (30s suppression)
4. Amber border overlay on alerting panes (TerminalView)
5. Alert count badge in status bar (● N)
6. Dismissed when pane becomes active

See [attention-management.md](attention-management.md) for the full spec.

## tmux State

All runtime state lives in tmux (no external database):

| Variable | Scope | Purpose |
|----------|-------|---------|
| `AMUX_MANAGED=1` | Session env | Marks session as amux-managed |
| `@amux-title` | Pane option | Custom pane title |
| `@amux-cx`, `@amux-cy` | Pane option | Current center coordinates |
| `@amux-pcx`, `@amux-pcy` | Pane option | Previous center coordinates |
| `@amux-alert` | Pane option | `1` if pane needs attention |
| `@amux-alert-count` | Session option | Number of alerted panes |
| `@amux-cmd-held` | Session option | `1` when Cmd key is held (status bar glow) |
| `@amux-picking` | Session option | `1` during split-pick mode |
| `@amux-split-first-label` | Session option | Label for first-selected split pane |

## Testing

**Unit tests** (no tmux needed): embedded in the app binary, run via
`amux-app --run-tests`. Covers KeyInput, Layout, LayoutEngine, Sticky,
Bell, AppController (with FakeTmux), PaneStyle, LinkDetector.

**Integration tests** (need tmux): separate `amux-integration-tests`
executable. Tests run on an isolated tmux server (custom socket via `-L`)
so they can't leak to the user's live tmux. Covers zoom, config, alerts,
send, split mode, session resolution, border formats.
