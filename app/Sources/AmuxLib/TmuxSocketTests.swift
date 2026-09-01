#if DEBUG
import Foundation

/// Which tmux server amux-cli talks to.
///
/// The CLI is invoked from inside a pane (hooks, popups), so the correct
/// server is the one that spawned it — which tmux names in $TMUX. Honouring
/// that is also what lets integration tests drive the real CLI against their
/// isolated socket instead of the developer's live tmux.
public enum TmuxSocketTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        // $TMUX is "<socket-path>,<server-pid>,<session-id>".
        check("tmux-env",
              TmuxSocket.resolve(env: ["TMUX": "/private/tmp/tmux-501/amux-test-42,991,0"])
                == .path("/private/tmp/tmux-501/amux-test-42"),
              String(describing: TmuxSocket.resolve(env: ["TMUX": "/private/tmp/tmux-501/amux-test-42,991,0"])))

        // A socket path may contain commas; only the last two fields are tmux's.
        check("tmux-env-comma-in-path",
              TmuxSocket.resolve(env: ["TMUX": "/tmp/od,d/sock,991,0"]) == .path("/tmp/od,d/sock"),
              String(describing: TmuxSocket.resolve(env: ["TMUX": "/tmp/od,d/sock,991,0"])))

        // Explicit override wins — it is how a test names a socket for a CLI
        // process it launches outside any pane.
        check("explicit-name",
              TmuxSocket.resolve(env: ["AMUX_TMUX_SOCKET": "amux-test-7",
                                       "TMUX": "/tmp/other,1,0"]) == .name("amux-test-7"))

        // No hints at all: the default server, i.e. plain `tmux`.
        check("default", TmuxSocket.resolve(env: [:]) == .default)
        check("empty-values-ignored",
              TmuxSocket.resolve(env: ["TMUX": "", "AMUX_TMUX_SOCKET": ""]) == .default)
        check("malformed-tmux-ignored",
              TmuxSocket.resolve(env: ["TMUX": "nocommas"]) == .default)

        // The argv the executor builds for each case.
        check("argv-default", TmuxSocket.default.tmuxArgv(["list-panes"]) == ["tmux", "list-panes"])
        check("argv-name",
              TmuxSocket.name("s").tmuxArgv(["list-panes"]) == ["tmux", "-L", "s", "list-panes"])
        check("argv-path",
              TmuxSocket.path("/tmp/s").tmuxArgv(["list-panes"]) == ["tmux", "-S", "/tmp/s", "list-panes"])

        print("TmuxSocket tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("TmuxSocket tests failed") }
    }
}
#endif
