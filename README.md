# amux

**The AI Multiplexer. The Attention Multiplexer.**

A terminal multiplexer purpose-built for parallel AI coding.

## Why amux?

You're coding with Claude Code and hit a point where you need something done
in parallel — a refactor, a test suite, a migration. You spin up a new pane
and start a second thread. Then a third. Before long you have six agents
working across your codebase.

Now you need to come back. Which ones are done? Which ones are waiting on you?
You want to collapse back to four threads and pull the important results into
focus. You can't. You're tabbing between terminals, hunting for permission
prompts, losing your place. The agents are fast — but you've become the
bottleneck.

**Running multiple AI agents is a solved problem. Managing your attention
across them is not.** That's what amux solves.

amux gives you a fluid workspace where threads expand and contract naturally.
Spin up agents when you need parallelism. See at a glance which ones need you.
Zoom in to pair with one. Zoom out to survey the team. Bring background work
into the foreground. Collapse finished threads. The workspace reshapes around
your attention — not the other way around.

### Why not tmux / Zellij / screen / iTerm2 splits?

Those are general-purpose terminal multiplexers. They give you panes, but they
have no concept of what's happening inside them. amux is purpose-built for the
flow of AI coding:

- **Attention-aware**: pane borders show agent state (working, waiting, idle)
  — your terminal is a team dashboard, not a grid of anonymous rectangles
- **Fluid scaling**: expand to 6+ agents when you need parallelism, collapse
  back to 2 when you don't — panes stick to their spatial positions
- **Progressive zoom**: two levels — working grid and full screen — with
  quick cycling between panes in either view
- **Calm notifications**: visual indicators when you're in the terminal, a
  single macOS notification when you're away. No alert fatigue.

## Quick Start

### One-Line Install

```bash
curl -sSL https://raw.githubusercontent.com/byoungs/amux/main/scripts/install.sh | bash
```

### Manual Install

```bash
git clone https://github.com/byoungs/amux.git
cd amux
make setup
amux
```

### What Setup Does

`make setup` prepares your environment (safe to re-run anytime):

1. Verifies Rust toolchain is installed
2. Checks tmux version and warns if tmux HEAD is needed (for flicker-free rendering)
3. Builds the amux binary
4. Creates a symlink so `amux` is on your PATH
5. Installs the Claude Code notification hook for attention management

If you move the repo, re-run `make setup` to update the symlink.

Create panes with `Ctrl-n`, cycle between them with `Ctrl-]`/`Ctrl-[`,
zoom in with `Ctrl-+`, zoom out with `Ctrl--`.

## How It Works

amux is a thin layer on top of tmux. It configures layout, styles, key
bindings, and attention tracking, then gets out of the way. tmux handles all
rendering — perfect keystroke fidelity, perfect resize, zero overhead.

### Two-Level Zoom

| Level | View | Mode | Enter | Exit |
|-------|------|------|-------|------|
| **Working** | All panes visible in a grid | Pair with one agent — type in the active pane | `Ctrl--` from Full Screen | `Ctrl-+` |
| **Full Screen** | One pane fills terminal | Deep focus — heads down on one task | `Ctrl-+` from Working | `Ctrl--` |

`Ctrl-]` and `Ctrl-[` cycle between panes (wraps around at the ends).
Works in both Working and Full Screen — in Full Screen, the view stays
zoomed as you cycle.

`Ctrl-1` through `Ctrl-9` jumps to a specific pane. Press the same number
again to zoom deeper. Press a different number to switch panes.

`Ctrl--` from Working opens the space picker instead of zooming out
further — spaces replace the old bird's eye view.

### Attention Management

Every pane border tells you its state at a glance:

| Border | Meaning |
|--------|---------|
| **Teal** (bright) | Active — you're focused here |
| **Amber** | Ready for you — agent needs input |
| **Dark** | Working — agent is busy, nothing to do |

The system respects your attention level:

- **Full Screen**: a subtle badge in the status bar corner shows how many
  agents are waiting. No detail, no interruption.
- **Working**: amber borders glow on panes that need you.
- **Space Picker** (`Ctrl-P` or `Ctrl--`): indicators show which spaces
  have waiting agents.
- **Outside amux**: a single macOS notification brings you back. No per-agent
  spam.

### Pane Layout

Panes arrange in an alternating grid pattern — balanced grids for even
counts, balanced + full-height right column for odd counts:

