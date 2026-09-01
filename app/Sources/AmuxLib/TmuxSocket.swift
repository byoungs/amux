// TmuxSocket.swift -- Which tmux server to talk to.
//
// amux-cli runs from inside a pane (hooks, popups), so the right server is
// the one that spawned it. tmux names that server in $TMUX, and honouring it
// is both more correct than always using the default socket and what lets
// integration tests drive the real CLI against their isolated server.

import Foundation

public enum TmuxSocket: Equatable {
    /// The default server: plain `tmux`.
    case `default`
    /// A named socket: `tmux -L <name>`.
    case name(String)
    /// A socket path: `tmux -S <path>`.
    case path(String)

    public static let overrideKey = "AMUX_TMUX_SOCKET"

    /// Resolve from the environment. An explicit override wins; otherwise the
    /// server named in $TMUX; otherwise the default.
    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> TmuxSocket {
        if let override = env[overrideKey], !override.isEmpty {
            return .name(override)
        }
        if let tmux = env["TMUX"], !tmux.isEmpty {
            // "<socket-path>,<server-pid>,<session-id>" — the path itself may
            // contain commas, so drop exactly the last two fields.
            let fields = tmux.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count >= 3 {
                let socketPath = fields.dropLast(2).joined(separator: ",")
                if !socketPath.isEmpty { return .path(socketPath) }
            }
        }
        return .default
    }

    /// The full argv for a tmux invocation against this server.
    public func tmuxArgv(_ args: [String]) -> [String] {
        switch self {
        case .default: return ["tmux"] + args
        case .name(let name): return ["tmux", "-L", name] + args
        case .path(let path): return ["tmux", "-S", path] + args
        }
    }
}
