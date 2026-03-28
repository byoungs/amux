# Getting Started with amux

amux is a terminal workspace for running multiple Claude Code agents in parallel.

## Install

1. Download **amux.dmg**
2. Open the DMG
3. Drag **amux** to your **Applications** folder
4. Launch **amux** from Applications (or Spotlight)

That's it. Everything is bundled — no Homebrew, Rust, or terminal setup needed.

On first launch, amux installs a small CLI helper to `~/.local/bin/amux`. You may need to add `~/.local/bin` to your PATH if it isn't already:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## Keyboard Shortcuts

All shortcuts use **Cmd**. No prefix key.

| Shortcut | Action |
|----------|--------|
| **Cmd-N** | New pane (start another Claude Code agent) |
| **Cmd-1..9** | Jump to pane by number |
| **Cmd-]** | Next pane (cycles around) |
| **Cmd-[** | Previous pane |
| **Cmd-+** | Zoom in (full screen) |
| **Cmd--** | Zoom out (back to grid / space picker) |
| **Cmd-P** | Space picker |
| **Cmd-C** | Copy selected text |
| **Cmd-V** | Paste |
| **Shift-Enter** | Newline in Claude Code input |

## Workflow

1. Launch amux — you get a single shell pane
2. Type `claude` to start Claude Code
3. **Cmd-N** to create more panes for parallel work
4. Panes arrange in a grid automatically

### Border Colors

| Color | Meaning |
|-------|---------|
| **Teal** | Active — you're focused here |
| **Amber** | Needs you — agent waiting for input |
| **Dark** | Working — agent is busy |

### Zooming

- **Cmd-+** zooms in to full screen on the current pane
- **Cmd--** zooms back out to the grid
- **Cmd-]** / **Cmd-[** cycles panes (works in both grid and full screen)

### Spaces

Spaces are separate workspaces (like virtual desktops for your agents).

- **Cmd-P** opens the space picker
- Press **n** to create a new space
- Spaces with waiting agents are marked

## Tips

- **Cmd-Q** quits the app but your session stays alive. Relaunch to pick up where you left off.
- Click on a pane to focus it. Scroll wheel works for history.
- Right-click for Copy/Paste menu.

## Requirements

- macOS 14 (Sonoma) or later
- That's it — tmux is bundled inside the app
