# Permission Peek — Design

**Date:** 2026-05-26
**Status:** Proposed
**Worktree:** `peek-permissions`

## Problem

When several Claude panes run in parallel, each one periodically stops on a
permission prompt and waits. Today the only signal is the per-pane border
alert, which is driven by Claude Code's Notification hook (`Hooks.swift` →
`amux-cli alert-pane`). That hook is an unreliable, regression-prone signal:
when it silently stops firing, a thread sits blocked and you don't find out
until you go looking. The cost lands hardest when you're zoomed into one pane
reading at full size — the other threads are invisible, and a missed alert
means a stalled thread.

What you want: stay in your current pane, get a reliable indicator when a
*background* pane needs a yes/no, glance at the prompt, and answer it (or go
deal with it) without losing your place.

## Goal

A pane-content watcher that detects Claude permission prompts directly from
on-screen text, surfaces them in a bottom-right indicator, and lets you
answer or engage from a `Cmd-Y` popup without switching panes.

## Non-Goals

- Generic "idle / waiting on you" detection. Permission prompts have a
  distinctive box; idle-waiting has no on-screen marker. Permission-only
  first. (Long-term the watcher could subsume the existing border-alert
  feature, but that unification is out of scope here.)
- Replacing or modifying the existing Claude hook / border-alert path. It
  stays as-is; this feature is self-contained and additive.
- Remote *plain* "No." Every rejection routes through "engage" (see below).

## Key Decisions

### Watch the text, not the hook

Detection polls `tmux capture-pane` rather than trusting Claude Code's
notification.

- **Cost (accepted):** coupling to Claude's prompt-box *format*, which can
  change between versions.
- **Win (the bigger one):** the on-screen box is ground truth and is
  *user-verifiable*. If a prompt is on screen, a text scan sees it. Hook
  failures are invisible; format changes are not. This directly removes the
  "silently missed alert" failure mode that motivates the feature.

amux's terminal view only renders the *attached* tmux client's pane —
background panes' output is owned by tmux, not visible to the app. So
"watch the text" concretely means the app **polls** `capture-pane`; there is
no passive stream available for background panes.

### `capture-pane` over streaming (considered alternatives)

`capture-pane` is the right *read* primitive because we need rendered screen
state ("is the box on screen now?"), not a byte stream:

- **`tmux pipe-pane`** streams a pane's *raw output* (ANSI escapes, cursor
  moves, redraws). Reconstructing current rendered state from it means running
  a full VT emulator per background pane — reimplementing `capture-pane`.
- **tmux control mode (`-CC`)** `%output` is also raw bytes per pane (same
  reconstruction problem), and is a persistent-protocol shift away from the
  shell-out-per-command `TmuxExecutor` model. Overkill.
- **Substring-scanning the raw stream** (like `Bell.swift` does for BEL) is
  fragile: prompt text interleaves with escape codes and splits across
  redraws/wraps, so it isn't reliably contiguous. Rendered capture sidesteps
  this.

### Poll interval: 4s

A prompt sits on screen until answered, so detection latency only needs to
beat your attention while you're heads-down in another thread, not feel
instant. **Default 4s** (3-5s range), easy to tune. Two consequences:

- **Answer latency is independent of poll interval.** Answering `1`/`2`
  optimistically drops the prompt from the in-memory queue and advances
  immediately; the queue already holds other pending prompts from prior polls.
  The interval only governs how fast a *new* prompt is *noticed*.
- At 4s × a handful of panes, capture cost is negligible — this removes any
  need for an event-driven (tmux `monitor-activity` hook) capture
  optimization. Blind timer poll is the whole story.

### Faithful option set + engage on the reject option

The popup renders Claude's actual options **verbatim**, parsed from the pane —
never a hardcoded set. Option count/labels vary (2-option `Yes`/`No`,
3-option `Yes` / `Yes, and don't ask again…` / `No`); the popup shows exactly
what is on screen. (Confirmed against real captures, Task 1 — see
`permission-peek-sendkeys-notes.md`.)

Selection mirrors Claude's own UI: press the option's **digit**, or move a
highlight with **arrow keys + Enter**. Resolving to an option sends that
option's key to the pane (a bare digit selects AND confirms — verified, no
trailing Enter).

- **Answer-in-place options** — every option except the reject (i.e. `Yes`,
  `Yes, and don't ask again`): `send-keys` the option's digit to the pane,
  advance the queue, stay in your current pane. The "don't ask again" option
  is the lever that actually reduces future prompts (inline `/learn`).
