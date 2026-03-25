# Level 1 Layout Customization

**Status:** Backlog

**Goal:** Let users rearrange panes at bird's eye level (L1) by dragging or
swapping, so their spatial layout reflects their mental model of the project.

## Problem

Currently the grid layout is deterministic — pane count determines position.
Users can't say "I want the API server on the left and the frontend on the
right." Panes go where the grid engine puts them.

## Idea

At L1 (bird's eye), let users swap pane positions with arrow keys + a modifier
(e.g., Shift+Arrow). The custom arrangement persists across add/remove via
spatial stickiness (panes remember their center coordinates).

## Considerations

- Spatial stickiness already tracks pane centers — custom positions would
  naturally persist through the existing snap-back mechanism
- Need to decide: should custom positions survive across session restarts?
  Currently centers are stored as tmux pane options (ephemeral).
- The grid engine would need to respect user-defined positions rather than
  always computing from scratch
- Could start simple: just swap two adjacent panes (Shift+Arrow swaps the
  active pane with its neighbor in that direction)
