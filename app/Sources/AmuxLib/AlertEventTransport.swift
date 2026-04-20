// AlertEventTransport.swift — one-shot IPC from amux-cli to amux-app.
//
// amux-cli fires on tmux hooks. It has no UNUserNotificationCenter (a CLI
// invocation cannot post actionable macOS notifications that route clicks
// back to amux). amux-app is the long-lived bundled process that owns
// that capability. This file defines the transport between them.
//
// Wire shape: Unix-domain stream socket. Client connects, writes a single
// JSON-encoded AlertEvent, closes. Server accepts, reads until EOF, decodes,
// hands the event to its handler, closes. One event per connection — no
// length prefix needed.
//
// Design notes:
//   - Client send is fire-and-forget from the caller's point of view, but
//     still synchronous at the syscall level: connect, write, close.
//     A missing server surfaces as `.notListening` so the caller can
//     decide to skip / warn / spawn amux-app.
//   - Server runs its accept loop on a dedicated background thread. The
//     handler is invoked on that thread — UI work must dispatch to main.
//   - Server unlinks any stale socket file before binding so a prior
//     crash does not permanently wedge the socket path.
//   - stop() is idempotent. It closes the listening FD (which unblocks
//     accept()), sets an atomic "stopping" flag so the loop exits cleanly,
//     joins the worker thread, and unlinks the socket file.

import Foundation
import Darwin

// MARK: - Types

public struct AlertEvent: Codable, Equatable, Sendable {
    public let session: String
    public let pane: Int
    public let terminalFrontmost: Bool

    public init(session: String, pane: Int, terminalFrontmost: Bool) {
        self.session = session
        self.pane = pane
        self.terminalFrontmost = terminalFrontmost
    }
}

public enum AlertTransportError: Error, Equatable {
    case notListening
    case io(String)
    case decode(String)
}

// MARK: - Protocols

/// Client: amux-cli uses this to fire-and-forget an event.
public protocol AlertEventClient {
    /// Throws AlertTransportError.notListening if nobody accepted,
    /// AlertTransportError.io(...) for other socket failures.
    func send(_ event: AlertEvent) throws
}

/// Server: amux-app uses this to receive events.
public protocol AlertEventServer {
    /// Start listening. `handler` is called on every received event.
    /// Handler may be invoked from a background thread — caller is
    /// responsible for dispatching to main if needed.
    func start(handler: @escaping (AlertEvent) -> Void) throws
    /// Stop listening and release the socket. Idempotent.
    func stop()
}

// MARK: - Default path

/// Default socket path for the current user on macOS.
/// Uses NSTemporaryDirectory() which is per-UID on Darwin — no collision
/// between users, no need for /tmp path-length workarounds.
public func defaultAlertSocketPath() -> String {
    let base = NSTemporaryDirectory()
    // Trim any trailing slash so we don't produce "//amux-alert.sock".
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    return "\(trimmed)/amux-alert.sock"
}

// MARK: - Low-level helpers

/// Build a sockaddr_un for the given path.
/// Returns nil if the path is too long to fit in sun_path.
private func makeSockaddrUn(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    // sun_path is a fixed-size tuple; withUnsafeMutableBytes gives us its
    // capacity. Need a trailing NUL, so max usable length is capacity-1.
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    if pathBytes.count >= capacity { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let buf = raw.bindMemory(to: CChar.self)
        for i in 0..<pathBytes.count {
            buf[i] = CChar(bitPattern: pathBytes[i])
        }
        buf[pathBytes.count] = 0
    }
    return addr
}

/// errno text helper for wrapping failures in AlertTransportError.io.
private func errnoText(_ prefix: String) -> String {
    let code = errno
    let msg = String(cString: strerror(code))
    return "\(prefix): \(msg) (errno \(code))"
}

// MARK: - Live client

public final class UnixSocketAlertEventClient: AlertEventClient {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ event: AlertEvent) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(event)
        } catch {
            throw AlertTransportError.io("encode: \(error)")
        }

        guard var addr = makeSockaddrUn(path: socketPath) else {
            throw AlertTransportError.io("socket path too long: \(socketPath)")
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw AlertTransportError.io(errnoText("socket"))
        }
        defer { Darwin.close(fd) }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, addrLen)
            }
        }
        if connectResult < 0 {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED {
                throw AlertTransportError.notListening
            }
            throw AlertTransportError.io(errnoText("connect"))
        }

        // Write the whole payload. Small JSON blob; one write usually
        // suffices, but loop for partial writes to be correct.
        try data.withUnsafeBytes { raw in
            var remaining = raw.count
            var offset = 0
            let base = raw.baseAddress!
            while remaining > 0 {
                let n = Darwin.write(fd, base.advanced(by: offset), remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AlertTransportError.io(errnoText("write"))
                }
                if n == 0 {
                    throw AlertTransportError.io("write returned 0 with \(remaining) bytes remaining")
                }
                offset += n
                remaining -= n
            }
        }
        // Closing via `defer` signals EOF to the server.
    }
}

