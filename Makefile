# amux — development workflow
#
# make setup    Full environment setup (idempotent, safe to re-run)
# make dev      Build release binary — live on next tmux keypress
# make test     Run tests (unit + integration)
# make check    Lint + test + build — pre-merge gate (safe: tests before release build)
# make fmt      Auto-format code
# make lint     Run clippy + format check
# make refresh  Re-apply tmux config (after changing format strings/keybindings)
# make clean    Remove build artifacts

# Detect main worktree (always first in porcelain output)
MAIN_WORKTREE := $(shell git worktree list --porcelain | head -1 | sed 's/^worktree //')
export CARGO_TARGET_DIR := $(MAIN_WORKTREE)/target

RELEASE_BIN := $(CARGO_TARGET_DIR)/release/amux
SYMLINK := $(HOME)/.cargo/bin/amux
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
SHORT_SHA := $(shell git rev-parse --short HEAD)

.PHONY: dev test check fmt lint refresh clean setup setup-rust setup-tmux setup-symlink setup-hook

# ── Build ──────────────────────────────────────────────

dev:
	@# Auto-fix symlink if missing or wrong
	@if [ ! -L "$(SYMLINK)" ] || [ "$$(readlink $(SYMLINK))" != "$(RELEASE_BIN)" ]; then \
		mkdir -p "$$(dirname $(SYMLINK))"; \
		if [ -f "$(SYMLINK)" ] && [ ! -L "$(SYMLINK)" ]; then \
			echo "  Backing up existing $(SYMLINK) to $(SYMLINK).bak"; \
			mv "$(SYMLINK)" "$(SYMLINK).bak"; \
		fi; \
		ln -sf "$(RELEASE_BIN)" "$(SYMLINK)"; \
		echo "✓ Symlink: $(SYMLINK) → $(RELEASE_BIN)"; \
	fi
	@# Back up previous binary for rollback (only available after 2+ builds)
	@if [ -f "$(RELEASE_BIN)" ]; then cp "$(RELEASE_BIN)" "$(RELEASE_BIN).prev"; fi
	cargo build --release
	@echo "✓ Built amux from $(BRANCH) ($(SHORT_SHA)) — live on next keypress"

test:
	cargo test

# check: pre-merge gate. Tests run against debug build (cargo test uses debug),
# so the live release binary is never touched until all checks pass.
# Skips tmux::tests (need live tmux session) — run 'make test' locally for those.
check: lint
	cargo test --lib -- --skip tmux::tests
	cargo test --test config_test --test alert_test --test bell_test --test sticky_test --test notify_test
	cargo build --release
	@echo "✓ All checks passed"

fmt:
	cargo fmt

lint:
	cargo fmt --check
	cargo clippy -- -D warnings

clean:
	cargo clean

# ── Setup ──────────────────────────────────────────────

setup: setup-rust setup-tmux
	@$(MAKE) dev
	@$(MAKE) setup-hook
	@echo ""
	@echo "✓ amux setup complete. Run 'amux' to start."

setup-rust:
	@command -v cargo >/dev/null 2>&1 || { \
		echo "✗ Rust not found. Install from https://rustup.rs"; \
		exit 1; \
	}
	@echo "✓ Rust toolchain found"

setup-tmux:
	@command -v tmux >/dev/null 2>&1 || { \
		echo "✗ tmux not found."; \
		echo "  macOS:  brew install tmux --HEAD"; \
		echo "  Linux:  git clone https://github.com/tmux/tmux.git && cd tmux && sh autogen.sh && ./configure && make && sudo make install"; \
		exit 1; \
	}
	@# Check for synchronized output support (tmux HEAD / 3.7+)
	@tmux_version=$$(tmux -V | sed 's/[^0-9.]//g'); \
	echo "  tmux version: $$tmux_version"; \
	case "$$tmux_version" in \
		3.[7-9]*|[4-9]*) echo "✓ tmux version is good" ;; \
		*) echo "⚠  tmux $$tmux_version may cause flickering with Claude Code."; \
		   echo "  Recommended: brew install tmux --HEAD (macOS) or build from source"; \
		   echo "  See: https://github.com/tmux/tmux/pull/4744" ;; \
	esac

setup-hook:
	@"$(RELEASE_BIN)" hook-install 2>&1 || true
	@echo "✓ Claude Code notification hook checked"

# ── Convenience ────────────────────────────────────────

refresh:
	amux refresh
