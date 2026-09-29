#if DEBUG
import Foundation

/// Claude Code Notification hook installation. Runs against a scratch
/// settings file; the real ~/.claude/settings.json is never touched.
public enum HooksTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amux-hooks-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        func notificationCommands(_ path: URL) -> [String] {
            guard let data = try? Data(contentsOf: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any],
                  let entries = hooks["Notification"] as? [[String: Any]] else { return [] }
            return entries.flatMap { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
            }
        }

        // Every amux launch calls ensureClaudeHook; it must install once, not
        // append another copy of the hook each time.
        do {
            let path = dir.appendingPathComponent("fresh/settings.json")
            try Hooks.ensureClaudeHook(settingsPath: path)
            try Hooks.ensureClaudeHook(settingsPath: path)
            let cmds = notificationCommands(path)
            check("install-idempotent",
                  cmds.count == 1 && cmds[0].contains("amux-cli alert-pane"),
                  "commands: \(cmds)")
        } catch {
            check("install-idempotent", false, "threw \(error)")
        }

        // A legacy `amux alert-pane` entry counts as installed, and unrelated
        // user settings survive untouched.
        do {
            let path = dir.appendingPathComponent("legacy/settings.json")
            let legacy: [String: Any] = [
                "model": "opus",
                "hooks": ["Notification": [
                    ["matcher": "", "hooks": [["type": "command", "command": "amux alert-pane 0"]]],
                ]],
            ]
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: legacy).write(to: path)
            try Hooks.ensureClaudeHook(settingsPath: path)
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String: Any]
            check("legacy-not-duplicated",
                  notificationCommands(path) == ["amux alert-pane 0"]
                      && json?["model"] as? String == "opus",
                  "commands: \(notificationCommands(path))")
        } catch {
            check("legacy-not-duplicated", false, "threw \(error)")
        }

        print("Hooks tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Hooks tests failed") }
    }
}
#endif
