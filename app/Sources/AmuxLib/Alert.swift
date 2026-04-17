// Alert.swift -- Pure alert decision logic.
// No tmux dependency. Takes data in, returns decisions out.

/// Count panes in "ready for you" state.
public func countAlerts(_ alertStates: [Bool]) -> Int {
    alertStates.filter { $0 }.count
}

// MARK: - Tests

#if DEBUG
public enum AlertTests {
    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " -- \(message)")") }
        }

        check("no alerts", countAlerts([false, false, false]) == 0)
        check("one alert", countAlerts([false, true, false]) == 1)
        check("all alerts", countAlerts([true, true, true]) == 3)
        check("empty", countAlerts([]) == 0)

        print("Alert tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("Alert tests failed") }
    }
}
#endif
