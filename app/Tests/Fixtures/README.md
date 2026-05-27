# Permission-prompt fixtures

Real `tmux capture-pane -p -J` captures of Claude Code permission prompts,
used to test `detectPermissionPrompt` (`AmuxLib/PermissionPrompt.swift`)
against ground truth instead of guessed formats.

| File | What it is |
|------|------------|
| `permission-bash.txt` | 2-option Bash prompt (`1. Yes` / `2. No`), forced via a `permissions.ask` rule |
| `permission-bash-3opt.txt` | 3-option Bash prompt (`1. Yes` / `2. Yes, and don't ask again…` / `3. No`) |
| `permission-bash-narrow.txt` | 3-option prompt in a narrow (64-col) pane — option 2's long "don't ask again for" pattern wraps into a right-hand column across rows. Exercises the detector's multi-row option handling against real `-J` output. |

Captured with `tools/capture-permission-prompt.sh` against Claude Code 2.1.150
(narrow fixture: 2.1.152, started at `-x 64`).
See `docs/superpowers/specs/2026-05-26-permission-peek-sendkeys-notes.md` for
the full findings (selection glyph, answer mechanism, format details).

To regenerate, run the harness (it isolates on a dedicated tmux socket so it
never touches a running amux) and re-`capto` into this directory.