// MARK: - Live server

public final class UnixSocketAlertEventServer: AlertEventServer {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    // Atomic-ish stop flag: Swift has no stdlib atomics on macOS 14 target,
    // but Int32 writes are aligned and a single 32-bit store is atomic on
    // arm64/x86_64. Reads see torn values only on sub-32-bit types.
    private var stopping: Int32 = 0
    private let lock = NSLock()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start(handler: @escaping (AlertEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        if listenFD >= 0 {
            throw AlertTransportError.io("server already started")
        }

        // Unlink any stale socket file so bind() does not EADDRINUSE.
        // Swallow errors — if the file doesn't exist, that's fine; if it
        // exists but we can't remove it, bind() will surface that.
        unlink(socketPath)

        guard var addr = makeSockaddrUn(path: socketPath) else {
            throw AlertTransportError.io("socket path too long: \(socketPath)")
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw AlertTransportError.io(errnoText("socket"))
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, addrLen)
            }
        }
        if bindResult < 0 {
            let text = errnoText("bind")
            Darwin.close(fd)
            throw AlertTransportError.io(text)
        }

        if Darwin.listen(fd, 16) < 0 {
            let text = errnoText("listen")
            Darwin.close(fd)
            unlink(socketPath)
            throw AlertTransportError.io(text)
        }

        self.listenFD = fd
        self.stopping = 0

        let thread = Thread { [weak self] in
            self?.acceptLoop(fd: fd, handler: handler)
        }
        thread.name = "amux.AlertEventServer"
        self.acceptThread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let thread = acceptThread
        listenFD = -1
        acceptThread = nil
        stopping = 1
        lock.unlock()

        if fd < 0 {
            // Already stopped. Unlink is still safe (unlink of non-existent
            // file just returns ENOENT which we ignore).
            unlink(socketPath)
            return
        }

        // Closing the listening FD unblocks accept() with EBADF.
        Darwin.close(fd)
        unlink(socketPath)

        // Wait for the accept thread to finish so handler invocations
        // don't outlive stop(). Thread.join isn't in Foundation; poll
        // isFinished with a short sleep, capped to avoid hanging.
        if let thread = thread {
            let deadline = Date().addingTimeInterval(2.0)
            while !thread.isFinished && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private func acceptLoop(fd: Int32, handler: @escaping (AlertEvent) -> Void) {
        while stopping == 0 {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(fd, &clientAddr, &clientLen)
            if client < 0 {
                // EBADF / EINVAL happens when stop() closes the listening
                // FD; that's our exit condition. EINTR = retry.
                if errno == EINTR { continue }
                break
            }
            handleConnection(fd: client, handler: handler)
            Darwin.close(client)
        }
    }

    private func handleConnection(fd: Int32, handler: (AlertEvent) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return // read error; drop this connection
            }
            if n == 0 { break } // EOF — client closed
            buffer.append(chunk, count: n)
            // Cap at 64KB to bound memory on a misbehaving client.
            if buffer.count > 65_536 { return }
        }
        guard !buffer.isEmpty else { return }
        do {
            let event = try JSONDecoder().decode(AlertEvent.self, from: buffer)
            handler(event)
        } catch {
            // Silently drop undecodable payloads. Tests use the recording
            // handler to assert successful decodes; malformed payloads
            // are not in scope for this transport.
            return
        }
    }
}

// MARK: - Test doubles

/// Test double for other agents' tests.
public final class RecordingAlertEventClient: AlertEventClient {
    public private(set) var sent: [AlertEvent] = []
    public init() {}
    public func send(_ event: AlertEvent) throws {
        sent.append(event)
    }
}

// MARK: - Tests

#if DEBUG
public enum AlertEventTransportTests {
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

        // --- 1. AlertEvent JSON round-trip ---
        do {
            let event = AlertEvent(session: "work", pane: 3, terminalFrontmost: true)
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(AlertEvent.self, from: data)
            check("roundtrip-equal", decoded == event)
            check("roundtrip-session", decoded.session == "work")
            check("roundtrip-pane", decoded.pane == 3)
            check("roundtrip-frontmost", decoded.terminalFrontmost == true)
        } catch {
            check("roundtrip", false, "threw: \(error)")
        }

        // --- 2. RecordingAlertEventClient records in order ---
        do {
            let rec = RecordingAlertEventClient()
            check("recording-emptyAtStart", rec.sent.isEmpty)
            let a = AlertEvent(session: "a", pane: 0, terminalFrontmost: false)
            let b = AlertEvent(session: "b", pane: 1, terminalFrontmost: true)
            let c = AlertEvent(session: "c", pane: 2, terminalFrontmost: false)
            try? rec.send(a)
            try? rec.send(b)
            try? rec.send(c)
            check("recording-count", rec.sent.count == 3)
            check("recording-order", rec.sent == [a, b, c])
        }

