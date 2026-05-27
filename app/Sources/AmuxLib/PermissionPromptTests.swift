#if DEBUG
import Foundation

public enum PermissionPromptTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        // Real 2-option Bash prompt shape (permission-bash.txt). No box glyphs;
        // space-indented; selection glyph ❯.
        let twoOpt = """
         Bash command

           echo hello-from-peek
           Echo test string

         Permission rule Bash(echo:*) requires confirmation for this command.
         /permissions to update rules

         Do you want to proceed?
         ❯ 1. Yes
           2. No

         Esc to cancel · Tab to amend · ctrl+e to explain
        """
        if let p = detectPermissionPrompt(twoOpt) {
            check("2opt-question", p.question == "Do you want to proceed?", p.question)
            check("2opt-count", p.options.count == 2, "\(p.options.count)")
            check("2opt-yes", p.options.first?.label == "Yes")
            check("2opt-selected", p.options.first?.selected == true)
            check("2opt-reject", p.rejectOption?.label == "No", p.rejectOption?.label ?? "nil")
            check("2opt-details-command",
                  p.details.contains(where: { $0.contains("echo hello-from-peek") }),
                  p.details.joined(separator: " | "))
        } else {
            check("2opt-detected", false, "returned nil")
        }

        // Real 3-option Bash prompt shape (permission-bash-3opt.txt).
        let threeOpt = """
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for: sw_vers *
           3. No
        """
        if let p = detectPermissionPrompt(threeOpt) {
            check("3opt-count", p.options.count == 3, "\(p.options.count)")
            check("3opt-opt2-yes", p.options[1].label.hasPrefix("Yes"))
            check("3opt-reject", p.rejectOption?.number == 3 && p.rejectOption?.label == "No")
            check("3opt-selected", p.options.first?.selected == true)
        } else {
            check("3opt-detected", false, "returned nil")
        }

        // No numbered "No" (reject is Esc-only): rejectOption must be nil so
        // "Yes, and don't ask again" answers in place — never engages.
        let noReject = """
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don't ask again for: foo *
        """
        if let p = detectPermissionPrompt(noReject) {
            check("noreject-count", p.options.count == 2, "\(p.options.count)")
            check("noreject-nil", p.rejectOption == nil, p.rejectOption?.label ?? "nil")
        } else {
            check("noreject-detected", false, "returned nil")
        }

        // Narrow-pane two-column rendering: option 2's long command wraps
        // across lines BETWEEN option 2 and "3. No", and a right-hand column
        // follows a 2+-space gap. Parser must still find all 3 options and
        // identify "No" as the reject (sanitized replica of a real capture).
        let narrow = """
         Bash command

           ~/tools/bin/longbinary --flag-one --flag-two --flag-three
           Render and check the thing

         Do you want to proceed?
         ❯ 1. Yes
          2.Yes, and don't ask   : ~/tools/bin/longbinary --flag-one --flag-two
            again for            longbinary-name --flag-three --flag-four
                                 --flag-five
           3. No

         Esc to cancel · Tab to amend · ctrl+e to explain
        """
        if let p = detectPermissionPrompt(narrow) {
            check("narrow-count", p.options.count == 3, "\(p.options.count)")
            check("narrow-opt1-yes", p.options.first?.label == "Yes")
            check("narrow-opt2-yes", p.options[1].label.hasPrefix("Yes"), p.options[1].label)
            check("narrow-reject", p.rejectOption?.number == 3 && p.rejectOption?.label == "No",
                  "\(p.rejectOption?.number ?? -1):\(p.rejectOption?.label ?? "nil")")
            check("narrow-details-command",
                  p.details.contains(where: { $0.contains("longbinary") }),
                  p.details.joined(separator: " | "))
        } else {
            check("narrow-detected", false, "returned nil")
        }

        // Answer mapping: option → its digit token (verified: no Enter).
        check("answer-1", answerKeys(for: PromptOption(number: 1, label: "Yes", selected: true)) == ["1"])
        check("answer-3", answerKeys(for: PromptOption(number: 3, label: "No", selected: false)) == ["3"])

        // Negative: ordinary chat numbered list (no "?" line above) must NOT detect.
        let chat = """
        Here are the steps:
        1. Yes you can do that
        2. No you cannot
        Let me know.
        """
        check("chat-not-detected", detectPermissionPrompt(chat) == nil)

        // Negative: text that quotes a prompt shape (?, numbered Yes/No) but has
        // NO selection glyph and NO footer — e.g. Claude echoing a prompt in the
        // transcript. Must NOT detect (else a stray digit gets sent to the pane).
        let quoted = """
        Do you want to proceed?
        1. Yes
        2. No
        """
        check("quoted-not-detected", detectPermissionPrompt(quoted) == nil)

        // Negative: empty / whitespace.
        check("empty-not-detected", detectPermissionPrompt("   \n  ") == nil)

        print("PermissionPrompt tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PermissionPrompt tests failed") }
    }
}
#endif
