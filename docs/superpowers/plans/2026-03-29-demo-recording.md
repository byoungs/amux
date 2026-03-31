# Demo Recording — Implementation Plan

**Goal:** Produce a polished demo GIF for the README using VHS, with
realistic AI agent content and no human in the loop.

**Spec:** `docs/superpowers/specs/2026-03-29-demo-recording-design.md`

---

### Task 1: Create demo-setup.sh

Write `docs/demo-setup.sh` that creates a tmux session `amux-demo` with:

- 4 panes with realistic titles: `myapp/auth-refactor`, `myapp/test-suite`,
  `myapp/main`, `myapp/deploy`
- Pane 1: completed plan output using heredoc with ANSI colors — structured
  headers, bullets, file paths. No visible commands. Use `clear` then
  `cat <<'EOF'` so only the content shows.
- Pane 2: empty for now (streaming script fills it during recording)
- Pane 3: permission prompt — "I'd like to edit these files:" with file
  list and "Allow? (y/n)" waiting
- Pane 4: shell prompt with recent `git status` output showing a few
  modified files
- Alert flags on panes 0 and 2, alert count = 2
- Pane 3 selected as active (index 3, the "deploy" pane)
- `@amux-level` set to 2 (working grid)

Apply amux config via `amux refresh`.

**Validation:** Run the script, then `tmux capture-pane -t amux-demo:0.0 -p`
and verify plan content is visible with no echo artifacts.

- [ ] Script creates session with 4 titled panes
- [ ] Pane content is realistic, no visible commands
- [ ] Alerts set correctly
- [ ] `tmux capture-pane` validation passes

### Task 2: Create demo-driver.sh

Write `docs/demo-driver.sh` that drives the demo beats via amux CLI:

```
sleep 5      # Beat 1: grid sits (includes 2s attach time)
amux zoom 0  # Beat 2: jump to alert
sleep 3
amux zoom-in # Beat 3: zoom in to read plan
sleep 4
amux zoom-out # Beat 4: zoom out
sleep 3
amux pane-next # Beat 5: cycle
sleep 1.5
amux pane-next
sleep 2
amux zoom-in  # Beat 6: zoom in on permission prompt
sleep 3
amux zoom-out
sleep 2
              # Beat 7: end card (3s, handled by VHS duration)
```

All commands use `AMUX_SESSION=amux-demo`.

**Validation:** Run setup, then driver manually, verify transitions with
`tmux display-message -t amux-demo -p '#{window_zoomed_flag}'` at each step.

- [ ] Driver script runs without errors
- [ ] Zoom transitions verified via tmux queries

### Task 3: Create demo-streaming.sh

Write `docs/demo-streaming.sh` — a background script that runs in pane 2
during recording, outputting test-like content line by line:

```
Running tests...

  ✓ auth/login validates credentials (12ms)
  ✓ auth/login rejects expired tokens (3ms)
  ✓ auth/refresh rotates token pair (8ms)
  ✓ auth/middleware blocks unsigned requests (2ms)
  ✗ auth/session concurrent limit exceeded (45ms)
    Expected: max 3 sessions
    Received: 4 sessions active

  7/12 passed, 1 failed...
```

Use `sleep` between lines (0.3-0.8s) to simulate streaming. Use ANSI
colors (green for ✓, red for ✗). Total runtime should match the driver
duration (~25s). The setup script starts this in pane 2 as a background
process.

**Validation:** Run the script in a terminal, verify colored output
streams at a readable pace.

- [ ] Output looks like realistic test results
- [ ] Timing spans ~25 seconds
- [ ] ANSI colors render correctly

### Task 4: Create demo.tape

Write `docs/demo.tape` — the VHS tape file:

```
Set Width 1200
Set Height 800
Set FontSize 13
Set Shell "bash"
Set TypingSpeed 0

Hide
Type "bash docs/demo-streaming.sh | tmux send-keys -t amux-demo:0.1 &"
...
Type "bash docs/demo-driver.sh &"
Enter
Sleep 0.5s
Type "AMUX_SESSION=amux-demo amux attach"
Enter
Sleep 2s
Show

Sleep 26s
```

Actual streaming approach TBD — may need to start the streaming script
in the setup phase instead and have it sleep-wait for a signal.

**Validation:** Run `vhs -o /tmp/demo-test.gif docs/demo.tape`, then
read the GIF and verify visually.

- [ ] VHS produces a GIF without errors
- [ ] GIF shows 4-pane grid with alerts
- [ ] Transitions (zoom, navigate) are visible
- [ ] No setup artifacts visible

### Task 5: Iterate on visual quality

Read the GIF output and check:

1. Are the amber alert borders visible?
2. Is the plan content readable when zoomed?
3. Does the streaming pane show motion?
4. Are pane titles realistic?
5. Is the status bar visible with alert badge?
6. Is the timing good (not too fast, not too slow)?

Adjust setup/driver/tape/font-size as needed. Re-run VHS after each change.

- [ ] All 6 visual checks pass
- [ ] Final GIF is under 2MB for README embedding

### Task 6: Integrate into README and clean up

1. Copy final GIF to `docs/demo.gif`
2. Update `README.md` to reference `docs/demo.gif` (already has placeholder)
3. Remove `docs/record-demo.sh` (replaced by VHS approach)
4. Ensure `demo.tape`, `demo-setup.sh`, `demo-driver.sh`, `demo-streaming.sh`
   are checked in for reproducibility

- [ ] README shows the GIF
- [ ] Old recording script removed
- [ ] All demo files checked in
