# Demo Recording Design

**Date:** 2026-03-29
**Status:** Approved

## Problem

amux needs a demo GIF for the README that shows the core workflow: grid
view with attention alerts, navigation, zoom in/out. Previous approaches
(screencapture, manual recording) failed due to permissions, human-in-the-loop
requirements, and tmux send-keys not triggering keybindings.

## Design

### Approach: VHS + background driver + setup script

Three components work together:

1. **Setup script** — creates a tmux session with 4 panes, realistic
   content, and alert state. Runs before VHS.
2. **Driver script** — runs in the background during VHS recording,
   calling amux CLI commands (zoom, pane-next, etc.) on a timer.
3. **VHS tape** — attaches to the tmux session, kicks off the driver,
   and records for the duration. Output is a GIF.

### Why this works

- `amux zoom 0`, `amux zoom-in`, `amux pane-next` are proven to work
  from outside the session
- VHS records the tmux session as it appears in a virtual terminal
- No screen recording permissions needed
- No human in the loop — Claude can run VHS, read the output GIF,
  and iterate

### Pane content (realistic AI agent output)

| Pane | Title | Content | State |
|------|-------|---------|-------|
| 1 | myapp/auth-refactor | Completed plan (structured markdown with headers, bullets, file paths) | Alert (amber) — agent finished, needs review |
| 2 | myapp/test-suite | Streaming test output (lines appear during recording) | Working (dark) — agent is busy |
| 3 | myapp/main | Permission prompt ("Allow editing these files?") | Alert (amber) — agent needs input |
| 4 | myapp/deploy | Clean shell prompt, recent git status output | Active (teal) — user's home pane |

Content uses ANSI color codes via `printf`/heredocs — no visible `echo`
commands. Pane 2 uses a background script that slowly outputs lines during
recording to simulate a working agent.

### Demo beats (~25 seconds)

1. **Grid** (3s) — 4 panes, 2 amber alerts, status bar shows "● 2"
2. **Jump to alert** (3s) — `amux zoom 0`, pane 1 becomes active
3. **Zoom in** (4s) — `amux zoom-in`, plan fills screen, readable
4. **Zoom out** (3s) — `amux zoom-out`, back to grid
5. **Cycle to next alert** (3s) — `amux pane-next` x2, land on pane 3
6. **Zoom in/out on pane 3** (4s) — show the permission prompt up close
7. **End card** (3s) — back to grid, clean state

### Validation

Claude reads the output GIF after each run. Checks:
- 4 panes visible in grid view
- Amber borders on alert panes
- Zoom transitions happen
- Content is readable when zoomed
- No visible setup artifacts (echo commands, script paths)

If any check fails, adjust setup/driver/tape and re-run.

### Output

- `docs/demo.gif` — the final GIF for README
- `docs/demo.tape` — VHS tape file (checked in for reproducibility)
- `docs/demo-setup.sh` — setup script (checked in)
- `docs/demo-driver.sh` — driver script (checked in)
