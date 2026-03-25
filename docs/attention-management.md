# Attention Management

## Design Principle

**Progressive disclosure along the zoom axis.**

Each zoom level reveals exactly one more layer of detail about what needs your
attention. You never receive more information than your current attention level
asks for. The system informs without demanding — you pull information toward
you by zooming out, rather than having it pushed at you.

| Context | What you see |
|---------|-------------|
| **Level 3** (deep focus) | Badge in status bar right corner: `⬤ 2` — something needs you, no detail |
| **Level 2** (working) | Pane border colors — *which* pane needs you |
| **Level 1** (bird's eye) | All panes and their states — full team dashboard |
| **Space picker** (Ctrl-P) | Which *spaces* have agents waiting for you |
| **Outside amux** | macOS system notification — something needs you back in amux |

Every zoom-out reveals one more layer. Every zoom-in narrows your view.
The system respects where you are on this gradient at all times.

## The Team Model

amux manages a team of AI agents working in parallel. The metaphor is a
manager with a team of junior developers: they work independently, and
periodically one raises their hand — "I have a question" or "I'm done, ready
for review." You don't owe them urgency. You get to them when you're ready.

This is **calm technology**: the system moves information to the periphery and
only brings it to the center when you choose. Mark Weiser called this
"periphery to center" transitions. The zoom levels are literally that
transition mechanism.

## Pane States

Every pane communicates one of three states through its border color:

| State | Border | Meaning |
|-------|--------|---------|
| **Active** | Bright teal (existing) | You are focused on this pane |
| **Working** | Dark/dim (existing) | Agent is busy, no action needed |
| **Ready for you** | Amber/yellow (new) | Agent needs input — bell received |

### Ready-for-you behavior

- **Trigger:** tmux bell character (emitted by Claude Code on permission
  prompts, completion, etc.)
- **Persistence:** The amber border stays until you *focus* that pane. Seeing
  it is not enough — you must select it as the active pane.
- **At level 2:** Amber borders are visible on non-active panes in the grid.
- **At level 1:** All pane states visible at a glance — this is the team
  standup view.

## Level 3 Status Badge

When you're in full-screen mode (level 3), other panes are hidden. A subtle
badge appears in the **right corner** of the status bar to provide ambient
awareness:

```
                                                          ⬤ 2
```

- Shows count of panes in the "ready for you" state
- Updates in real time as bells arrive
- Decrements as you address panes
- Hidden when count is zero — no visual noise when nothing needs you

This is the equivalent of an unread badge on a phone app icon. You don't need
to know which agents or what they want — just that something is waiting,
whenever you're ready.

## Space Picker Indicators

The space picker (`Ctrl-P`) serves as the **notification center**. Each space
shows its team status:

```
  ● auth-refactor        ⬤⬤
    api-migration
  ● billing-fix           ⬤
```

- Spaces with agents in "ready for you" state show amber dots (count matches
  number of waiting panes)
- Spaces with no waiting agents show nothing extra
- Current space retains its existing green dot marker

This lets you survey all your workspaces and decide where to go based on
what needs attention.

### Smart landing on space switch

When you select a space from the picker:

- **One pane ready:** Land on that pane at level 2 (working view). The system
  assumes you came here to deal with the one thing that's waiting.
- **Zero or multiple panes ready:** Land where you left off (same pane, same
  zoom level). With zero, nothing needs you — resume. With multiple, the system
  doesn't presume which one you want.

**Exception:** If you were at level 3 in the destination space, land at level 2
instead. You zoomed out to get to the picker — landing back at level 3 would
feel like the system trapped you.

## System Notifications (Outside amux)

When amux is **not** the frontmost macOS application (you're in a browser,
editor, email, etc.), the system sends macOS notifications to bring you back.

### Behavior

- **First bell:** Immediate macOS notification — "amux: an agent is ready
  for you"
- **Suppression window:** After a notification fires, suppress further system
  notifications for 30 seconds
- **After window:** Next bell triggers a new notification with updated count
- **When amux is active:** No system notifications, ever. All communication
  is internal (borders, badges, picker indicators).

### Detection

Frontmost-app detection via macOS APIs. Options:
- `osascript` to query `NSWorkspace.frontmostApplication`
- A small Swift helper binary
- The `active-app` crate or similar Rust binding

The check runs each time a bell event is received, before deciding whether to
send a system notification.

## Implementation: pipe-pane BEL Detection

amux uses tmux's `pipe-pane` to monitor each pane's raw output for terminal
bell characters (BEL, 0x07). This works automatically — no user configuration
needed. Any application that sends a bell (Claude Code, or anything else)
triggers the attention system.

### How it works

When amux creates a pane or refreshes config, it sets up a `pipe-pane` on
each pane:

```
tmux pipe-pane -t SESSION:.N "exec focus bell-watch --session SESSION N"
```

The `focus bell-watch` process reads the pane's raw output stream and runs a
state machine that distinguishes bare BEL characters from BEL used as
terminators in escape sequences (OSC, DCS, APC, PM). When a real bell is
detected, it calls the alert logic.

### BEL scanner state machine

Terminal applications use BEL (0x07) for two purposes:
1. **Ring the bell** — "I need attention" (what we want to detect)
2. **Terminate string sequences** — OSC (`ESC ]...BEL`), DCS (`ESC P...BEL`),
   APC (`ESC _...BEL`), PM (`ESC ^...BEL`)

The scanner tracks four states (Normal, Esc, StringSeq, StringEsc) to
distinguish these cases. Only bare BEL — outside any string sequence —
triggers an alert. The state carries across buffer boundaries, so split
escape sequences are handled correctly.

### Alert flow

1. Application in pane N sends a BEL character
2. tmux pipes the output to `focus bell-watch --session S N`
3. The scanner detects a bare BEL
4. `trigger_alert` runs: skip if pane is active or already alerted
5. Sets `@focus-alert=1` on pane N
6. Updates `@focus-alert-count` session option
7. If terminal is not frontmost → sends macOS notification (with 30-second
   suppression window)

### Why not tmux's alert-bell hook?

tmux's `alert-bell` hook does not populate `#{hook_pane}` — it fires at the
window level with no pane identity. This is a tmux source code limitation
(`alerts.c` passes NULL for the pane parameter). Using `pipe-pane` gives us
per-pane detection without requiring application cooperation.

### Alternative: Claude Code Notification hook

For users who want explicit control, `focus alert-pane N` can also be called
directly from Claude Code's Notification hook:

```json
{
  "hooks": {
    "Notification": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "focus alert-pane $(tmux display-message -p '#{pane_index}')"
      }]
    }]
  }
}
```

This is optional — pipe-pane detection works without it.

### Dismissal

When a pane becomes the active pane:
1. Clear its "ready for you" state (`@focus-alert=0`)
2. Border returns to active teal automatically (conditional format)
3. Decrement the status badge count

## State Storage

Following amux's existing pattern of storing state in tmux:

| Variable | Scope | Purpose |
|----------|-------|---------|
| `@focus-alert` | Pane option | `1` if pane is in "ready for you" state |
| `@focus-alert-count` | Session option | Number of panes with active alerts |
| `FOCUS_LAST_NOTIFY` | Session env | Unix timestamp of last system notification |

No external state files needed. The alert flag lives on the pane object and
survives index renumbering, consistent with existing `@focus-cx/cy` pattern.

## Design Test

For any future feature involving notifications or attention: **does it respect
progressive disclosure along the zoom axis?** Information should only appear
at the level of detail matching the user's current zoom level. If the answer
is no, redesign it.
