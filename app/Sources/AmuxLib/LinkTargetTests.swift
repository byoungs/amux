import Foundation

#if DEBUG
public enum LinkTargetTests {
    public static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")") }
        }

        let files: Set<String> = ["/repo/README.md", "/repo/src/a b.swift", "/Users/me/notes.txt"]
        func resolve(_ link: String, cwd: String = "/repo") -> URL? {
            LinkTarget.resolve(link, cwd: cwd, home: "/Users/me", exists: { files.contains($0) })
        }

        // Web links go to macOS as-is (default browser).
        check("https passes through",
              resolve("https://example.com/a?b=1") == URL(string: "https://example.com/a?b=1"))
        // Any OSC 8 scheme is macOS's to route (mailto:, file://, vscode:, ...).
        check("other scheme passes through",
              resolve("mailto:x@y.com") == URL(string: "mailto:x@y.com"))
        check("file URI passes through",
              resolve("file:///repo/README.md") == URL(string: "file:///repo/README.md"))

        // Detected paths ("file:" + text) resolve against the clicked pane.
        check("relative path uses pane cwd",
              resolve("file:README.md") == URL(fileURLWithPath: "/repo/README.md"))
        check("dot-relative path normalized",
              resolve("file:./src/../README.md") == URL(fileURLWithPath: "/repo/README.md"))
        check("path with spaces",
              resolve("file:src/a b.swift") == URL(fileURLWithPath: "/repo/src/a b.swift"))
        check("absolute path ignores cwd",
              resolve("file:/repo/README.md", cwd: "/elsewhere") == URL(fileURLWithPath: "/repo/README.md"))
        check("tilde expands to home",
              resolve("file:~/notes.txt") == URL(fileURLWithPath: "/Users/me/notes.txt"))

        // A detected path that isn't a real file is not a link: a click on
        // "config.json" in prose must not open a missing-file error.
        check("missing file is nil", resolve("file:nope.md") == nil)
        check("relative with no cwd is nil", resolve("file:README.md", cwd: "") == nil)

        // A link's label can say anything, so a click must never *run*
        // something: executables and bundles are revealed in Finder.
        check("document opens", !LinkTarget.shouldReveal(path: "/r/a.md", isDirectory: false, isExecutable: false))
        check("folder opens", !LinkTarget.shouldReveal(path: "/r/src", isDirectory: true, isExecutable: true))
        check("executable is revealed", LinkTarget.shouldReveal(path: "/r/x", isDirectory: false, isExecutable: true))
        check("app bundle is revealed", LinkTarget.shouldReveal(path: "/r/X.app", isDirectory: true, isExecutable: true))
        check("command script is revealed", LinkTarget.shouldReveal(path: "/r/go.command", isDirectory: false, isExecutable: false))

        // Pane under the click, for the cwd.
        let panes = [
            LinkTarget.PaneRect(left: 0, top: 1, width: 40, height: 20, cwd: "/left", active: false),
            LinkTarget.PaneRect(left: 41, top: 1, width: 40, height: 20, cwd: "/right", active: true),
        ]
        check("click inside left pane", LinkTarget.cwd(atRow: 5, col: 10, panes: panes) == "/left")
        check("click inside right pane", LinkTarget.cwd(atRow: 20, col: 80, panes: panes) == "/right")
        check("click on border falls back to active",
              LinkTarget.cwd(atRow: 0, col: 10, panes: panes) == "/right")

        print("LinkTarget tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("LinkTarget tests failed") }
    }
}
#endif