```
2 panes       3 panes       4 panes     5 panes        6 panes
┌────┬────┐   ┌────┬────┐   ┌──┬──┐    ┌──┬──┬───┐    ┌──┬──┬──┐
│    │    │   │    │ 2  │   │1 │2 │    │1 │2 │   │    │1 │2 │3 │
│ 1  │ 2  │   │ 1  ├────┤   ├──┼──┤    ├──┼──┤ 5 │    ├──┼──┼──┤
│    │    │   │    │ 3  │   │3 │4 │    │3 │4 │   │    │4 │5 │6 │
└────┴────┘   └────┴────┘   └──┴──┘    └──┴──┴───┘    └──┴──┴──┘
```

**Sticky panes:** When you add a pane, existing panes stay in place and
the new pane fills the next available slot. When you remove a pane, its
column-mate expands to fill the gap. The result is minimal visual
disruption — panes don't shuffle around unexpectedly.

See [docs/sticky-panes.md](docs/sticky-panes.md) for the full design.

### Spaces

Spaces are independent workspaces, each with their own grid of panes.
Think of them like desks — you swivel your chair to face a different desk,
and everything on the previous desk stays exactly where you left it.

`Ctrl-P` opens the space picker. Spaces with agents waiting for you are
marked, so you know where to go next. Press a number to switch, or `n` to
create a new space. `Ctrl-S` sends the current pane to another space.

### Split View

`Ctrl-L` pulls two panes into a side-by-side view in a dedicated window.
The rest of your grid stays in the background. `Ctrl--` exits back to the grid.

## Key Bindings

All bindings work without a prefix key.

| Key | Action |
|-----|--------|
| `Ctrl-]` | Next pane (cycles, works in Full Screen) |
| `Ctrl-[` | Previous pane (cycles, works in Full Screen) |
| `Ctrl-+` | Zoom in (Working → Full Screen) |
| `Ctrl--` | Zoom out (Full Screen → Working, Working → Spaces) |
| `Ctrl-1..9` | Jump to pane N (context-aware zoom) |
| `Ctrl-n` | Create new pane |
| `Ctrl-P` | Space picker (notification center) |
| `Ctrl-S` | Send current pane to another space |
| `Ctrl-L` | Start split view |

## Commands

```
amux               Start or attach to a session
amux start         Start a new session
amux new [name]    Create a new pane (auto-names from cwd + git branch)
amux list          List all panes
amux refresh       Re-apply config to existing session
amux spaces        Space picker
amux send          Send pane to another space
```

## How Attention Management Works

amux's attention system has two layers:

**In-terminal indicators** (all platforms): amber pane borders, status bar
badges, and space picker dots show you which agents need attention. These
work everywhere — they're just tmux styling driven by pane options.

**System notifications** (macOS only): when you leave the terminal — switch
to Chrome, email, Slack — amux sends a macOS notification to bring you back.
When you're in the terminal, no popups. Only when you're away, and only once
per 30 seconds to prevent alert fatigue.

System notification detection uses `lsappinfo` (a built-in macOS tool that
requires no special permissions) to check if your terminal is the frontmost
app. This has been tested on macOS with iTerm2. On Linux or other platforms,
system notifications are not sent — the in-terminal indicators still work.

## Configuration

amux stores state in `~/.amux/`. The tmux session name defaults to `amux` —
override with `AMUX_SESSION=myname amux`.

Pane titles are auto-generated from the working directory and git branch:
`project-name/feature-branch`. Override with `amux new "custom name"`.

## Requirements

- **tmux HEAD** — required for flicker-free rendering. `make setup` checks
  your version and provides install instructions. See
  [PR #4744](https://github.com/tmux/tmux/pull/4744) for details.
- **Rust** — for building from source. Install from [rustup.rs](https://rustup.rs).
- **macOS or Linux** — uses libc for raw terminal I/O in picker UIs.

## Development

See [docs/development.md](docs/development.md) for the full contributor
guide. Quick reference:

```bash
make dev       # Build — live on next keypress
make test      # Run tests
make refresh   # Re-apply tmux config after changing config.rs
make check     # Build + test
```

## Architecture

```
src/
├── main.rs      CLI entry point, zoom state machine, picker UIs
├── alert.rs     Pure alert decision logic (smart landing, counting)
├── notify.rs    macOS notification sending, frontmost-app detection
├── config.rs    tmux styles, borders, key bindings, status bar
├── layout.rs    Grid position calculator, tmux layout string generator
├── sticky.rs    Spatial matching algorithm, pane center tracking
├── tmux.rs      tmux command wrappers (sessions, panes, layout, zoom)
├── state.rs     State persistence (JSON to ~/.amux/)
├── util.rs      Auto-title generation (project name + git branch)
└── lib.rs       Public module exports, constants
```

See [docs/architecture.md](docs/architecture.md) for deep technical details
and [docs/attention-management.md](docs/attention-management.md) for the
attention system design.
