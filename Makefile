# amux — development workflow
#
# make dev       Build and launch the app in debug mode
# make test      Run unit tests (embedded in app binary)
# make validate  Full test suite: unit + tmux integration tests
# make refresh   Re-apply tmux config (after changing format strings/hooks)
# make release   Build and validate a release DMG
# make publish   Tag and publish to GitHub (requires gh, clean tree)
# make clean     Remove build artifacts

VERSION := 0.3.0

.PHONY: dev test validate refresh clean setup app app-dev app-test app-clean tmux-bundle dmg release publish

# ── Build ──────────────────────────────────────────────

dev: app-dev

# test: unit tests only (no tmux needed)
test: app-test

# validate: full test suite including tmux integration tests
validate: app-test
	cd app && swift run amux-integration-tests
	@echo "✓ Validation passed (unit + integration tests)"

clean:
	cd app && swift package clean
	rm -rf build/

# ── Setup ──────────────────────────────────────────────

setup: setup-tmux
	@echo ""
	@echo "✓ amux setup complete. Run 'make dev' to start."

setup-tmux:
	@command -v tmux >/dev/null 2>&1 || { \
		echo "✗ tmux not found."; \
		echo "  macOS:  brew install tmux --HEAD"; \
		exit 1; \
	}
	@tmux_version=$$(tmux -V | sed 's/[^0-9.]//g'); \
	echo "  tmux version: $$tmux_version"; \
	case "$$tmux_version" in \
		3.[7-9]*|[4-9]*) echo "✓ tmux version is good" ;; \
		*) echo "⚠  tmux $$tmux_version may cause flickering."; \
		   echo "  Recommended: brew install tmux --HEAD" ;; \
	esac

# ── Native App ──────────────────────────────────────────

app:
	cd app && swift build -c release
	@echo "Built amux-app — run: app/.build/release/amux-app"

SWIFT_BUILD_DIR := app/.build/arm64-apple-macosx/debug

app-dev:
	cd app && swift build
	@# Symlink amux-cli to ~/.local/bin so hooks can find it
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(CURDIR)/$(SWIFT_BUILD_DIR)/amux-cli $(HOME)/.local/bin/amux-cli
	$(SWIFT_BUILD_DIR)/amux-app

app-test:
	cd app && swift build
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

release: validate dmg
	@echo ""
	@echo "✓ amux v$(VERSION) release ready: build/amux.dmg"

publish:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "✗ Working tree is dirty — commit or stash changes first"; \
		exit 1; \
	fi
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
		echo "✗ Tag v$(VERSION) already exists"; \
		exit 1; \
	fi
	@$(MAKE) release
	@ASSETS="build/amux.dmg"; \
	git tag -a "v$(VERSION)" -m "v$(VERSION)"; \
	git push origin "v$(VERSION)"; \
	gh release create "v$(VERSION)" $$ASSETS --title "amux v$(VERSION)" --generate-notes
	@echo "✓ Published amux v$(VERSION) to GitHub"

# ── Convenience ────────────────────────────────────────

refresh:
	amux refresh
