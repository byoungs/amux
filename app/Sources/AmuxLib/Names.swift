import Foundation

/// The optional naming companion. Providers exchange metadata over JSON pipes.
/// It never creates terminals or changes their input, scrolling or lifecycle.
public enum Names {
    public static func scriptPath() -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/names/names.py")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return source.appendingPathComponent("scripts/names/names.py").path
    }

    public static func command(_ args: [String]) -> String {
        (["python3", scriptPath()] + args).map(SessionRestore.singleQuoted).joined(separator: " ")
    }

    public static func popup(session: String, mode: String = "rename", clientTTY: String? = nil) {
        Tmux.launch(["display-popup", "-t", session] + (clientTTY.map { ["-c", $0] } ?? []) + ["-E", "-w", "80%", "-h", "10",
                     "-T", mode == "rename-space" ? " Rename Space " : " Rename Pane / Session ",
                     "env AMUX_SESSION=\(SessionRestore.singleQuoted(session)) " + command([mode])])
    }

    public static func background(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptPath()] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    public static func spaceTitle(_ session: String) -> String {
        let title = Tmux.runRaw(["show-options", "-v", "-t", session, "@amux-space-title"])
        return title.isEmpty ? session : title
    }

    public static func binding(_ target: String) -> String {
        Tmux.runRaw(["show-options", "-p", "-v", "-t", target, "@amux-names"])
    }
}