- **The reject option** (the last option — `No`): **engage**. Full-screen the
  pane (switch the client to that session + zoom) and send its key there, so
  you land in the session with Claude awaiting "what should I do instead?"
  and type the follow-up live. Identified as the **last** option (Claude
  always lists `No` last) → count-agnostic, not a hardcoded slot.
- **`Esc`** — dismiss the whole queue to background; nothing answered;
  indicator stays lit.

Why engage on reject rather than answer it in place: a plain `No` leaves
Claude waiting for your typed instruction. Answering it remotely would strand
that session waiting on input you are not there to give. So rejecting = "take
me there."

**Spike correction (Task 1):** the earlier draft assumed option 3 was "No,
and tell Claude what to do differently" (requiring typed feedback, hence
engage). Claude Code 2.1.150 shows a plain `No`. The engage-on-reject behavior
is kept, but justified by the stranding problem above and keyed off the
last/reject option, not a fixed slot or that wording.

### FIFO, one at a time

- Bottom-right count badge when ≥1 background pane has a pending prompt.
- `Cmd-Y` opens the popup showing the **oldest** pending prompt only.
- Answering `1`/`2` clears it and **advances** to the next oldest (rip through
  yes/yes/yes); popup closes when the queue empties.
- `3` engages and closes the popup.
- `Esc` dismisses the whole queue to background; indicator stays lit; `Cmd-Y`
  re-opens to the same queue.
- The focused pane is excluded from the queue (you see it directly).

### Always-on

Watcher and indicator are active whenever any background pane has a pending
prompt, zoomed or not. Simpler than gating on zoom, and useful in multi-pane
view too.

### `Cmd-Y`

`Cmd-P` is taken (`spaces`). `Cmd-Y` is free and mnemonic for the yes/no
prompt.

## Architecture

Functional core + imperative shell, matching the codebase convention
(`LayoutEngine` is the model: pure state machine, `FakeTmux` for tests).

- **Detector (pure, AmuxLib):** `detectPermissionPrompt(text) -> Prompt?`.
  Parses captured pane text into a `Prompt { question, options: [Option] }`
  or nil. No tmux. Tested against captured fixtures. Anchors on the box
  border + "Do you want to proceed?" + numbered options so it never fires on
  chat text that merely quotes a prompt.
- **Queue (pure, AmuxLib):** state machine over per-pane detector results.
  Computes `none → prompt` / `prompt → none` transitions, maintains FIFO
  order, exposes `current`, `advance`, `dismissAll`. No tmux.
- **Watcher (shell, app):** timer (4s) that lists managed panes, calls
  `capture-pane -p -t %id -S -25` for each (excluding the focused pane),
  feeds text to the detector, drives the queue, updates UI.
- **Answerer (shell, app):** `tmux send-keys -t %id` for `1`/`2`; pane
  select/zoom for `3` (engage).
- **UI (app, AmuxTerm):** bottom-right count badge overlay + `Cmd-Y` popup
  overlay drawn over the terminal view. New `AmuxCommand` case + `KeyCommand`
  mapping for `Cmd-Y`.

## Risks — spikes RESOLVED (Task 1, 2026-05-26)

Full results in `permission-peek-sendkeys-notes.md`; fixtures in
`app/Tests/Fixtures/`.

1. **Box fixture — DONE.** Real `capture-pane` captures committed:
   `permission-bash.txt` (2-option) and `permission-bash-3opt.txt`
   (3-option). The box has **no box-drawing glyphs** (color-rendered), so
   capture yields space-indented text; glyph is `❯`; question is
   `Do you want to proceed?`. (Edit/MCP variants not capturable in this env —
   Write is allowlisted, MCP needs a server — Bash fixtures suffice for v1.)
2. **Keystroke mechanism — DONE.** A **bare digit selects AND confirms** (no
   Enter). Verified `1` (ran) and `3` (interrupted). `answerKeys = ["<n>"]`.
3. **False-positive anchoring — to confirm in Task 2** against the committed
   fixtures: anchors = ≥2 numbered options + one label starts with "Yes" + a
   preceding line ending in "?". Negative test: ordinary chat numbered lists.

## Open Questions

- Poll interval set at 4s (see Key Decisions); revisit only if a real
  workload shows it too slow or too costly.
- Badge styling / exact placement within the terminal overlay — defer to
  implementation.
- Behavior if a prompt is answered *in* its session while queued — the next
  poll detects `prompt → none` and drops it from the queue; popup reconciles
  on advance.
