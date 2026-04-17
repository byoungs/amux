// Landing.swift -- Pure navigation logic for space switching.
// Decides where to land when entering a space from the picker.

/// Where to land when switching to a space.
public enum LandingTarget: Equatable {
    case focusPane(Int)
    case resume(Int)
}

/// Decide where to land when entering a space from the picker.
///
/// If any pane has an alert, focus the first alerted pane.
/// Otherwise resume on the previously active pane.
public func smartLanding(alertStates: [Bool], prevPane: Int) -> LandingTarget {
    if let index = alertStates.firstIndex(of: true) {
        return .focusPane(index)
    }
    return .resume(prevPane)
}

// MARK: - Tests

#if DEBUG
public enum LandingTests {
    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " -- \(message)")") }
        }

        check("no alerts resumes previous pane",
              smartLanding(alertStates: [false, false, false], prevPane: 2) == .resume(2))

        check("single alert focuses that pane",
              smartLanding(alertStates: [false, true, false], prevPane: 0) == .focusPane(1))

        check("multiple alerts focuses first",
              smartLanding(alertStates: [false, true, true], prevPane: 0) == .focusPane(1))

        check("all alerted focuses first",
              smartLanding(alertStates: [true, true, true], prevPane: 2) == .focusPane(0))

        check("empty alert states resumes",
              smartLanding(alertStates: [], prevPane: 0) == .resume(0))

        print("Landing tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Landing tests failed") }
    }
}
#endif
