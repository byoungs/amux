/// Integration test: `make build-dev-bundle` produces a valid macOS app
/// bundle that UNUserNotificationCenter will accept posts from.
///
/// This test exists specifically to prevent a regression where
/// `make dev` launched amux-app as a raw Mach-O (no bundle wrapper).
/// In that state Bundle.main.bundleIdentifier is nil and every
/// UN.add() call silently no-ops — the user sees zero notifications,
/// with zero errors logged. The fix is to assemble a real
/// .app/Contents/Info.plist so the process has a bundle identity.
///
/// What we can verify automatically:
///   - make build-dev-bundle succeeds
///   - The assembled bundle has the expected directory layout
///   - Info.plist parses and has a non-empty CFBundleIdentifier
///   - The MacOS executable is present and executable
///   - The icon resource is present
///
/// What we can NOT verify automatically (requires manual smoke test):
///   - User has granted notification permission in System Settings
///   - macOS actually displays the banner
///   - Clicking the banner brings amux to front
///
/// For the manual smoke test, launch `make dev`, trigger an alert from
/// a pane (Claude Code notification or `printf '\a'`), and watch for
/// the stderr line `amux: posting notification: body="..."`. If you
/// see that line, the code pipeline is working; if the banner still
/// doesn't appear after that, it's a permission issue and the
/// UNNotificationPoster authorization log points at System Settings.

import Foundation

enum DevBundleTests {
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

        // Repo root derived from this file's path — two levels up from
        // app/Tests/DevBundleTests.swift.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .path

        // Unique bundle path per test run so concurrent runs and
        // leftover bundles from earlier runs don't cause flake.
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = NSTemporaryDirectory()
            + "amux-devbundle-test-\(pid)-\(UUID().uuidString).app"

        defer {
            try? FileManager.default.removeItem(atPath: bundlePath)
        }

        // Run the exact Makefile target the dev flow uses. Overriding
        // DEV_APP points the assembly at our temp path; if the target
        // is broken or the Info.plist path drifts, make will fail here.
        let makeResult = runShell(
            "make -C \(shellEscape(repoRoot)) build-dev-bundle DEV_APP=\(shellEscape(bundlePath))")
        check("make-build-dev-bundle-succeeds",
              makeResult.success,
              "make failed (exit \(makeResult.status)): \(makeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        if !makeResult.success {
            print("DevBundleTests: \(passed) passed, \(failed) failed")
            return (passed, failed)
        }

        // MARK: - Bundle layout

        let infoPlist = "\(bundlePath)/Contents/Info.plist"
        let binary    = "\(bundlePath)/Contents/MacOS/amux-app"
        let iconPath  = "\(bundlePath)/Contents/Resources/amux.icns"

        check("bundle-hasInfoPlist",
              FileManager.default.fileExists(atPath: infoPlist),
              "Info.plist missing at \(infoPlist)")

        check("bundle-hasBinary",
              FileManager.default.isExecutableFile(atPath: binary),
              "amux-app binary missing or not executable at \(binary)")

        check("bundle-hasIcon",
              FileManager.default.fileExists(atPath: iconPath),
              "icon missing at \(iconPath)")

        // MARK: - Info.plist content

        // Use plutil to extract fields. plutil is part of the base OS
        // and is what macOS itself uses to parse bundle metadata, so
        // success here mirrors LaunchServices' own parsing.
        let bundleIdResult = runShell(
            "plutil -extract CFBundleIdentifier raw -o - \(shellEscape(infoPlist))")
        let bundleId = bundleIdResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("bundle-hasBundleIdentifier",
              bundleIdResult.success && !bundleId.isEmpty,
              "CFBundleIdentifier missing or empty. plutil output: " +
              "'\(bundleIdResult.stdout)' / stderr: '\(bundleIdResult.stderr)'")
        check("bundle-identifierIsAmuxDev",
              bundleId == "com.byoungs.amux.dev",
              "expected com.byoungs.amux.dev, got '\(bundleId)'")

