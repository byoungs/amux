import Foundation
import AmuxLib

enum HelpTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        // help_content_covers_all_commands
        do {
            let allText = HelpContent.sections.flatMap { $0.entries.map { $0.key + " " + $0.description } }.joined(separator: " ")
            check("helpHasZoom", allText.contains("⌘+") && allText.contains("⌘-"),
                  "help must document zoom shortcuts")
            check("helpHasCycle", allText.contains("⌘[") || allText.contains("⌘]"),
                  "help must document cycle shortcuts")
            check("helpHasNewPane", allText.contains("⌘n"),
                  "help must document new pane shortcut")
            check("helpHasSplit", allText.contains("⌘l"),
                  "help must document split shortcut")
            check("helpHasSend", allText.contains("⌘s"),
                  "help must document send shortcut")
            check("helpHasSpaces", allText.contains("⌘p"),
                  "help must document spaces shortcut")
            check("helpHasHelp", allText.contains("⌘?"),
                  "help must document help shortcut")
            check("helpHasPeek", allText.contains("⌘y"),
                  "help must document permission-peek shortcut")
        }

        print("HelpTests: \(passed) passed, \(failed) failed")
        return (passed, failed)
    }
}
