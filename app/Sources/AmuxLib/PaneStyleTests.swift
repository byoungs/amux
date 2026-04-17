#if DEBUG
import Foundation

public enum PaneStyleTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        // Helper
        func opt(_ fake: FakeTmux, pane: Int, key: String) -> String? {
            try? fake.execute(["show-options", "-p", "-t", "test:.\(pane)", "-v", key])
        }
        func gopt(_ fake: FakeTmux, key: String) -> String {
            fake.globalOptions[key] ?? ""
        }
        func sopt(_ fake: FakeTmux, key: String) -> String? {
            try? fake.execute(["show-options", "-t", "test", "-v", key])
        }

        // === setPaneStyle — sets tmux user options only ===

        do {
            let fake = FakeTmux()
            fake.addSession("test", panes: 3)
            Tmux.executor = fake

            setPaneStyle(session: "test", pane: 1, title: "my-title")
            check("setPaneStyle-title", opt(fake, pane: 1, key: "@amux-title") == "my-title")

            setPaneStyle(session: "test", pane: 1, alert: true)
            check("setPaneStyle-alert", opt(fake, pane: 1, key: "@amux-alert") == "1")

            setPaneStyle(session: "test", pane: 1, alert: false)
            check("setPaneStyle-alertOff", opt(fake, pane: 1, key: "@amux-alert") == "0")

            setPaneStyle(session: "test", pane: 2, splitSelected: true)
            check("setPaneStyle-splitSelected", opt(fake, pane: 2, key: "@amux-split-selected") == "1")

            // Setting one property doesn't affect others
            check("setPaneStyle-independent", opt(fake, pane: 2, key: "@amux-alert") == nil,
                  "alert should be unset on pane 2")
        }

        // === No per-pane pane-border-format overrides ===
        // The new architecture: tmux global format handles active/inactive.
        // TerminalView overlay handles alert/split coloring on top row only.
        // setPaneStyle must NEVER set pane-border-format.

        do {
            let fake = FakeTmux()
            fake.addSession("test", panes: 3)
            Tmux.executor = fake

            func hasBorderOverride(_ pane: Int) -> Bool {
                fake.sessions["test"]?.windows.first?.panes[pane].options["pane-border-format"] != nil
            }

            setPaneStyle(session: "test", pane: 0, alert: true)
            check("noOverride-alert",
                  !hasBorderOverride(0),
                  "alert must not set pane-border-format")

            setPaneStyle(session: "test", pane: 1, splitSelected: true)
            check("noOverride-split",
                  !hasBorderOverride(1),
                  "split-selected must not set pane-border-format")

            setPaneStyle(session: "test", pane: 0, alert: false)
            check("noOverride-alertOff",
                  !hasBorderOverride(0),
                  "clearing alert must not set pane-border-format")

            setPaneStyle(session: "test", pane: 1, splitSelected: false)
            check("noOverride-splitOff",
                  !hasBorderOverride(1),
                  "clearing split must not set pane-border-format")

            // Even with all states set, no pane gets a border override
            setPaneStyle(session: "test", pane: 2, title: "x", alert: true, splitSelected: true)
            check("noOverride-allStates",
                  !hasBorderOverride(2),
                  "no combination of states should set pane-border-format")
        }

        // === resetBorderStyles ===

        do {
            let fake = FakeTmux()
            Tmux.executor = fake

            resetBorderStyles()
            check("resetBorderStyles-active",
                  gopt(fake, key: "pane-active-border-style") == "fg=colour43",
                  "active border teal")
            check("resetBorderStyles-inactive",
                  gopt(fake, key: "pane-border-style") == "fg=colour235")
        }

        // === setSessionStatus ===

        do {
            let fake = FakeTmux()
            fake.addSession("test", panes: 2)
            Tmux.executor = fake

            setSessionStatus(session: "test", picking: true, label: "2 my-pane")
            check("sessionStatus-picking", sopt(fake, key: "@amux-picking") == "1")
            check("sessionStatus-label", sopt(fake, key: "@amux-split-first-label") == "2 my-pane")

            setSessionStatus(session: "test", picking: false)
            check("sessionStatus-pickingOff", sopt(fake, key: "@amux-picking") == "0")

            setSessionStatus(session: "test", alertCount: 3)
            check("sessionStatus-alertCount", sopt(fake, key: "@amux-alert-count") == "3")
        }

        Tmux.executor = LiveTmux()

        print("PaneStyle tests: \(passed) passed, \(failed) failed")
        Darwin.fflush(Darwin.stdout)
        if failed > 0 { fatalError("PaneStyle tests failed") }
    }
}
#endif
