# Scroll UX Overhaul — Design

## Problem

Scroll behavior in amux is broken:

1. **Wrong content shown.** Scrolling up surfaces older pane history ("prior prompts") instead of the current Claude Code response. Does not occur when running Claude Code in Terminal.app / iTerm2 outside amux.
2. **Scroll speed too fast.** Hard to navigate precisely.
3. **No vertical scrollbar.** Only scroll-wheel input; no visual scroll indicator.

## Root Cause

`TerminalView.scrollWheel` unconditionally emits SGR mouse wheel sequences (`ESC [ < 64;col;row;M`) via `KeyInput.scrollBytes`. Problems:

- **tmux mouse is off** (`Config.swift:116` — history-limit only, no `mouse on`). SGR mouse passes through to Claude Code, which only consumes mouse events in fullscreen mode. Classic-mode Claude Code ignores them; the wheel becomes a no-op inside the TUI, but tmux pane state can still drift in confusing ways.
- **No alt-screen gating.** Standard terminal emulators (xterm, iTerm2, Alacritty, WezTerm, VTE) translate wheel events to cursor-up/down in alt-screen apps when mouse reporting is off — amux does not.
- **Base rate = `visibleRows / 10`** — ~4 lines per wheel tick on a 40-row pane. macOS pre-multiplies wheel deltas, so this compounds into very coarse jumps.

## Goals

- Scroll wheel does the expected thing in every common TUI state: Claude Code (classic + fullscreen), vim, less, htop, and plain shells.
- Scroll speed feels natural; adjustable with shift modifier.
- Visible scrollbar confirms position and availability of scrollback on main screen.

## Non-Goals

- Amux owning its own scrollback buffer (tmux already does; duplicating it fights resize/reflow).
- Draggable scrollbar that re-positions tmux copy-mode via `goto-line`. Read-only indicator only.
- DECSET 1007 (alternate-scroll) support. libvterm doesn't expose it; the `altScreen && mouse==NONE` heuristic gives correct behavior for every app we care about.

## Design

### 1. Track alt-screen + mouse mode in `VTerminal`

libvterm fires `settermprop` callbacks for `VTERM_PROP_ALTSCREEN` (bool) and `VTERM_PROP_MOUSE` (number: 0=NONE, 1=CLICK, 2=DRAG, 3=MOVE).

Extend `VTerminal.swift`:

- Add stored properties:
  ```swift
  private(set) var isAltScreen: Bool = false
  private(set) var mouseMode: MouseMode = .none
  enum MouseMode: Int { case none = 0, click = 1, drag = 2, move = 3 }
  ```
- Extend `onSetTermProp` C callback to decode `prop == VTERM_PROP_ALTSCREEN` into `val.pointee.boolean` and `prop == VTERM_PROP_MOUSE` into `val.pointee.number`.
- No changes to libvterm bindings required — these prop IDs are already defined in `CVterm`.

### 2. Translate wheel in `KeyInput.scrollBytes`

New signature:

```swift
static func scrollBytes(
  deltaY: CGFloat,
  col: Int, row: Int,
  cellHeight: CGFloat,
  precise: Bool,
  shiftHeld: Bool,
  isAltScreen: Bool,
  mouseMode: MouseMode
) -> [Data]
```

Decision tree:

1. **`isAltScreen && mouseMode == .none`** → emit cursor-key sequences:
   - Wheel up: `ESC [ A` per line. Wheel down: `ESC [ B`.
   - Matches xterm / Alacritty / WezTerm alt-scroll default. CSI form (not SS3) works regardless of cursor-key mode.
   - Arrow keys are regular key input — tmux forwards them to the pane app (no mouse binding fires).
2. **Else** (main screen, or alt-screen with app mouse mode on) → emit SGR mouse events.
   - Main screen → tmux's `WheelUpPane` binding enters copy-mode and scrolls.
   - Alt-screen with mouse mode → tmux re-emits via `send-keys -M`; pane app consumes as mouse.

Speed: **1 line per wheel tick** on imprecise wheel events (macOS pre-multiplies; matches Alacritty/iTerm2). Shift+wheel = 5 lines. Precise trackpad: fractional accumulator, 1 cell per `cellHeight` of delta (unchanged from today).

Hard cap at 10 lines per event to guard against runaway touchpad deltas.

### 3. Enable tmux mouse on, with alt-screen pass-through

`Config.swift`:

```
tmuxSetGlobal("mouse", "on")

tmuxBind(key: "WheelUpPane", table: "root", command:
  "if-shell -Ft= '#{?pane_in_mode,1,#{alternate_on}}' " +
  "'send-keys -M' " +
  "'select-pane -t=; copy-mode -eu'")

tmuxBind(key: "WheelDownPane", table: "root", command:
  "if-shell -Ft= '#{?pane_in_mode,1,#{alternate_on}}' " +
  "'send-keys -M' " +
  "'send-keys -M'")
```