        // CFBundleExecutable must match the actual binary name or
        // LaunchServices won't find it.
        let execNameResult = runShell(
            "plutil -extract CFBundleExecutable raw -o - \(shellEscape(infoPlist))")
        let execName = execNameResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("bundle-executableNameMatches",
              execName == "amux-app",
              "CFBundleExecutable should be 'amux-app', got '\(execName)'")

        // CFBundlePackageType must be APPL for LaunchServices to treat
        // it as an application (not, say, a framework). Without this,
        // `open bundle.app` fails with -10810.
        let pkgTypeResult = runShell(
            "plutil -extract CFBundlePackageType raw -o - \(shellEscape(infoPlist))")
        let pkgType = pkgTypeResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("bundle-packageTypeAPPL",
              pkgType == "APPL",
              "CFBundlePackageType should be 'APPL', got '\(pkgType)'")

        // MARK: - Binary is a real file, not a symlink
        //
        // dyld resolves the executable path through any symlinks before
        // computing Bundle.main. A symlink into .build/ makes
        // mainBundle.bundleURL point at the build dir (no Info.plist),
        // which makes UNUserNotificationCenter.current() abort with
        // "bundleProxyForCurrentProcess is nil" on macOS 15.7+.
        let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: binary)) != nil
        check("bundle-binaryNotSymlink", !isSymlink,
              "binary at \(binary) is a symlink — dyld will resolve it and break Bundle.main")
        let attrs = try? FileManager.default.attributesOfItem(atPath: binary)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        check("bundle-binaryNonEmpty", size > 0,
              "binary at \(binary) has zero size")

        // MARK: - Stale-symlink upgrade
        //
        // Simulate a bundle left over from the old Makefile (which used
        // ln -sf). A naive `cp` fails with "SRC and DST are identical"
        // because the symlink already points at SRC — leaving the bundle
        // with the stale symlink and a failing make target. Assert that
        // re-running build-dev-bundle over a pre-existing symlink
        // succeeds and replaces it with a real file.
        let swiftBinary = "\(repoRoot)/app/.build/arm64-apple-macosx/debug/amux-app"
        try? FileManager.default.removeItem(atPath: binary)
        try? FileManager.default.createSymbolicLink(
            atPath: binary, withDestinationPath: swiftBinary)
        let rerunResult = runShell(
            "make -C \(shellEscape(repoRoot)) build-dev-bundle DEV_APP=\(shellEscape(bundlePath))")
        check("make-build-dev-bundle-overStaleSymlink-succeeds",
              rerunResult.success,
              "make failed over stale symlink (exit \(rerunResult.status)): \(rerunResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        let isStillSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: binary)) != nil
        check("bundle-staleSymlinkReplacedWithRealFile", !isStillSymlink,
              "binary at \(binary) is still a symlink after rerun")

        // MARK: - Code signing identifier matches bundle ID
        //
        // adhoc signing defaults to "amux-app-<hash>". For UN and other
        // bundle-ID-keyed subsystems to consistently identify the app,
        // the signing identifier must match CFBundleIdentifier. The
        // Makefile's codesign --identifier step enforces this.
        let codesignResult = runShell(
            "codesign -dv \(shellEscape(bundlePath)) 2>&1")
        let identifierLine = codesignResult.stdout
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("Identifier=") })
            .map(String.init) ?? ""
        let codesignId = identifierLine
            .replacingOccurrences(of: "Identifier=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("bundle-codesignIdentifierMatchesBundleId",
              codesignId == "com.byoungs.amux.dev",
              "codesign Identifier should be com.byoungs.amux.dev, got '\(codesignId)'")

        print("DevBundleTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }

    /// Run a shell command. Used to invoke `make` and `plutil` since
    /// neither is accessible via the test target's Swift deps.
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

    /// Quote a path for safe inclusion in a /bin/sh command.
    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
