# Amux.app DMG Bundle

**Goal:** Create a self-contained Amux.app bundle in a DMG that includes amux (Rust), amux-app (Swift), and tmux — no Rust, Swift, Homebrew, or source builds needed by the end user.

**Architecture:**
```
Amux.app/Contents/
  Info.plist
  MacOS/
    amux-app    (main executable — Swift terminal)
    amux        (Rust CLI — tmux calls this via run-shell)
    tmux        (built from HEAD with static libevent/ncurses)
  Resources/
    LICENSE-tmux.txt
```

On first launch, amux-app:
1. Finds the bundled `amux` binary next to itself
2. Symlinks it to `~/.local/bin/amux` (so tmux's run-shell can find it)
3. Uses the bundled `tmux` binary (not system tmux)

## Tasks

### Task 1: Build script for tmux with static dependencies
### Task 2: Info.plist and app bundle structure
### Task 3: AppDelegate changes — use bundled binaries, first-run symlink
### Task 4: make dmg target
### Task 5: GETTING_STARTED.md update
### Task 6: Test the full flow