Effect:

- **Main screen** (classic Claude Code, shell): wheel up enters tmux copy-mode, scrolls pane history. Wheel down exits at bottom.
- **Alt-screen** (fullscreen Claude Code, vim): tmux passes wheel through. Amux has already translated to arrow keys → app scrolls natively.
- **In copy-mode**: wheel scrolls copy-mode buffer.

Requires `make refresh` after Config.swift changes (tmux caches bindings).

### 4. Read-only scrollbar overlay

Add `NSScroller` subview to `TerminalView`:

- Style: `.overlay` (auto fade-in on macOS; matches Ghostty / Terminal.app).
- Position: anchored to trailing edge, 15px wide when visible.
- **Hidden when `VTerminal.isAltScreen == true`**. Industry standard — alt-screen has no scrollback.
- `knobProportion` = `visibleRows / (visibleRows + tmuxHistoryLines)`.
- `doubleValue` (position) = `(tmuxHistoryLines - scrollPosition) / tmuxHistoryLines` in copy-mode; 1.0 (bottom) when not in copy-mode.
- **Not draggable.** `.enabled = false` suppresses hit-testing. Wheel + keys remain the only scroll inputs.

Tmux state query, polled once per 100ms while view is in front OR on every scroll event:

```
tmux display-message -p -t % \
  '#{history_size} #{?pane_in_mode,#{scroll_position},}'
```

Parse both tokens; pass to `NSScroller` update.

## Data Flow

```
User scroll wheel
  ↓
NSEvent → TerminalView.scrollWheel
  ↓
Query VTerminal.isAltScreen, VTerminal.mouseMode
  ↓
KeyInput.scrollBytes → byte sequence
  ↓
PTY.write → tmux
  ↓
tmux alternate_on? → pass-through to pane app (alt-screen)
                  → copy-mode -eu (main screen)
  ↓
Pane app (Claude Code, vim, shell) handles arrow keys or SGR mouse
  ↓
App output → PTY → VTerminal.write → screen callbacks → redraw
  ↓ (parallel)
Scrollbar polls tmux display-message → NSScroller.knobProportion/doubleValue
```

## Testing

### Unit Tests

`VTerminalTests.swift` — new cases:

- Inject `ESC [ ? 1049 h` → assert `isAltScreen == true`.
- Inject `ESC [ ? 1049 l` → assert `isAltScreen == false`.
- Inject `ESC [ ? 1000 h` → assert `mouseMode == .click`.
- Inject `ESC [ ? 1002 h` → assert `mouseMode == .drag`.
- Inject `ESC [ ? 1000 l` after set → assert `mouseMode == .none`.

`KeyInputTests.swift` — parametrize `scrollBytes` over (altScreen × mouseMode × precise × shift):

- `altScreen=true, mouseMode=.none, deltaY=-1, precise=false` → `["\u{1B}[B"]` (1 arrow down).
- `altScreen=true, mouseMode=.click, deltaY=-1, precise=false` → SGR mouse.
- `altScreen=false, mouseMode=.none` → SGR mouse (tmux binding handles).
- `shift=true, altScreen=true, mouseMode=.none` → 5 arrow sequences.
- Deltas clamped to hard cap of 10.

`ConfigTests.swift` (new) — snapshot the rendered tmux bindings so drift is caught in `make test`.

### Manual Validation Checklist

Run `make validate` plus this checklist in a live amux session:

| Scenario | Expected |
|----------|----------|
| Claude Code classic, scroll up | Pane enters tmux copy-mode; conversation history visible |
| Claude Code classic, scroll down at bottom | Exits copy-mode |
| Claude Code fullscreen (`/tui fullscreen`), scroll up | Transcript scrolls within Claude Code (no copy-mode entry) |
| vim, scroll up/down | Cursor moves (arrow-key behavior) |
| less, scroll up/down | Page scrolls |
| Plain shell, scroll up | tmux copy-mode |
| Shift+wheel | ~5× scroll distance |
| Scrollbar in classic mode | Visible, thumb at bottom when caught up |
| Scrollbar in fullscreen mode | Hidden |
| Scrollbar in copy-mode | Thumb position tracks tmux `scroll_position` |

## Rollout

One worktree (`scrollback-ux`), one squashed commit, no flags. Changes are localized to four files:

- `app/Sources/AmuxTerm/VTerminal.swift` — state tracking
- `app/Sources/AmuxTerm/KeyInput.swift` — translation logic
- `app/Sources/AmuxTerm/TerminalView.swift` — scrollbar subview, scrollWheel wiring
- `app/Sources/AmuxLib/Config.swift` — tmux mouse on + bindings

Brian lands via `wtr` after review. Users get improved scroll after `make dev` + tmux `make refresh`.
