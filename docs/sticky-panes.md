# Sticky Panes

Sticky panes is amux's rule for where panes go when the grid changes. The
rule keeps pane **numbers** stable: the number you press with Cmd-1..9
always follows a predictable order, no matter how panes are added or closed.

## The Grid

Layouts alternate between **balanced grids** (even pane counts) and
**balanced + full-height column** (odd counts):

```
1        2         3           4         5             6           7               8
┌────┐  ┌──┬──┐  ┌──┬──┐   ┌──┬──┐  ┌──┬──┬───┐  ┌──┬──┬──┐  ┌──┬──┬──┬───┐  ┌──┬──┬──┬──┐
│    │  │  │  │  │  │ 2│   │ 1│ 2│  │ 1│ 2│   │  │ 1│ 2│ 3│  │ 1│ 2│ 3│   │  │ 1│ 2│ 3│ 4│
│ 1  │  │1 │2 │  │1 ├──┤   ├──┼──┤  ├──┼──┤ 5 │  ├──┼──┼──┤  ├──┼──┼──┤ 7 │  ├──┼──┼──┼──┤
│    │  │  │  │  │  │ 3│   │ 3│ 4│  │ 3│ 4│   │  │ 4│ 5│ 6│  │ 4│ 5│ 6│   │  │ 5│ 6│ 7│ 8│
└────┘  └──┴──┘  └──┴──┘   └──┴──┘  └──┴──┴───┘  └──┴──┴──┘  └──┴──┴──┴───┘  └──┴──┴──┴──┘
```

Slots are numbered in reading order: top row left to right, bottom row
left to right, then the right column. A pane's number is its slot.

## The Rule

Every change keeps the panes in their current order and re-tiles them into
the grid for the new count.

- **Add:** the new pane is always last. Every existing pane keeps its number.
- **Close:** each pane after the closed one moves down one number. Panes
  before it don't change.
- **Resize, attach, unzoom:** nothing changes order; the grid is redrawn at
  the new size.

```
Close pane 1 of 9:
┌──┬──┬──┬──┬──┐     ┌──┬──┬──┬──┐
│ x│ B│ C│ D│  │     │ B│ C│ D│ E│
├──┼──┼──┼──┤ I│  →  ├──┼──┼──┼──┤     every pane moves down one number;
│ E│ F│ G│ H│  │     │ F│ G│ H│ I│     I goes 9 → 8
└──┴──┴──┴──┴──┘     └──┴──┴──┴──┘
```

## Design Rationale

### Why order, not position?

amux used to keep panes *spatially* still: a closed pane's column-mate or
the right-column pane moved into the gap, and window resizes matched panes
to slots by nearest center. That kept panes on screen near where they were,
but their numbers jumped. Closing pane 1 of 9 sent pane 9 to pane 1, and
when two panes were equally close to a slot, a tie decided which one got it
(pane 9 landed at 2 after two closes, 2026-10-26).

Numbers are what you navigate by, so they are what stays predictable. Panes
may move on screen after a close, but always by sliding into the slot
before them.

### Why it holds on every path

Pane exit (`pane-exited`) and `kill-pane` (`window-layout-changed`) re-tile
with `.resize` after tmux has already removed the pane and merged its space
into a neighbour. The surviving geometry no longer says where the dead pane
was, but tmux keeps the survivors in index order, so ordering by index needs
nothing else. tmux inserts a split pane right after its source, so `.add`
moves the new pane to the end explicitly.
