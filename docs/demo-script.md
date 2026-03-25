# Demo Recording Script

Record with a screen recorder (OBS, CleanShot, or `asciinema rec`).
Terminal should be ~280 columns wide for clean grid layouts.

## Scene 1: Launch (10s)
```
amux
```
- Show: single pane with status bar showing "amux" branding and "BIRD'S EYE"

## Scene 2: Create panes (15s)
- Press `Ctrl-n` three times to create 4 panes total
- Show: 2x2 grid forms automatically, each pane auto-titled from cwd/branch

## Scene 3: Three-level zoom (20s)
- Press `Ctrl-1` — zoom into pane 1 (L2 Working)
- Show: status bar changes to "WORKING"
- Press `Ctrl-+` — zoom to full screen (L3)
- Show: status bar changes to "FULL SCREEN"
- Press `Ctrl--` — back to Working
- Press `Ctrl--` — back to Bird's Eye
- Show: all 4 panes visible again, arrow keys navigate

## Scene 4: Pane switching (10s)
- Press `Ctrl-2`, `Ctrl-3`, `Ctrl-4` — instant pane switching
- Show: no layout shift, grid stays perfectly stable

## Scene 5: Attention management (20s)
- Start Claude Code in two panes (e.g., `claude -p "say hello"`)
- When one finishes, its border turns amber
- Show: amber border at Working level
- Zoom to Full Screen on the other pane
- Show: status badge "⬤ 1" in corner
- Press `Ctrl--` back to Bird's Eye
- Show: amber pane clearly visible in dashboard view

## Scene 6: Spaces (15s)
- Press `Ctrl-P` — space picker opens
- Press `n`, type "backend" — new space created
- Press `Ctrl-P` again — two spaces listed
- Switch back to original space
- Show: everything preserved

## Scene 7: Spatial stickiness (15s)
- Start with 4 panes (2x2)
- Close one pane (`exit` in shell)
- Show: remaining 3 panes rebalance, positions stable
- Press `Ctrl-n` — new pane fills the vacancy
- Show: original panes snap back to their corners

## Total: ~2 minutes

## Tips
- Use a dark terminal theme (amux looks best on black backgrounds)
- Resize the terminal window during recording to show auto-relayout
- Run real Claude Code sessions for authenticity
- Consider split-screening the recording with a voiceover
