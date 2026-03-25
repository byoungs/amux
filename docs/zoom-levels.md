# Focus: Three-Level Zoom Model

## Overview

Focus has three zoom levels. Think of it like a camera:
- **Level 1 (Bird's Eye)** — See everything, touch nothing
- **Level 2 (Working View)** — Active pane receives keystrokes, everything still visible
- **Level 3 (Full Screen)** — One pane fills the entire screen

```
Level 1: Bird's Eye          Level 2: Working View         Level 3: Full Screen
(read-only scanning)         (typing in pane 2)            (pane 2 only)

┌─────────┬─────────┐       ┌────┬──────────────┐         ┌──────────────────┐
│         │         │       │    │              │         │                  │
│  pane 1 │  pane 2 │  C-2  │ 1  │   pane 2     │  C-2    │                  │
│         │         │ ───►  │    │   (active)   │ ───►   │    pane 2        │
│         │         │       │    │              │         │    (full screen) │
├─────────┼─────────┤       ├────┼──────────────┤         │                  │
│         │         │       │    │              │         │                  │
│  pane 3 │  pane 4 │       │ 3  │   4          │         │                  │
│         │         │       │    │              │         │                  │
└─────────┴─────────┘       └────┴──────────────┘         └──────────────────┘

         C-2 ───────────────────►                  C-2 ───►
         ◄─────────────────────── C--              ◄────── C--
```

## Level 1: Bird's Eye

All panes tiled equally and fully readable. **No pane receives keystrokes** — you're reading and scanning across all panes, deciding where to focus next.

```
4 panes at 120x40 terminal:

┌──── pane 1 ─────────────┬──── pane 2 ─────────────┐
│ ~/src/project-alpha      │ ~/src/project-beta       │
│ $ claude                 │ $ claude                 │
│ ● Investigating auth bug │ ● Running test suite     │
│ ...                      │ ...                      │
│                          │                          │
│                          │                          │
├──── pane 3 ─────────────┼──── pane 4 ─────────────┤
│ ~/src/project-gamma      │ ~/src/api-service        │
│ $ claude                 │ $ make deploy            │
│ ● Writing migration      │ Deploying to staging...  │
│ ...                      │ ...                      │
│                          │                          │
│                          │                          │
└──────────────────────────┴──────────────────────────┘
 BIRD'S EYE   C-+ in · C-1..4 focus · C-n new
```

**Actions available:**
- `Ctrl-1..9` — Focus on pane N (→ Level 2)
- `Ctrl-+` — Focus on the highlighted pane (→ Level 2)
- `Ctrl-n` — Create new pane
- Arrow keys — Move highlight between panes (no mode switch needed)

**Arrow keys at Level 1:** Since no pane receives keystrokes, arrow keys can navigate between panes directly — no Ctrl modifier or nav mode needed. This solves the keybinding conflict problem entirely.


## Level 2: Working View

The active pane receives keystrokes. It may be enlarged depending on how many panes exist, but all panes remain visible.

### Already big enough — no resize needed

When the active pane already meets the minimum size (e.g., 2 panes on a wide
screen, or 4 panes on a large monitor), nothing changes visually. The pane
just starts receiving keystrokes.

```
┌──── pane 1 ─────────────┬──── pane 2 ◆────────────┐
│ ~/src/project-alpha      │ ~/src/project-beta       │
│ $ claude                 │ $ echo "typing here"     │
│ ● Investigating auth bug │ typing here              │
│ ...                      │ $                        │
│                          │                          │
│                          │                          │
│                          │                          │
│                          │                          │
│                          │                          │
└──────────────────────────┴──────────────────────────┘
 WORKING: pane 2   C-+ full screen · C-- bird's eye
```

Each pane is 140x25 — already at minimum. No resize needed.


### Too small — enlarge active pane

When the active pane is below the minimum (e.g., 6 panes tiled on a normal
screen gives ~93x16 per pane), the active pane is enlarged and others shrink.

```
┌─ 1 ──────┬──── pane 2 ◆───────────────────────────┐
│ ~/src/..  │ ~/src/project-beta                      │
│ $ claude  │ $ echo "typing here"                    │
│ ● Inves.. │ typing here                             │
│           │ $                                       │
│           │                                         │
├─ 3 ──────┤                                         │
│ ~/src/..  │                                         │
│           │                                         │
├─ 4 ──────┼─ 5 ────────┬─ 6 ────────────────────────┤
│ ~/src/..  │ ~/src/..   │ ~/src/..                    │
│           │            │                             │
└───────────┴────────────┴─────────────────────────────┘
 WORKING: pane 2   C-+ full screen · C-- bird's eye
```

Pane 2 is enlarged to the minimum size. Others shrink to fit.
The active pane stays in its general grid position.


## Level 3: Full Screen

One pane fills the entire terminal. All others hidden. This is tmux's native zoom (`resize-pane -Z`).

```
┌──── pane 2 ◆───────────────────────────────────────┐
│ ~/src/project-beta                                  │
│ $ echo "typing here"                                │
│ typing here                                         │
│ $ ls -la                                            │
│ total 42                                            │
│ drwxr-xr-x  12 user  staff   384 Mar 22 10:00 .    │
│ -rw-r--r--   1 user  staff  1234 Mar 22 10:00 foo  │
│ ...                                                 │
│                                                     │
│                                                     │
│                                                     │
│                                                     │
└─────────────────────────────────────────────────────┘
 FULL SCREEN: pane 2   C-- working view · C-1..4 switch
```


## Navigation Summary

```
                    Ctrl-+ or Ctrl-N
    Level 1  ─────────────────────────►  Level 2
   Bird's Eye                            Working View
    (scan)   ◄─────────────────────────  (type)
                       Ctrl--

                    Ctrl-+ or Ctrl-N
    Level 2  ─────────────────────────►  Level 3
  Working View                           Full Screen
    (type)   ◄─────────────────────────  (type)
                       Ctrl--


    Level 1  ─── Ctrl-N then Ctrl-N ──► Level 3
   Bird's Eye    (double-tap same #)     Full Screen
             ◄── Ctrl-- then Ctrl-- ───
```

### Key bindings by level:

| Key       | Level 1 (Bird's Eye)      | Level 2 (Working)          | Level 3 (Full Screen)      |
|-----------|---------------------------|----------------------------|----------------------------|
| Ctrl-N    | Go to pane N at L2        | If same pane → L3          | If same pane → (stay L3)   |
|           |                           | If diff pane → switch, L2  | If diff pane → switch, L2  |
| Ctrl-+    | Focus highlighted → L2    | Zoom active → L3           | (already full screen)      |
| Ctrl--    | (already bird's eye)      | Back to L1                 | Back to L2                 |
| Arrows    | Move highlight            | (sent to active pane)      | (sent to active pane)      |
| Ctrl-n    | Create new pane           | Create new pane            | Create new pane            |
| Ctrl-L    | Start split view          | Start split view           | —                          |
| Any text  | (ignored)                 | Sent to active pane        | Sent to active pane        |

### Ctrl-N behavior detail

Ctrl-N (where N is 1-9) is context-aware — it does the smart thing:

```
Current state          Action              Result
─────────────────────────────────────────────────────
L1, any pane        → Ctrl-3           → L2, pane 3 active
L2, pane 3 active   → Ctrl-3 (same)   → L3, pane 3 full screen
L2, pane 3 active   → Ctrl-1 (diff)   → L2, pane 1 active
L3, pane 3 full     → Ctrl-3 (same)   → stay L3 (already there)
L3, pane 3 full     → Ctrl-1 (diff)   → L2, pane 1 active
```

This means **Ctrl-N Ctrl-N** (double-tap same number) always takes you from
bird's eye to full screen on that pane. And pressing a different number
always lands you in working view on that pane — never jarring.


## Implementation Notes

### Level 1 (Bird's Eye) — new concept
- This is a new mode where tmux does NOT send keystrokes to any pane
- Arrow keys navigate between panes (change which border is highlighted)
- Requires either: (a) a tmux key table that captures all keys, or (b) a small
  overlay process that captures input and sends tmux commands
- The simplest approach: use tmux's `copy-mode` or a custom key table

### Level 2 (Working View) — the "smart resize"
- The active pane has a **minimum size guarantee**: ~140 cols x 25 rows
- If the active pane already meets the minimum (e.g., 2 wide panes on a large
  screen), no resize happens — everything stays where it is
- If the active pane is smaller than the minimum (e.g., 4+ panes on a normal
  screen), tmux enlarges it and shrinks the others to fit
- The active pane stays in its grid position (doesn't move to a different corner)
- When switching active pane at Level 2, the resize follows the new active pane
- When zooming out to Level 1, the tiled layout is restored (all panes equal)

**Size-based logic (not pane-count-based):**
```
if active_pane.width >= MIN_WIDTH && active_pane.height >= MIN_HEIGHT:
    # Already big enough — do nothing, just start receiving keystrokes
else:
    # Enlarge active pane to at least MIN_WIDTH x MIN_HEIGHT
    # Other panes shrink proportionally
    tmux resize-pane -t <active> -x <target_width> -y <target_height>
```

**Minimum pane size:** 120 cols x 24 rows (hardcoded, tunable)
- Reference: user's 5-pane setup at 140x25 was "about minimum, maybe a bit small"
- 120x24 is a classic terminal size — readable for code and Claude Code output
- If a tiled pane is already >= 120x24, Level 2 does no resize
- If a tiled pane is < 120x24, Level 2 enlarges it to 120x24 (or as close as possible)
- Constant defined in code: `MIN_PANE_COLS = 120`, `MIN_PANE_ROWS = 24`

### Level 3 (Full Screen) — already implemented
- This is tmux's native `resize-pane -Z`
- Already works perfectly

### Transition animations
- Level 1 → 2: tmux resizes panes (instant, no animation needed)
- Level 2 → 3: tmux zoom (instant)
- Level 3 → 2: tmux unzoom + resize (instant)
- Level 2 → 1: tmux restores tiled layout (instant)
