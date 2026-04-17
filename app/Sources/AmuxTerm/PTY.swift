import Foundation
import Darwin

/// Manages a pseudo-terminal connected to a child process (tmux).
/// Reads output asynchronously via DispatchIO on the main queue.
/// All callbacks fire on main thread — no synchronization needed.
final class PTY {
    let masterFd: Int32
    let childPid: pid_t
    /// The slave TTY device path (e.g., /dev/ttys005). Used to identify
    /// our tmux client when resolving the current session.
    private(set) var slavePath: String?
    private var dispatchIO: DispatchIO?
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    /// Spawn a process in a new PTY.
    init?(executable: String, args: [String], rows: UInt16, cols: UInt16, env: [String: String] = [:]) {
        var master: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var nameBuf = [CChar](repeating: 0, count: 1024)

        let pid = forkpty(&master, &nameBuf, nil, &ws)
        self.slavePath = nil  // initialized here; set to real value below if parent
        guard pid >= 0 else { return nil }

        if pid == 0 {
            // Child process — set env vars and exec
            // TERM must be xterm-256color for tmux to enable extended-keys, truecolor, etc.
            setenv("TERM", "xterm-256color", 1)
            // macOS .app bundles launch with no locale. Without LANG, tmux
            // treats the terminal as non-UTF-8 and replaces Unicode characters
            // (used in border formats, status bar) with underscores.
            setenv("LANG", "en_US.UTF-8", 0)  // 0 = don't overwrite if already set
            for (key, value) in env {
                setenv(key, value, 1)
            }
            let cArgs = args.map { strdup($0) } + [nil]
            _ = executable.withCString { path in execv(path, cArgs) }
            _exit(127)
        }

        self.masterFd = master
        self.childPid = pid
        let name = String(cString: nameBuf)
        self.slavePath = name.isEmpty ? nil : name
    }

    /// Start reading output asynchronously on the main queue.
    func startReading() {
        let io = DispatchIO(type: .stream, fileDescriptor: masterFd,
                            queue: .main, cleanupHandler: { [weak self] _ in
            self?.onExit?()
        })
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: .max, queue: .main) { [weak self] done, data, error in
            if let data = data, !data.isEmpty {
                self?.onOutput?(Data(data))
            }
            // NOTE: onExit is called by the cleanupHandler above, not here.
            // Calling it in both places would fire it twice.
        }
        self.dispatchIO = io
    }

    /// Write to the PTY using DispatchIO (fully async, never blocks UI thread).
    /// GCD handles partial writes, backpressure, and kqueue-based I/O internally.
    /// This is the same approach SwiftTerm uses.
    func write(_ data: Data) {
        let dd = data.withUnsafeBytes { DispatchData(bytes: $0) }
        DispatchIO.write(
            toFileDescriptor: masterFd,
            data: dd,
            runningHandlerOn: .global(qos: .userInteractive),
            handler: { _, _ in }
        )
    }

    /// Resize the PTY (sends SIGWINCH to child).
    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &ws)
    }

    deinit {
        dispatchIO?.close()
        close(masterFd)
    }
}
