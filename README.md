# amux

**The AI Multiplexer. The Attention Multiplexer.**

A workspace for running multiple AI coding agents in parallel — without
losing track of which ones need you.

![amux demo](https://github.com/byoungs/amux/releases/latest/download/demo.gif)

## The Problem

You're running four Claude Code sessions. One finishes a plan and needs
your review. Another hits a permission prompt. A third is still churning.
You're tabbing between iTerm splits, or scrolling through cmux, or checking
your custom UI — trying to figure out which agent needs you *right now*.

**The agents are fast. You've become the bottleneck.**

amux fixes this. Pane borders light up amber when an agent needs input.
You navigate directly to it, zoom in to read the output, handle it, zoom
back out. You never lose your place. You never miss a prompt.

## Install

### Download (macOS)

1. [**Download amux.dmg**](https://github.com/byoungs/amux/releases/latest/download/amux.dmg)
2. Open the DMG and drag **amux** to Applications
3. Launch amux from Applications (or Spotlight)

The app bundles everything — no dependencies, no Homebrew, no tmux install.

### Build from Source

```bash
git clone https://github.com/byoungs/amux.git
cd amux
make setup    # checks deps, builds, creates symlink
amux          # start a session
```

Requires Rust ([rustup.rs](https://rustup.rs)) and tmux HEAD (`brew install tmux --HEAD` on macOS).

## How to Use

### The Basics

Launch amux. You start with one pane. Open a terminal in it and start working.

| To do this | Press |
|------------|-------|
| **Create a new pane** | `Cmd-N` |
| **Navigate to next/previous pane** | `Cmd-]` / `Cmd-[` |
| **Jump to pane by number** | `Cmd-1` through `Cmd-9` |
| **Zoom in** (grid → full screen) | `Cmd-=` (or `Cmd-+`) |
| **Zoom out** (full screen → grid) | `Cmd--` |

That's enough to get started. Create a few panes, start Claude Code in
each one, and use `Cmd-]` / `Cmd-[` to bounce between them.

### Attention Management

This is the thing that makes amux different.

Every pane border tells you what's happening at a glance:

| Border Color | Meaning |
|-------------|---------|
| **Teal** (bright) | Active — you're focused here |
| **Amber** | Needs you — agent is waiting for input |
| **Dark** | Working — agent is busy, leave it alone |

When you're zoomed into one pane at full screen, a badge in the status bar
shows how many other panes need attention. When you leave the terminal
entirely, amux sends a single macOS notification to bring you back — no
per-agent spam.

### Zoom

amux has two zoom levels:

- **Working** — all panes visible in a grid. You can see everything, type
  in the active pane.
- **Full Screen** — one pane fills the terminal. For reading long output,
  reviewing plans, or pairing with a single agent.

`Cmd-=` zooms in. `Cmd--` zooms out. Simple.

When an agent returns a long plan or diff, it's unreadable crammed into a
grid cell. Hit `Cmd-=` to zoom in, read through it, then `Cmd--` to zoom
back out and see all your agents.

Pane cycling (`Cmd-]` / `Cmd-[`) works in both views. In full screen, the
view stays zoomed as you flip through panes — like swiping between cards.

### Spaces

Spaces are separate workspaces, each with their own grid of panes. Think
of them like desktops — you switch to a different desktop and everything on
the previous one stays exactly where you left it.

Use spaces to organize by project, by task type, or however makes sense
for your workflow. One space for the frontend agents, another for backend,
a third for CI/deployment.

| To do this | Press |
|------------|-------|
| **Open space picker** | `Cmd-P` (or `Cmd--` from grid) |
| **Send pane to another space** | `Cmd-S` |

The space picker shows which spaces have agents waiting for you, so you
know where to go next.

### Split View

Sometimes you need to see two panes side by side — comparing output,
reviewing a plan while editing, or watching two agents work on related
tasks.

`Cmd-L` starts a split view. Pick a second pane to pair with. You get a
dedicated two-up view while your grid stays in the background. `Cmd--`
exits back to the grid.

### Pane Layout

Panes arrange automatically in a balanced grid:

```
2 panes       3 panes       4 panes     5 panes        6 panes
+----+----+   +----+----+   +--+--+    +--+--+---+    +--+--+--+
|    |    |   |    | 2  |   |1 |2 |    |1 |2 |   |    |1 |2 |3 |
| 1  | 2  |   | 1  +----+   +--+--+    +--+--+ 5 |    +--+--+--+
|    |    |   |    | 3  |   |3 |4 |    |3 |4 |   |    |4 |5 |6 |
+----+----+   +----+----+   +--+--+    +--+--+---+    +--+--+--+
```

Panes stick to their positions. When you add a pane, existing panes stay
put and the new one fills the next slot. When you remove a pane, its
neighbor expands to fill the gap. No shuffling.

## Key Bindings

All bindings use `Cmd` in the amux app. If running in a terminal with
tmux directly, these are `Ctrl` keys.

### Navigate

| Key | Action |
|-----|--------|
| `Cmd-]` | Next pane (wraps around, works while zoomed) |
| `Cmd-[` | Previous pane (wraps around, works while zoomed) |
| `Cmd-1..9` | Jump directly to pane N |

### Focus

| Key | Action |
|-----|--------|
| `Cmd-=` | Zoom in (grid → full screen) |
| `Cmd--` | Zoom out (full screen → grid → spaces) |

### Organize

| Key | Action |
|-----|--------|
| `Cmd-N` | Create a new pane |
| `Cmd-P` | Space picker |
| `Cmd-S` | Send current pane to another space |
| `Cmd-L` | Split view (two panes side by side) |

## Commands

```
amux               Start or attach to a session
amux start         Start a new session
amux new [name]    Create a new pane (auto-names from cwd + git branch)
amux list          List all panes
amux spaces        Space picker
amux send          Send pane to another space
```

## How Attention Management Works

amux has two layers of attention tracking:

**In-terminal indicators** (all platforms): amber pane borders, status bar
badges, and space picker markers show which agents need you. These are
tmux styling driven by pane options — they work everywhere.

**System notifications** (macOS): when you leave the terminal — switch to
your browser, email, Slack — amux sends a single macOS notification to
bring you back. No popups while you're in the terminal. Rate-limited to
once per 30 seconds to prevent fatigue.

## Configuration

amux stores state in `~/.amux/`. The tmux session name defaults to `amux` —
override with `AMUX_SESSION=myname amux`.

Pane titles are auto-generated from the working directory and git branch:
`project-name/feature-branch`. Override with `amux new "custom name"`.

## Requirements

### amux.app (recommended)

- macOS 14+
- Everything else is bundled

### Building from source

- **tmux HEAD** — required for flicker-free rendering (`brew install tmux --HEAD`).
  See [tmux PR #4744](https://github.com/tmux/tmux/pull/4744).
- **Rust** — install from [rustup.rs](https://rustup.rs)
- macOS or Linux

## Development

```bash
make dev       # Build, kill+relaunch app, re-apply tmux config
make test      # Lint + fast tests + release build
make validate  # Full suite including tmux integration tests
make release   # Validate + build DMG
make publish   # Tag + push to GitHub releases
```

## Architecture

```
src/
  main.rs      CLI entry point, zoom state machine, picker UIs
  alert.rs     Pure alert decision logic (smart landing, counting)
  notify.rs    macOS notification sending, frontmost-app detection
  config.rs    tmux styles, borders, key bindings, status bar
  layout.rs    Grid position calculator, tmux layout string generator
  sticky.rs    Spatial matching algorithm, pane center tracking
  tmux.rs      tmux command wrappers (sessions, panes, layout, zoom)
  state.rs     State persistence (JSON to ~/.amux/)
  bell.rs      BEL character scanner for agent-done detection
  hooks.rs     Claude Code hook installation
  util.rs      Auto-title generation (project name + git branch)
```
