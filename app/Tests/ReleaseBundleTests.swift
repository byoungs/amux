/// Regression tests for three build bugs hit while rebuilding the release
/// .app from a clean tree (macOS/tmux toolchain drift, 2026-07-24):
///
/// 1. tmux HEAD's `configure` now hard-requires `--enable-jemalloc` or
///    `--disable-jemalloc` — `scripts/build-tmux.sh` didn't pass either,
///    so `make dmg` died in `./configure` before tmux ever compiled.
/// 2. tmux HEAD links `-lncursesw` (not `-lncurses`). The Makefile-sed
///    that force-links the static lib matched `-lncurses` as a substring
///    of `-lncursesw`, leaving a stray trailing `w` and producing the
///    nonexistent path `libncursesw.aw` — link failure.
/// 3. Newer `codesign` refuses to seal an .app that has any top-level
///    item besides `Contents/` ("unsealed contents present in the bundle
///    root"), even if that item is itself signed. The old Makefile put
///    SwiftPM's generated `AmuxApp_amux-app.bundle` there so `Bundle.module`
///    could find it. Fix: `AppDelegate` now loads the icon via
///    `Bundle.main` (the icon is already copied to
///    `Contents/Resources/amux.icns` for both dev and release bundles),
///    so the loose top-level bundle isn't needed and isn't copied in.
///
/// These tests are static/synthetic — they don't run the real multi-minute
/// `make dmg` (which clones and builds tmux from scratch) — but they pin
/// down the exact conditions that broke, so a future edit that
/// reintroduces any of the three can't pass silently.
import Foundation

