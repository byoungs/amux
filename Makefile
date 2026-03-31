# amux — development workflow
#
# make setup    Full environment setup (idempotent, safe to re-run)
# make dev      Build release binary — live on next tmux keypress
# make test     Lint + fast tests + release build — runs anywhere, no tmux needed
# make validate Full test suite including tmux integration tests (parallel-safe)
# make fmt      Auto-format code
# make lint     Run clippy + format check
# make refresh  Re-apply tmux config (after changing format strings/keybindings)
# make release  Build and validate a release DMG
# make publish  Tag and publish to GitHub (requires gh, clean tree)
# make demo     Record the demo GIF (requires vhs, Pillow)
# make clean    Remove build artifacts

# Detect main worktree (always first in porcelain output)
MAIN_WORKTREE := $(shell git worktree list --porcelain | head -1 | sed 's/^worktree //')
export CARGO_TARGET_DIR := $(MAIN_WORKTREE)/target

RELEASE_BIN := $(CARGO_TARGET_DIR)/release/amux
SYMLINK := $(HOME)/.cargo/bin/amux
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
SHORT_SHA := $(shell git rev-parse --short HEAD)
VERSION := $(shell awk -F'"' '/^\[package\]/{p=1} p && /^version/{print $$2; exit}' Cargo.toml)

.PHONY: dev test validate fmt lint refresh clean setup setup-rust setup-tmux setup-hook app app-dev app-test app-clean tmux-bundle dmg release publish demo

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

# test: lint + fast tests + release build. Runs anywhere, no tmux needed.
# Tests run against debug build (cargo test uses debug), so the live
# release binary is never touched until all checks pass.
test: lint
	cargo test --lib -- --skip tmux::tests
	cargo test --test config_test --test alert_test --test bell_test --test sticky_test --test notify_test
	cargo build --release
	@echo "✓ Tests passed"

# validate: full test suite including tmux integration tests.
# Tests use unique session names (amux-test-*) so they run in parallel
# without colliding with each other or your live amux sessions.
# Clean first to avoid stale test binaries from shared CARGO_TARGET_DIR.
validate:
	cargo clean -p amux
	cargo test
	@echo "✓ Validation passed (all tests including tmux integration)"

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

# -- Native App ------------------------------------------------

app:
	cd app && swift build -c release
	@echo "Built amux-app -- run: app/.build/release/amux-app"

app-dev:
	cd app && swift build
	app/.build/debug/amux-app

app-test: app-dev
	app/.build/debug/amux-app --run-tests

app-clean:
	cd app && swift package clean

# Build tmux from HEAD with static deps (for bundling)
tmux-bundle:
	./scripts/build-tmux.sh

# Create amux.app bundle and DMG installer
dmg: app tmux-bundle
	@echo "=== Creating amux.app bundle ==="
	rm -rf build/amux.app build/dmg-staging
	mkdir -p build/amux.app/Contents/MacOS
	mkdir -p build/amux.app/Contents/Resources
	cp app/Resources/Info.plist build/amux.app/Contents/
	cp app/.build/release/amux-app build/amux.app/Contents/MacOS/
	cp $(RELEASE_BIN) build/amux.app/Contents/MacOS/amux
	cp build/tmux-bundle/tmux build/amux.app/Contents/MacOS/
	cp build/tmux-bundle/LICENSE-tmux.txt build/amux.app/Contents/Resources/
	cp app/Resources/amux.icns build/amux.app/Contents/Resources/
	@echo "=== Creating DMG ==="
	mkdir -p build/dmg-staging
	cp -R build/amux.app build/dmg-staging/
	ln -s /Applications build/dmg-staging/Applications
	hdiutil create -volname "amux" -srcfolder build/dmg-staging -ov -format UDZO build/amux.dmg
	rm -rf build/dmg-staging
	@echo "✓ DMG created: build/amux.dmg"

# ── Release ────────────────────────────────────────────

# Build a release-ready DMG after full validation
release: validate dmg
	@echo ""
	@echo "✓ amux v$(VERSION) release ready: build/amux.dmg"

# Tag and publish to GitHub (requires gh CLI, clean tree)
publish:
	@if [ -z "$(VERSION)" ]; then \
		echo "✗ Could not extract version from Cargo.toml"; \
		exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "✗ Working tree is dirty — commit or stash changes first"; \
		exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "✗ Tag v$(VERSION) already exists — bump version in Cargo.toml first"; \
		exit 1; \
	fi
	@$(MAKE) release
	@ASSETS="build/amux.dmg"; \
	if [ -f demo/demo.gif ]; then \
		ASSETS="$$ASSETS demo/demo.gif"; \
	else \
		echo "⚠  demo/demo.gif not found — run 'make demo' to include it in the release"; \
		printf "Publish without demo GIF? [y/N] "; \
		read -r ans; \
		if [ "$$ans" != "y" ]; then echo "Aborted."; exit 1; fi; \
	fi; \
	git tag -a "v$(VERSION)" -m "v$(VERSION)"; \
	git push origin "v$(VERSION)"; \
	gh release create "v$(VERSION)" $$ASSETS --title "amux v$(VERSION)" --generate-notes; \
	gh release delete-asset "v$(VERSION)" "amux-$(VERSION).tar.gz" --yes 2>/dev/null; \
	gh release delete-asset "v$(VERSION)" "amux-$(VERSION).zip" --yes 2>/dev/null
	@echo "✓ Published amux v$(VERSION) to GitHub"

# ── Demo ──────────────────────────────────────────────

# Record the demo GIF (requires vhs and Pillow)
demo:
	bash demo/setup.sh
	vhs -o demo/demo-raw.gif demo/demo.tape
	python3 demo/overlay.py demo/demo-raw.gif demo/demo.gif
	rm -f demo/demo-raw.gif
	@echo "✓ Demo GIF: demo/demo.gif"

# ── Convenience ────────────────────────────────────────

refresh:
	amux refresh
