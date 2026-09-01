# Session restore — implementation plan

Design source: `~/.amux/session-restore-spec.md` (approved by Brian 2026-09-01, not
re-litigated here). This plan translates it into ordered, TDD-able tasks.

## Files

New in `app/Sources/AmuxLib/`:

| File | Contents | Purity |
|---|---|---|
| `AtomicFile.swift` | `AtomicFile.write(_:to:)` — temp file + `replaceItemAt`, extracted from `AmuxState.save` | shell |
| `SessionSnapshot.swift` | `SessionSnapshot` / `SpaceSnapshot` / `PaneSnapshot` / `PaneKind` / `IDConfidence`, `RestorePrefs`, load/save, `defaultPath` | model |
| `ClaudeSession.swift` | pure `resolveSessionIDs`, plus `slugFor`, `resumeArgID`, `parseLstart`, `firstTimestamp` parsers | core |
| `ClaudeScan.swift` | `ps`/`pgrep` walk + `~/.claude/projects` transcript reads producing the pure inputs | shell |
| `SnapshotCapture.swift` | pure `buildSnapshot(...)`; shell `captureSnapshot(cleanExit:)`; debounce marker | core + shell |
| `RestorePlan.swift` | pure `planRestore(snapshot:existing:) -> RestorePlan`, pure `shouldOfferRestore(...)` | core |
| `SessionRestoreTests.swift`, `ClaudeSessionTests.swift`, `RestorePlanTests.swift` | unit suites (`runAll()`) | tests |

Touched: `State.swift` (use `AtomicFile`), `AppController.swift` (startup gate +
popup), `AmuxCLI/main.swift` (`snapshot`, `prompt restore`, trigger from `layout` /
`update-title`), `AmuxTerm/AppDelegate.swift` (terminate hook + test registration),
`app/Tests/main.swift` + `app/Tests/SessionRestoreTests.swift` (integration).

## Data model

```swift
SessionSnapshot { version, capturedAt, cleanExit, spaces: [SpaceSnapshot], backlog: [String] }
SpaceSnapshot   { name, panes: [PaneSnapshot], selectedPane: Int }
PaneSnapshot    { index, cwd, title, kind: PaneKind }
PaneKind        = .claude(sessionID: String?, confidence: IDConfidence) | .shell | .command(String)
IDConfidence    = .resumeArg | .startTime | .topicMatch | .none
```

`backlog` holds the names of the spaces that were parked (`@amux-state=background`),
so a backlog space is a normal `SpaceSnapshot` plus a name in that list.

Paths: snapshot `~/.amux/session-snapshot.json`; prefs `~/.amux/restore-prefs.json`
(`{ dontAsk: Bool, consumedCapturedAt: Date? }`). Prefs are separate because every
capture overwrites the snapshot and would otherwise wipe the opt-out.

## Tasks

1. **AtomicFile** — extract the temp-file + `replaceItemAt` write; `AmuxState.save`
   calls it. Test: write/overwrite round-trip, parent dir created.
2. **Snapshot model + persistence** — Codable, `load(from:)` returning nil on
   missing/corrupt, `save(to:)` via `AtomicFile`; `RestorePrefs` same shape.
   Tests: encode→decode equality across all `PaneKind` cases, corrupt file → nil.
3. **Claude id resolution (pure)** — `resolveSessionIDs(panes:transcripts:tolerance:)`.
   Order: `.resumeArg` (argv `--resume <uuid>`) → `.startTime` (|first transcript
   timestamp − process start| ≤ 300s, nearest wins) → `.topicMatch` (token overlap,
   unique assignment by elimination, ids already pinned are off the table) → `.none`.
   Tests: resume-arg wins over a nearer start-time; start-time inside/outside
   tolerance; two panes one dir get distinct ids by topic and are labelled
   `.topicMatch`; no candidate → `.none` (never a guess).
4. **Scan adapter** — `pgrep -P` 3 levels from `pane_pid`, `ps -o lstart=,command=`,
   transcript head read for the first `"timestamp"`, topic blob from summaries +
   first/last user message. Pure parsers unit-tested; process walk untested.
5. **Capture** — pure `buildSnapshot(panes:resolutions:backlog:cleanExit:capturedAt:)`;
   `amux-cli snapshot [--clean-exit]`; trailing-coalesce via a request-marker file
   (write marker, wait 500ms, proceed only if marker unchanged). Triggered from
   `amux-cli layout-changed` (pane-exited hook — split out from `layout` so a
   window drag, which fires `client-resized` continuously, does not capture) and
   `amux-cli update-title` (after-select-pane hook) as a detached child, and from
   `applicationWillTerminate` with `cleanExit = true`. No timer.
6. **Restore planning (pure)** — `planRestore` emits an ordered `[[String]]` tmux
   command list: `new-session -d -s NAME -c CWD` → per extra pane
   `select-layout tiled` then `split-window -c CWD` → `send-keys` launch command →
   final `select-layout tiled` → `select-pane` on `selectedPane`; backlog spaces get
   `set-option @amux-state background`. Spaces that already exist with panes are
   skipped and reported; the space amux just created for itself is adopted (its
   pane `cd`s to the saved cwd) since killing it would drop our client. Tests:
   re-tile precedes every split; splits target the previous pane so order is
   preserved; skip-existing; adopt-when-untouched; a `.claude` pane with no id
   sends no `--resume`; selected pane restored last.
7. **Prompt gating (pure)** — `shouldOfferRestore(sessionWasCreated:snapshot:prefs:)`;
   true only when freshly created + ≥1 pane + `capturedAt != consumedCapturedAt` +
   `!dontAsk`. Tests: one per gate.
8. **Prompt UI + wiring** — `amux-cli prompt restore SESSION` matching
   `runParkPrompt`'s raw-mode loop and style; shows pane/space counts, Claude topics,
   a `.topicMatch` marker, and a crash note when `cleanExit == false`; options
   Restore / Start fresh / Don't ask again. `AppController.startup()` launches the
   popup through `display-popup -E` when the gate passes; restoring stamps
   `consumedCapturedAt`.
9. **Integration test** (`app/Tests/`) — real tmux on an isolated socket: build a
   session with 2 panes at known cwds, capture, kill, restore, assert space/pane
   count, cwds, and that a re-run against the live session is a no-op. Register in
   `app/Tests/main.swift`.
10. **`make validate`**, then stage.

## Out of scope

Timer-based autosave, auto-restore, touching the python snapshot script or its
launchd job (retired manually by Brian after a real reboot restore).
