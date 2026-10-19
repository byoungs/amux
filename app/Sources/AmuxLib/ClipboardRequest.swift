import Foundation

/// Selection bytes travel outside the terminal redraw stream to the native app.
public struct ClipboardRequest: Codable {
    public let text: String
    public init(text: String) { self.text = text }
    public static let maxTextBytes = 8 * 1024 * 1024
    // JSON may escape each input byte as six ASCII bytes.
    public static let maxMessageBytes = maxTextBytes * 6 + 1024
}

public func defaultClipboardSocketPath() -> String {
    URL(fileURLWithPath: defaultAlertSocketPath()).deletingLastPathComponent()
        .appendingPathComponent("amux-clipboard.sock").path
}

public func clipboardCommand(binary: String, socketPath: String = defaultClipboardSocketPath()) -> String {
    SessionRestore.singleQuoted(binary) + " copy-to-clipboard " + SessionRestore.singleQuoted(socketPath)
}
