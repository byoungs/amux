# Demo Recording

Produces the demo GIF for the README. Fully automated via VHS + Pillow.

## Quick Start

```bash
bash demo/setup.sh                                     # create demo tmux session
vhs -o demo/demo-raw.gif demo/demo.tape                # record raw demo
python3 demo/overlay.py demo/demo-raw.gif demo/demo.gif # add text overlays
```

The final `demo.gif` is attached to the GitHub release (not stored in git).
`make publish` handles this automatically.

## Setup (before recording)

1. Launch amux.app — clean session, one pane
2. Create 3 more panes (`Cmd-N` x3) so you have a 4-pane grid
3. In each pane, start `claude` with a task:
   - **Pane 1**: a task that returns a long plan (the zoom-in moment)
   - **Pane 2**: something still running (dark border)
   - **Pane 3**: something that hits a permission prompt (amber border)
   - **Pane 4**: your active pane (teal border)
4. Wait until state is right: pane 1 done with plan (amber), pane 3
   waiting for input (amber), pane 2 churning (dark), pane 4 active

If real agent timing is too unpredictable, fake it:
- Use `sleep` + `echo` scripts that simulate output
- Trigger alerts manually: `amux alert-pane amux <index>`

## The Recording

### Beat 1: The Grid (3s)
**Show:** 4 panes in a grid. Pane 4 active (teal). Panes 1 and 3
have amber borders. Pane 2 is dark.

**Caption:** *"Four agents running. Two need your attention."*

Hold for a beat — let the viewer read the border colors.

### Beat 2: Navigate to Alert (3s)
**Action:** `Cmd-1` to jump to pane 1.

**Caption:** *"Cmd-1 — jump to it"*

Pane 1 becomes active. The plan output is visible but crammed into
a grid cell — clearly too dense to read.

### Beat 3: Zoom In (5s)
**Action:** `Cmd-=` to zoom to full screen.

**Caption:** *"Cmd-= — zoom in to read"*

The plan fills the screen. Scroll slowly to show structured content
(steps, file names, details). Status bar shows "FULL SCREEN" with
a badge indicating 1 other pane still needs attention.

### Beat 4: Zoom Out (3s)
**Action:** `Cmd--` to zoom back out.

**Caption:** *"Cmd-- — back to the grid"*

4-pane grid returns. Pane 1 alert is cleared. Pane 3 still amber.

### Beat 5: Quick Navigate (3s)
**Action:** `Cmd-]` twice to cycle to pane 3.

**Caption:** *"Cmd-] — cycle through panes"*

Active highlight moves one pane per press. Land on pane 3 (the
permission prompt).

### Beat 6: Handle It (3s)
**Action:** Type a response or press Enter.

**Caption:** *"Handle it, move on"*

Pane 3's amber border clears as the agent resumes.

### Beat 7: Send to Space (5s)
**Action:** `Cmd-S` opens the send-to-space picker. Select or create
a space. The pane moves — grid reflows to 3 panes.

**Caption:** *"Cmd-S — send to another space"*

### Beat 8: Split View (5s)
**Action:** `Cmd-L` to start split view. Pick a second pane. Two
panes appear side by side.

**Caption:** *"Cmd-L — compare two panes"*

`Cmd--` exits back to the grid.

### Beat 9: End Card (3s)
**Show:** Grid with all borders dark (everyone working). Clean.

**Caption:** *"amux — manage your attention, not your terminals"*

Fade or cut.

## Total: ~33 seconds

## Shorter Cut (15 seconds)

For a quick README hero GIF, skip spaces and split view:

1. Grid with 4 panes, 2 amber (2s)
2. `Cmd-1` to jump to alerted pane (1s)
3. `Cmd-=` to zoom in, show the plan (4s)
4. `Cmd--` to zoom out (1s)
5. `Cmd-]` to cycle to next alert (2s)
6. Handle it (2s)
7. End card (3s)

## Tips

- Use a dark background (amux looks best on black)
- Use a large enough window that grid text is somewhat legible
- Key press captions should appear *as* the key is pressed
- Real Claude Code sessions are more authentic, but scripts are more
  controllable — use whichever gets the timing right
