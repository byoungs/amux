// CliDispatch.swift — pure predicate for the `amux` → `amux-cli` shim.
//
// Background: before the Swift port, `amux` was a single binary that
// handled both GUI and CLI subcommands (alert-pane, bell-watch, ...).
// The port split them: `amux-app` is the GUI, `amux-cli` is the CLI.
//
// Existing tmux and Claude Code hooks still invoke `amux alert-pane ...`
// (they were installed against the Rust binary and are not automatically
// rewritten). If `~/.local/bin/amux` still points at a stale Rust
// binary, those hooks post notifications via `osascript`, which routes
// clicks to Script Editor instead of amux (the regression this file is
// responding to).
//
// Fix shape: the GUI binary's entry point checks argv for a known CLI
// subcommand and, if matched, exec's `amux-cli` with the same args —
// turning `amux-app` into a drop-in replacement for the old unified
// `amux` binary. This predicate is the pure half of that logic, so
// tests can pin the subcommand set without spawning processes.

import Foundation

/// Canonical set of subcommands handled by `amux-cli`. Must match the
/// `case "..."` arms in AmuxCLI/main.swift.
public let amuxCliSubcommands: Set<String> = [
    "layout",
    "update-title",
    "alert-pane",
    "bell-watch",
    "hook-install",
    "spaces",
    "send",
    "help",
]

/// True if argv indicates a CLI invocation that should be forwarded to
/// `amux-cli`. argv[0] is the binary path; argv[1] is the subcommand.
public func shouldDispatchToCli(_ args: [String]) -> Bool {
    guard args.count >= 2 else { return false }
    return amuxCliSubcommands.contains(args[1])
}

#if DEBUG
public enum CliDispatchTests {
    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else {
                failed += 1
                print("FAIL: \(name)\(message.isEmpty ? "" : " — \(message)")")
            }
        }

        // No args → GUI launch.
        check("bareInvocationIsGui",
              !shouldDispatchToCli(["amux"]),
              "bare `amux` should start the GUI, not dispatch to CLI")

        // GUI flag → not a CLI subcommand.
        check("runTestsIsNotCli",
              !shouldDispatchToCli(["amux", "--run-tests"]))

        // Every documented CLI subcommand must dispatch. This is the
        // regression guard: if a subcommand is added to amux-cli but
        // not to `amuxCliSubcommands`, hooks calling `amux <cmd>` will
        // silently open the GUI instead of running the command.
        for sub in ["layout", "update-title", "alert-pane", "bell-watch",
                    "hook-install", "spaces", "send", "help"] {
            check("dispatch-\(sub)",
                  shouldDispatchToCli(["amux", sub]),
                  "`amux \(sub)` must be forwarded to amux-cli")
        }

        // Subcommand with its own args still dispatches.
        check("dispatchWithArgs",
              shouldDispatchToCli(["amux", "alert-pane", "0"]))

        // Unknown first arg → GUI (don't accidentally eat user data).
        check("unknownSubcommandIsGui",
              !shouldDispatchToCli(["amux", "not-a-command"]))

        print("CliDispatch tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("CliDispatch tests failed") }
    }
}
#endif
