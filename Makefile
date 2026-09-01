# amux — development workflow
#
# make dev       Build and launch the app in debug mode
# make test      Run unit tests (embedded in app binary)
# make validate  Full test suite: unit + tmux integration tests
# make release   Build and validate a release DMG
# make publish   Tag and publish to GitHub (requires gh, clean tree)
# make clean     Remove build artifacts

VERSION := 0.3.0

.PHONY: dev test validate clean setup app app-dev app-test app-clean tmux-bundle dmg release publish

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
DEV_APP := build/amux-dev.app

# Assemble the dev .app bundle. Standalone target so integration tests
# can invoke it. UNUserNotificationCenter requires Bundle.main to resolve
# to the .app bundle (for Info.plist's CFBundleIdentifier). On macOS 15.7+
# UN asserts "bundleProxyForCurrentProcess is nil" and aborts if it can't;
# older OSes silently dropped posts. Either way, the bundle must be real.
#
# The executable is COPIED (not symlinked) because dyld resolves the
# executable path via its symlink before computing Bundle.main — a symlink
# into .build/ makes mainBundle.bundleURL point at .build/..., not the
# .app, so Info.plist is never found.
#
# The dev bundle uses a separate bundle ID (com.byoungs.amux.dev) from the
# release (com.byoungs.amux) for two reasons:
#   1. macOS keeps UNUserNotification auth state keyed by bundle ID. If a
#      developer ever denied the release app's permission prompt, the dev
#      bundle inherits that denial forever and requestAuthorization returns
#      UNErrorCode 1 without re-prompting. Separate IDs give dev its own
#      permission decision, independent of release.
#   2. Installed release and dev can coexist without clobbering each other.
#
# Code signing uses the same --identifier as the bundle ID. Without this,
# adhoc signing uses "amux-app-<hash>" which macOS treats as a distinct
# identity from the bundle and some subsystems (SecTrust, LS) get confused.
#
# DEV_APP can be overridden per-invocation (tests use a temp path).
build-dev-bundle:
	cd app && swift build
	@mkdir -p $(DEV_APP)/Contents/MacOS
	@mkdir -p $(DEV_APP)/Contents/Resources
	@cp app/Resources/DevInfo.plist $(DEV_APP)/Contents/Info.plist
	@cp app/Resources/amux.icns $(DEV_APP)/Contents/Resources/amux.icns
	@# rm first so a leftover symlink from an older Makefile version doesn't
	@# make cp bail with "SRC and DST are identical (not copied)".
	@rm -f $(DEV_APP)/Contents/MacOS/amux-app
	@cp $(CURDIR)/$(SWIFT_BUILD_DIR)/amux-app $(DEV_APP)/Contents/MacOS/amux-app
	@# Bundle amux-cli alongside amux-app so AppDelegate's findBinaryOptional
	@# resolves it via execDir on first launch. Without this, the app falls
	@# back to ~/.local/bin/amux-cli (the symlink the next step installs),
	@# then overwrites that symlink to point at itself — self-referencing,
	@# every tmux hook silently breaks.
	@rm -f $(DEV_APP)/Contents/MacOS/amux-cli
	@cp $(CURDIR)/$(SWIFT_BUILD_DIR)/amux-cli $(DEV_APP)/Contents/MacOS/amux-cli
	@codesign --force --sign - --identifier com.byoungs.amux.dev $(DEV_APP) >/dev/null 2>&1

app-dev: build-dev-bundle
	@# Symlink amux-cli to ~/.local/bin so tmux hooks can find it.
	@# Remove any stale symlink first — a prior run with a missing
	@# $(CURDIR) once created a self-referencing symlink that silently
	@# broke every tmux hook.
	@mkdir -p $(HOME)/.local/bin
	@rm -f $(HOME)/.local/bin/amux-cli
	@ln -s $(CURDIR)/$(SWIFT_BUILD_DIR)/amux-cli $(HOME)/.local/bin/amux-cli
	@# Kill any running dev instance so the fresh binary is what launches
	@killall amux-app 2>/dev/null || true
	@sleep 0.3
	@# Launch via LaunchServices so macOS treats it as a proper bundled app
	open $(DEV_APP)

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
	cp app/.build/release/amux-cli build/amux.app/Contents/MacOS/
	cp build/tmux-bundle/tmux build/amux.app/Contents/MacOS/
	cp build/tmux-bundle/LICENSE-tmux.txt build/amux.app/Contents/Resources/
	cp app/Resources/amux.icns build/amux.app/Contents/Resources/
	@# amux.icns is loaded at runtime via Bundle.main (AppDelegate), not the
	@# SwiftPM-generated AmuxApp_amux-app.bundle, so that resource bundle is
	@# not copied in. It used to be, placed loose at the .app root — but
	@# recent codesign refuses to seal an .app with any top-level item
	@# besides Contents/ ("unsealed contents present in the bundle root"),
	@# and the generated resource-bundle accessor only ever looked at the
	@# .app root, so there was no path inside Contents/ that satisfied both.
	@# Re-sign so the signing identifier matches CFBundleIdentifier.
	@# Swift's default adhoc sign uses "amux-app-<hash>" which is a
	@# different identity than the bundle, and some macOS subsystems
	@# (including UNUserNotificationCenter) key off the signing ID.
	codesign --force --sign - --identifier com.byoungs.amux build/amux.app
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

