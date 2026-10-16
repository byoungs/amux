import Foundation

/// Open an existing space in an additional native window without switching
/// or detaching any client. Sent by the Spaces popup to its owning app.
public struct WindowRequest: Codable, Equatable {
    public let session: String
    public init(session: String) { self.session = session }
}

public typealias UnixSocketWindowRequestClient = UnixSocketMessageClient<WindowRequest>
public typealias UnixSocketWindowRequestServer = UnixSocketMessageServer<WindowRequest>

public func defaultWindowSocketPath() -> String {
    URL(fileURLWithPath: defaultAlertSocketPath()).deletingLastPathComponent()
        .appendingPathComponent("amux-windows.sock").path
}
