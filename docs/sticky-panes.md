# Sticky Panes

Sticky panes is amux's system for keeping panes spatially stable when the
grid changes. When you add or remove a pane, the remaining panes should
stay where you expect them, not shuffle around unpredictably.

## The Alternating Layout Pattern

Layouts alternate between **balanced grids** (even pane counts) and
**balanced + full-height column** (odd counts):

```
1        2         3           4         5             6           7               8
┌────┐  ┌──┬──┐  ┌──┬──┐   ┌──┬──┐  ┌──┬──┬───┐  ┌──┬──┬──┐  ┌──┬──┬──┬───┐  ┌──┬──┬──┬──┐
│    │  │  │  │  │  │ B│   │TL│TR│  │TL│TR│   │  │TL│TM│TR│  │TL│TM│TR│   │  │  │  │  │  │
│ A  │  │A │B │  │A ├──┤   ├──┼──┤  ├──┼──┤ R │  ├──┼──┼──┤  ├──┼──┼──┤ R │  ├──┼──┼──┼──┤
│    │  │  │  │  │  │ C│   │BL│BR│  │BL│BR│   │  │BL│BM│BR│  │BL│BM│BR│   │  │  │  │  │  │
└────┘  └──┴──┘  └──┴──┘   └──┴──┘  └──┴──┴───┘  └──┴──┴──┘  └──┴──┴──┴───┘  └──┴──┴──┴──┘
full    2 cols   col+split  2x2      2x2+col      3x2          3x2+col         4x2
```

The pattern: **even → odd = add column. Odd → even = split column.**

This creates a natural growth progression:
- Adding a pane to a balanced grid appends a full-height column on the right.
  The existing grid doesn't move at all.
- Adding a pane to a balanced+column layout splits the right column in half
  (existing pane stays top, new pane goes bottom). The balanced part doesn't move.

## Adding Panes

### Balanced → balanced+column (4→5, 6→7, 8→9)

The existing balanced grid stays in place. A new full-height column appears
on the right. Zero disruption to existing panes.

```
4→5:
┌──┬──┐         ┌──┬──┬───┐
│ A│ B│         │ A│ B│   │
├──┼──┤    →    ├──┼──┤ E │     E = new pane, full-height right column
│ C│ D│         │ C│ D│   │     A,B,C,D untouched
└──┴──┘         └──┴──┴───┘
```

### Balanced+column → balanced (5→6, 7→8, 9→10)

The right column splits. Existing full-height pane shrinks to top-right.
New pane fills bottom-right. The balanced part doesn't move.

```
5→6:
┌──┬──┬───┐     ┌──┬──┬──┐
│ A│ B│   │     │ A│ B│ E│
├──┼──┤ E │  →  ├──┼──┼──┤     E shrinks to top-right, F fills bottom-right
│ C│ D│   │     │ C│ D│ F│     A,B,C,D untouched
└──┴──┴───┘     └──┴──┴──┘
```

### Unbalanced → balanced (3→4)

The 3-pane layout has a full-height left pane and a split right column.
Going to 2x2: the right column stays put, the left pane shrinks to TL,
and the new pane fills BL.

```
3→4:
┌──┬──┐         ┌──┬──┐
│  │ B│         │ A│ B│
│ A├──┤    →    ├──┼──┤     Right column stays. A→TL. New→BL.
│  │ C│         │NW│ C│
└──┴──┘         └──┴──┘
```

## Removing Panes

Two rules govern removal:

### Rule 1: Column-Mate Expands (balanced → unbalanced)

When a pane is removed from a balanced grid, its **column-mate** (the pane
in the same column, other row) expands to full height. The other columns
stay split. The full-height column stays on the **same side** as the removed
pane.

```
Remove TL from 2x2:        Remove TR from 2x2:
┌──┬──┐     ┌──┬──┐        ┌──┬──┐     ┌──┬──┐
│ x│ B│     │  │ B│        │ A│ x│     │ A│  │
├──┼──┤  →  │BL├──┤        ├──┼──┤  →  ├──┤BR│
│BL│BR│     │  │BR│        │ C│BR│     │ C│  │
└──┴──┘     └──┴──┘        └──┴──┘     └──┴──┘
```

This means the 3-pane layout must support full-height on **either side**,
not just the left. The orientation is determined by which column the
removal happened in.

For 3x2 → 5-pane: the column-mate takes the full-height right column,
and the remaining columns compact into the 2x2 part.

```
Remove TM from 3x2:
┌──┬──┬──┐     ┌──┬──┬───┐
│ A│ x│ C│     │ A│ C│   │
├──┼──┼──┤  →  ├──┼──┤BM │     BM = column-mate of removed TM
│ D│BM│ F│     │ D│ F│   │     C,F shift left into 2x2
└──┴──┴──┘     └──┴──┴───┘
```

### Rule 2: Substitute Fills Gap (unbalanced → balanced)

When a pane is removed from the balanced part of a balanced+column layout,
the full-height column pane **fills the hole**. Everyone else stays put.

```
Remove TL from 2x2+col:
┌──┬──┬───┐     ┌──┬──┐
│ x│ B│   │     │ R│ B│
├──┼──┤ R │  →  ├──┼──┤     R fills the gap left by TL
│ C│ D│   │     │ C│ D│     B,C,D stay
└──┴──┴───┘     └──┴──┘
```

When the full-height column itself is removed, the balanced grid simply
stays as-is with zero movement.

## Design Rationale

### Why not pure geometric matching?

The original algorithm used Euclidean distance between pane centers and
slot centers. This works for simple cases but fails when the grid shape
changes significantly:

- A full-height left pane (center at mid-height) is geometrically closer
  to BL than TL. So going 3→4, it would go to BL, displacing the
  right-bottom pane to TL — very confusing.

- Pure geometry doesn't understand that "bottom-right in a 2x2" and
  "bottom-right in a 3x2" represent the same conceptual position.

### Why the alternating pattern?

The balanced/balanced+column alternation means:
- **Even → odd**: purely additive (new column, zero disruption)
- **Odd → even**: the column splits (minimal disruption, only 2 panes affected)

This is the minimum possible disruption at each step. No existing pane
needs to jump across the grid.

### Why column-mate for removal?

When a pane dies, its column has a hole. The column-mate is the most
natural pane to fill it — it's already in the same column and just needs
to expand vertically. This preserves the spatial relationship: the other
columns stay exactly as they were.