        // --- 3. Live round-trip: server + client, 3 events ---
        do {
            let path = NSTemporaryDirectory() + "amux-t-rt-\(UUID().uuidString).sock"
            defer { unlink(path) }
            let server = UnixSocketAlertEventServer(socketPath: path)
            let received = ReceivedEventBox()
            do {
                try server.start { event in
                    received.append(event)
                }
            } catch {
                check("liveRoundTrip-startFailed", false, "\(error)")
                return finish(passed: passed, failed: failed)
            }
            defer { server.stop() }

            let client = UnixSocketAlertEventClient(socketPath: path)
            let events = [
                AlertEvent(session: "alpha", pane: 0, terminalFrontmost: false),
                AlertEvent(session: "beta", pane: 1, terminalFrontmost: true),
                AlertEvent(session: "gamma", pane: 2, terminalFrontmost: false),
            ]
            var sendErrors = 0
            for e in events {
                do { try client.send(e) }
                catch { sendErrors += 1 }
            }
            check("liveRoundTrip-noSendErrors", sendErrors == 0,
                  "\(sendErrors) send errors")

            // Wait (cap 2s) for all 3 to arrive.
            let deadline = Date().addingTimeInterval(2.0)
            while received.count < 3 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            check("liveRoundTrip-receivedCount", received.count == 3,
                  "received \(received.count) of 3 events")
            check("liveRoundTrip-orderAndPayload",
                  received.events == events,
                  "events mismatch: got \(received.events)")
        }

        // --- 4. send to non-listening path → .notListening ---
        do {
            let path = NSTemporaryDirectory() + "amux-t-nl-\(UUID().uuidString).sock"
            // Make sure no file there so we get ENOENT, not ECONNREFUSED.
            unlink(path)
            let client = UnixSocketAlertEventClient(socketPath: path)
            do {
                try client.send(AlertEvent(session: "s", pane: 0, terminalFrontmost: false))
                check("noListener-throws", false, "send did not throw")
            } catch let err as AlertTransportError {
                check("noListener-throwsNotListening",
                      err == .notListening,
                      "got \(err)")
            } catch {
                check("noListener-wrongType", false, "\(error)")
            }
        }

        // --- 5. Stale socket file removed by server on start() ---
        do {
            let path = NSTemporaryDirectory() + "amux-t-st-\(UUID().uuidString).sock"
            // Create an empty file where the socket will go.
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
            check("stale-filePresent",
                  FileManager.default.fileExists(atPath: path))
            defer { unlink(path) }

            let server = UnixSocketAlertEventServer(socketPath: path)
            let received = ReceivedEventBox()
            do {
                try server.start { received.append($0) }
            } catch {
                check("stale-startFailed", false, "\(error)")
                return finish(passed: passed, failed: failed)
            }
            defer { server.stop() }

            let client = UnixSocketAlertEventClient(socketPath: path)
            let event = AlertEvent(session: "s", pane: 9, terminalFrontmost: false)
            do {
                try client.send(event)
                check("stale-sendOK", true)
            } catch {
                check("stale-sendFailed", false, "\(error)")
            }
            let deadline = Date().addingTimeInterval(2.0)
            while received.count < 1 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            check("stale-received",
                  received.count == 1 && received.events.first == event,
                  "stale socket should have been removed, got \(received.count) events")
        }

        // --- 6. stop() is idempotent ---
        do {
            let path = NSTemporaryDirectory() + "amux-t-sp-\(UUID().uuidString).sock"
            defer { unlink(path) }
            let server = UnixSocketAlertEventServer(socketPath: path)
            do {
                try server.start { _ in }
            } catch {
                check("stopIdempotent-start", false, "\(error)")
                return finish(passed: passed, failed: failed)
            }
            server.stop()
            server.stop() // must not crash or throw
            check("stopIdempotent-survives", true)
        }

        finish(passed: passed, failed: failed)
    }

    private static func finish(passed: Int, failed: Int) {
        print("AlertEventTransport tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("AlertEventTransport tests failed") }
    }

    /// Thread-safe receive-list for the live round-trip test. Handler fires
    /// on the server's accept thread; main thread polls count until the
    /// expected events arrive.
    private final class ReceivedEventBox {
        private let lock = NSLock()
        private var _events: [AlertEvent] = []

        func append(_ event: AlertEvent) {
            lock.lock(); defer { lock.unlock() }
            _events.append(event)
        }

        var events: [AlertEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _events.count
        }
    }
}
#endif
