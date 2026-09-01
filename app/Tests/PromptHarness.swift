/// Drives an amux-cli TUI inside a real tmux pane.
///
/// The prompt is a raw-mode terminal program, so the honest way to test it is
/// to run it in a pane, read the pane back, and press keys. Two environment
/// seams keep that off the developer's live amux:
///
///   AMUX_HOME         every amux state file (snapshot, prefs, marker)
///   $TMUX (implicit)  the CLI talks to the server that spawned it, which
///                     inside a test pane is the isolated test server
///
/// Both are set on the tmux session before the pane's shell is respawned, so
/// the shell — and everything it runs — inherits them.

import Foundation
import AmuxLib

final class PromptHarness {
    /// Fixed so tests can assert the exact value written to prefs.
    static let capturedAt: Double = 1_756_700_000

    let home: URL
    private let session: TestSession
    private let waitTimeout: TimeInterval = 10

    init(snapshot: SessionSnapshot) {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-prompt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? snapshot.save(to: home.appendingPathComponent("session-snapshot.json"))

        session = TestSession(paneCount: 1)
        // Set before respawning the shell: tmux builds a new process's
        // environment from the session environment at spawn time.
        tmux("set-environment", "-t", session.name, AmuxPaths.homeOverrideKey, home.path)
        session.useCleanShell()
    }

    /// Build a snapshot of one space for the prompt to offer.
    static func snapshot(spaceName: String, cleanExit: Bool,
                         panes: [(cwd: String, title: String, kind: PaneKind)]) -> SessionSnapshot {
        SessionSnapshot(
            capturedAt: capturedAt,
            cleanExit: cleanExit,
            spaces: [SpaceSnapshot(
                name: spaceName,
                panes: panes.enumerated().map { i, p in
                    PaneSnapshot(index: i, cwd: p.cwd, title: p.title, kind: p.kind)
                },
                selectedPane: 0)],
            backlog: [])
    }

    /// Launch the restore prompt in the pane and return the screen it painted.
    @discardableResult
    func start() -> String {
        let cli = PromptHarness.amuxCLIPath()
        tmux("send-keys", "-t", "\(session.name):0.0",
             "\(cli) prompt restore \(session.name)", "Enter")
        _ = waitFor { self.screen().contains("Restore your last session?") }
        return screen()
    }

    /// Press a key by tmux key name ("Enter", "Escape") or literal ("2").
    func press(_ key: String) {
        tmux("send-keys", "-t", "\(session.name):0.0", key)
    }

    /// What the pane currently shows. Visible region only — including
    /// scrollback would match text the prompt painted and already replaced.
    func screen() -> String {
        Tmux.capturePane(session.name, paneIndex: 0, lines: 0)
    }

    func prefs() -> RestorePrefs {
        RestorePrefs.load(from: home.appendingPathComponent("restore-prefs.json"))
    }

    func snapshotOnDisk() -> SessionSnapshot? {
        SessionSnapshot.load(from: home.appendingPathComponent("session-snapshot.json"))
    }

    /// Poll until the condition holds or the timeout expires.
    @discardableResult
    func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    func cleanUp(alsoKill sessions: [String] = []) {
        for name in sessions {
            tmux("kill-session", "-t", name)
        }
        try? FileManager.default.removeItem(at: home)
    }

    /// The amux-cli built alongside this test runner — never the one installed
    /// in ~/.local/bin, which may be an older build.
    ///
    /// `make validate` builds every product before running, so this binary is
    /// current. Running the test executable directly (`swift run
    /// amux-integration-tests`) can leave a stale amux-cli next to it, and
    /// these tests will then assert against the previous build's behavior.
    static func amuxCLIPath() -> String {
        let runner = URL(fileURLWithPath: CommandLine.arguments[0])
        let sibling = runner.deletingLastPathComponent().appendingPathComponent("amux-cli")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
        return Tmux.findAmuxBinary()
    }
}
