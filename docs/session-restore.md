# Session restore

tmux processes die when the machine reboots, but every Claude conversation is
on disk under `~/.claude/projects/<slug>/<session-id>.jsonl`. amux records what
was open while it runs, and on a cold start offers to bring it back.

## What is recorded

`~/.amux/session-snapshot.json`, written by `SnapshotCapture`:

```
SessionSnapshot { version, captured_at, clean_exit, spaces[], backlog[] }
SpaceSnapshot   { name, panes[], selected_pane, parked_from }
PaneSnapshot    { index, cwd, title, kind }
PaneKind        = claude(session_id, confidence) | shell | command(cmd)
```

`backlog` names the spaces that were parked. `clean_exit` is true only when
`applicationWillTerminate` wrote the snapshot — anything else means the last
run died, which the restore prompt says out loud, because a crash snapshot can
be slightly behind what was on screen.

State lives in a separate file from `~/.amux/state.json` (window labels, view
mode) on purpose: different concern, different lifetime.

`~/.amux/restore-prefs.json` holds the user's answers — `dont_ask`, and the
`captured_at` already consumed so the same snapshot is never offered twice.
It is separate from the snapshot because every capture rewrites the snapshot.

## When it captures

Event-driven, never timed:

- **pane added / closed** — the `pane-exited` hook runs `amux-cli layout-changed`
- **pane focus change** — the `after-select-pane` hook runs `amux-cli update-title`
- **clean exit** — `applicationWillTerminate`, with `clean_exit = true`

`client-resized` deliberately does *not* capture; it fires continuously while a
window is dragged.

Both hooks spawn `amux-cli snapshot`, which stamps `~/.amux/snapshot-request`
with a token, waits 500 ms, and captures only if no later event replaced it —
so a burst of focus changes produces one write, of the state the user left.

**The known gap:** typing `claude` into an existing shell pane is not a pane
event, so a crash before the next focus change loses that id. Hooking focus
(not just add/close) closes most of it. There is no autosave timer by design.

## Resolving Claude session ids

`ClaudeSession.resolveSessionIDs` is pure — process samples and transcript
metadata in, ids out — with `ClaudeScan` doing the `ps`/`pgrep`/file reads.
Three signals, most trustworthy first:

| Confidence | Signal |
|---|---|
| `resume_arg` | the process argv is `claude --resume <uuid>` |
| `start_time` | the transcript's first timestamp is within 300 s of the process start |
| `topic_match` | word overlap between pane title and transcript topic, assigned uniquely |
| `none` | nothing convincing — restore opens a shell and prints the topic |

Candidate transcripts for a pane come from its own project dir **and any dir
nested inside it**: a pane usually sits in the repo root while Claude runs in a
worktree below it, and Claude files the transcript under the worktree's slug.
A sibling that merely shares a name prefix (`…-amux2` vs `…-amux`) is excluded.
Without this, a pane running an amux worktree session resolved to no id at all.

Reading is two-phase, because capture runs on every focus change and one
project dir here holds 423 MB across 32 transcripts:

1. **cheap** — 16 KB head per transcript, enough for the first timestamp, which
   is all `.resumeArg` and `.startTime` need.
2. **only if a Claude pane is still unresolved** — 256 KB head + 64 KB tail for
   topic text, and only for that pane's project dir.

A full capture of a live 4-pane session measures ~0.7 s wall, ~0.07 s CPU — the
cost is `ps`/`pgrep` spawns, not file reads, and it happens in a short-lived
`amux-cli` process, never on the app's main thread.

Facts that cost a session to learn (verified 2026-09-01):

- The project slug is the cwd with every non-alphanumeric character → `-`.
- Claude does not hold the transcript open; `lsof` finds nothing.
- No session id in the environment, and none in argv unless it was resumed.
- A pane at Claude's "resume from summary?" prompt still reports its *shell*
  as `pane_current_command` — the process scan decides, not the pane command.
- Transcript mtimes are not a recency signal (a bulk touch can restamp old
  files); the timestamps inside the file are.

A wrong id resumes the wrong conversation, so the resolver never falls back to
"newest transcript in the directory" the way the older python script did, and
`topic_match` panes are flagged in the prompt before anything is resumed.

## The prompt

Offered only when **all** hold: no amux-managed tmux session survived, a
snapshot with at least one pane exists, that snapshot was not already consumed,
and "don't ask again" is unset (`SessionRestore.shouldOfferRestore`).

It is a `display-popup` running `amux-cli prompt restore`, armed by a one-shot
`client-attached` hook — at `startup()` time the app's PTY has not attached yet
and a popup would have no client.

```
  Restore your last session?   (last run ended in a crash)

  amux
    · scroll reflow    claude
    · shell            shell
  parked-fix (backlog)
    · fix              claude [topic match — verify]

  ❯ 1. Restore 3 panes across 2 spaces  saved 12m ago
    2. Start fresh
    3. Don't ask again
```

## Restoring

`SessionRestore.planRestore` is pure: snapshot + live pane counts → an ordered
tmux command list. Two rules it exists to enforce:

- **Re-tile before every split.** tmux refuses `split-window` with "no space for
  a new pane" once the default halving leaves the target too short (hit live at
  the 6th pane).
- **Split the pane just created (`-t sess:0.<n-1>`), not the window.** tmux
  inserts the new pane immediately after the target, and detached splits leave
  pane 0 active — splitting the window reverses the saved order.

Then: the space amux just created for itself is *adopted* (its single pane
`cd`s to the saved cwd) rather than skipped, since killing it would drop our
own client; spaces that already have panes are skipped and reported; backlog
spaces are re-parked; focus is restored last.

A Claude pane resumes with `claude --resume <id>`. With no id it gets a shell
at the right cwd and a printed hint — never a guess.

## Testing it, including the prompt

Nothing here needs a human at a keyboard.

| Layer | Where |
|---|---|
| id resolution, planning, gating | `ClaudeSessionTests`, `RestorePlanTests` (pure, no tmux) |
| startup arms the prompt hook | `AppControllerTests` against `FakeTmux` |
| capture + restore against real tmux | `app/Tests/SessionRestoreTests.swift` |
| the prompt itself, keystroke by keystroke | `app/Tests/RestorePromptUITests.swift` |

The prompt tests run the real `amux-cli prompt restore` in a real tmux pane,
read the screen back with `capture-pane`, send keys, and assert what tmux and
the prefs file look like afterwards (`PromptHarness`). Two seams make that safe
and possible:

- **`AMUX_HOME`** moves every amux state file (snapshot, prefs, coalescing
  marker) into a scratch directory. All paths resolve through `AmuxPaths`, so
  the override cannot half-apply and leak into the real `~/.amux`.
- **`$TMUX`** decides which tmux server `amux-cli` talks to (`TmuxSocket`).
  Inside a pane that is the server that spawned it — the isolated test server
  during tests, the user's own server in production.

`AppController.snapshotPath` / `.restorePrefsPath` are injectable for the same
reason, so the startup gate can be driven without touching real state.

Both tmux behaviours above (split ordering, trailing empty format field) have
regression tests that were confirmed to fail when the fix is reverted.
