// SpaceName.swift -- Turning what the user typed into a safe space name.
//
// A space is a tmux session, and its name ends up inside shell commands tmux
// runs for us (hooks, popups). Hook commands quote it with `#{q:...}`, but
// names are also normalized once, at creation, to characters no shell or
// tmux target syntax treats specially: a second line of defense for any
// interpolation that misses the quoting, and names that read cleanly in the
// space-separated `list-sessions` output amux parses.

import Foundation

public enum SpaceName {
    /// Normalize a typed name: letters, digits, `-` and `_` pass through;
    /// every other run of characters becomes a single `-`. Returns nil when
    /// nothing usable is left. Pure.
    public static func normalize(_ typed: String) -> String? {
        var out = ""
        var pendingDash = false
        for scalar in typed.unicodeScalars {
            let keep = CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            if keep {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? nil : out
    }
}