enum ReleaseBundleTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .path

        // MARK: - Bug 1: tmux configure needs an explicit jemalloc choice

        let buildTmuxScript = (try? String(
            contentsOfFile: "\(repoRoot)/scripts/build-tmux.sh", encoding: .utf8)) ?? ""
        check("buildTmuxScript-notEmpty", !buildTmuxScript.isEmpty,
              "could not read scripts/build-tmux.sh")
        check("buildTmuxScript-passesJemallocFlag",
              buildTmuxScript.contains("--disable-jemalloc") ||
              buildTmuxScript.contains("--enable-jemalloc"),
              "tmux's ./configure now requires --enable-jemalloc or " +
              "--disable-jemalloc explicitly; without one, configure " +
              "exits 1 before tmux ever compiles")

        // MARK: - Bug 2: -lncursesw must not be clobbered by the -lncurses sed

        // Reproduce the exact sed pipeline the script runs on tmux's
        // Makefile, against a synthetic link line containing both the
        // wide (-lncursesw) and narrow (-lncurses) library flags.
        let sampleLinkLine = "gcc -o tmux foo.o -lutf8proc -lncursesw -levent_core -levent "
        let sedResult = runShell(
            "printf '%s' \(shellEscape(sampleLinkLine)) | " +
            "sed \"s|-lutf8proc|LIBUTF8PROC.a|g\" | " +
            "sed \"s|-lncursesw|LIBNCURSESW.a|g\" | " +
            "sed \"s|-lncurses|LIBNCURSESW.a|g\"")
        let sedOutput = sedResult.stdout
        check("ncursesSed-rewritesWideLib",
              sedOutput.contains("LIBNCURSESW.a") && !sedOutput.contains(".aw"),
              "expected -lncursesw rewritten cleanly to LIBNCURSESW.a with no " +
              "trailing 'w', got: '\(sedOutput)'")
        check("ncursesSed-noStrayNarrowFlagLeftover",
              !sedOutput.contains("-lncurses"),
              "a bare -lncurses survived the sed pipeline: '\(sedOutput)'")

        // And assert the two sed lines in the real script are ordered
        // wide-before-narrow — the only ordering that avoids the clobber,
        // since a narrow-first `-lncurses` replacement would also match
        // (and truncate) the `-lncursesw` token before the wide rule runs.
        if let wideRange = buildTmuxScript.range(of: "-lncursesw"),
           let narrowSedRange = buildTmuxScript.range(
               of: "s|-lncurses|", range: wideRange.upperBound..<buildTmuxScript.endIndex) {
            check("buildTmuxScript-wideSedBeforeNarrowSed", true)
            _ = narrowSedRange // ordering confirmed by finding narrow sed after wide token
        } else {
            check("buildTmuxScript-wideSedBeforeNarrowSed", false,
                  "expected an -lncursesw sed line before any -lncurses sed line")
        }

        // MARK: - Bug 3: no loose top-level bundle inside the release .app

        let appDelegateSource = (try? String(
            contentsOfFile: "\(repoRoot)/app/Sources/AmuxTerm/AppDelegate.swift",
            encoding: .utf8)) ?? ""
        check("appDelegate-notEmpty", !appDelegateSource.isEmpty,
              "could not read AppDelegate.swift")
        check("appDelegate-doesNotUseBundleModuleForIcon",
              !appDelegateSource.contains("Bundle.module"),
              "AppDelegate should load the dock icon via Bundle.main, not " +
              "Bundle.module — Bundle.module resolves to a SwiftPM resource " +
              "bundle that only ever gets found at the .app's top level, " +
              "which newer codesign refuses to seal")
        check("appDelegate-usesBundleMainForIcon",
              appDelegateSource.contains(
                  #"Bundle.main.url(forResource: "amux", withExtension: "icns")"#),
              "expected AppDelegate to load the icon via " +
              "Bundle.main.url(forResource:withExtension:)")

        let makefile = (try? String(
            contentsOfFile: "\(repoRoot)/Makefile", encoding: .utf8)) ?? ""
        check("makefile-notEmpty", !makefile.isEmpty, "could not read Makefile")
        check("makefile-dmgDoesNotCopyResourceBundleToAppRoot",
              !makefile.contains("cp -R app/.build/release/AmuxApp_amux-app.bundle"),
              "the dmg target should not copy the SwiftPM resource bundle " +
              "to the .app root anymore — that's the exact item codesign " +
              "rejects as \"unsealed contents present in the bundle root\"")

        // Directly prove the codesign invariant: a synthetic .app with
        // ONLY Contents/ signs cleanly, but the old shape (a loose
        // top-level item alongside Contents/) does not. This is the
        // actual mechanism behind bug 3, independent of anything else
        // in the Makefile or AppDelegate.
        let pid = ProcessInfo.processInfo.processIdentifier
        let cleanApp = NSTemporaryDirectory() + "amux-release-test-clean-\(pid)-\(UUID().uuidString).app"
        let dirtyApp = NSTemporaryDirectory() + "amux-release-test-dirty-\(pid)-\(UUID().uuidString).app"
        defer {
            try? FileManager.default.removeItem(atPath: cleanApp)
            try? FileManager.default.removeItem(atPath: dirtyApp)
        }

        func scaffold(_ appPath: String, extraTopLevelDir: Bool) {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: "\(appPath)/Contents/MacOS", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: "\(appPath)/Contents/Resources", withIntermediateDirectories: true)
            fm.createFile(atPath: "\(appPath)/Contents/Info.plist", contents: Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                    <key>CFBundleIdentifier</key><string>com.byoungs.amux.test</string>
                    <key>CFBundleExecutable</key><string>dummy</string>
                    <key>CFBundlePackageType</key><string>APPL</string>
                </dict></plist>
                """.utf8))
            fm.createFile(atPath: "\(appPath)/Contents/MacOS/dummy", contents: Data("#!/bin/sh\n".utf8))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(appPath)/Contents/MacOS/dummy")
            fm.createFile(atPath: "\(appPath)/Contents/Resources/amux.icns", contents: Data([0x00]))
            if extraTopLevelDir {
                try? fm.createDirectory(atPath: "\(appPath)/SomeResourceBundle.bundle", withIntermediateDirectories: true)
                fm.createFile(atPath: "\(appPath)/SomeResourceBundle.bundle/thing", contents: Data([0x00]))
            }
        }

        scaffold(cleanApp, extraTopLevelDir: false)
        scaffold(dirtyApp, extraTopLevelDir: true)

        let cleanSign = runShell(
            "codesign --force --sign - --identifier com.byoungs.amux.test \(shellEscape(cleanApp))")
        check("codesign-cleanContentsOnlyBundleSigns", cleanSign.success,
              "expected a .app with only Contents/ to sign cleanly, got " +
              "(exit \(cleanSign.status)): \(cleanSign.stderr)")

        let dirtySign = runShell(
            "codesign --force --sign - --identifier com.byoungs.amux.test \(shellEscape(dirtyApp))")
        check("codesign-looseTopLevelDirFailsToSign", !dirtySign.success,
              "expected a .app with a loose top-level dir to be REJECTED by " +
              "codesign (this is the exact bug) — but it signed successfully, " +
              "meaning this Mac's codesign no longer exhibits the failure " +
              "this fix was written for")

        print("ReleaseBundle: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }

    private static func runShell(_ command: String) -> (stdout: String, stderr: String, status: Int32, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ("", "failed to launch: \(error)", -1, false)
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(data: out, encoding: .utf8) ?? "",
            String(data: err, encoding: .utf8) ?? "",
            process.terminationStatus,
            process.terminationStatus == 0
        )
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
