# Development Guide

## Setup

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

1. **Rust toolchain** — verifies `cargo` is on PATH
2. **tmux** — checks version, warns if tmux HEAD is needed for flicker-free rendering
3. **Build** — compiles the release binary
4. **Symlink** — links `~/.cargo/bin/amux` to the built binary
5. **Claude Code hook** — installs the notification hook in `~/.claude/settings.json`

If you move the repo directory, re-run `make setup` to update the symlink.

## How Live Reload Works

amux has no long-running daemon. tmux key bindings and hooks shell out to
the `amux` binary on every invocation (`run-shell "amux zoom-in"`, etc.).
The binary at `~/.cargo/bin/amux` is a symlink to `target/release/amux`.

This means: run `make dev`, and the next keypress in tmux uses the new code.
No restart, no refresh, no reconnect.

**Exception:** tmux caches configuration strings (border formats, status bar,
key bindings). If you change these in `src/config.rs`, run `make refresh`
to re-apply them.

## Worktree Development

All changes happen on branches in git worktrees. Main stays clean.

### Create a worktree

```bash
git worktree add -b fix-alert-dismiss .worktrees/fix-alert-dismiss main
cd .worktrees/fix-alert-dismiss
```

### Develop

```bash
# Edit code...
make dev      # Build — live on next keypress
make test     # Run tests
make refresh  # Only if you changed config strings
```

All worktrees share a single `target/` directory (the main checkout's).
Cargo serializes concurrent builds via file lock — no corruption risk.
The last `make dev` wins; it prints the branch and commit so you know
what's running.

### Complete and merge

```bash
# Squash work into a single commit on the branch
# Rebase onto current main (needed if other branches merged since you branched)
git rebase main

# From the main checkout:
cd ~/src/amux   # or wherever your main checkout lives
git merge --ff-only fix-alert-dismiss
make dev
git worktree remove .worktrees/fix-alert-dismiss
git branch -d fix-alert-dismiss
```

## Rollback

If a bad build breaks tmux key bindings:

```bash
# Option 1: rebuild from main
cd ~/src/amux
git checkout main
make dev

# Option 2: restore previous binary (available after 2+ builds)
cp target/release/amux.prev target/release/amux
```

`make dev` saves the previous binary as `target/release/amux.prev` before
each build.

## Make Targets

| Target | What it does |
|--------|-------------|
| `make setup` | Full environment setup (idempotent) |
| `make dev` | Build release binary — live on next keypress |
| `make test` | Run all tests (unit + integration) |
| `make check` | Lint + test + build — pre-merge gate |
| `make fmt` | Auto-format code |
| `make lint` | clippy + format check |
| `make refresh` | Re-apply tmux config |
| `make clean` | Remove build artifacts |
