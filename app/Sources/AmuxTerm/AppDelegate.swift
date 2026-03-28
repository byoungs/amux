import AppKit
import CVterm

@main
struct AmuxTermApp {
    static func main() {
        // --run-tests: run KeyInput tests and exit without launching GUI
        if CommandLine.arguments.contains("--run-tests") {
            #if DEBUG
            KeyInputTests.runAll()
            print("All tests passed")
            #else
            print("Tests only available in debug builds")
            #endif
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var termView: TerminalView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Find the amux binary (installed by make dev)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let amuxPath = "\(home)/.cargo/bin/amux"
        guard FileManager.default.fileExists(atPath: amuxPath) else {
            fatalError("amux not found at \(amuxPath). Run: make dev")
        }

        let rows: UInt16 = 40
        let cols: UInt16 = 120
        let terminal = VTerminal(rows: Int(rows), cols: Int(cols))

        // Run amux — it either attaches to existing workspace or creates a new one
        // with full setup (grid layout, borders, keybindings, hooks)
        guard let pty = PTY(executable: amuxPath,
                            args: ["amux"],
                            rows: rows, cols: cols) else {
            fatalError("Failed to create PTY")
        }

        let termView = TerminalView(terminal: terminal, pty: pty)
        self.termView = termView

        pty.onExit = {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "amux"
        window.contentView = termView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(termView)
        self.window = window

        // Menu bar
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit amux",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(TerminalView.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(TerminalView.paste(_:)),
                         keyEquivalent: "v")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = menuBar

        // Intercept Cmd-=/Cmd-- at the application level.
        // macOS may claim these keys for system zoom before performKeyEquivalent
        // reaches our view. This local monitor catches them first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.modifierFlags.contains(.command),
                  let chars = event.charactersIgnoringModifiers else { return event }

            #if DEBUG
            // Cmd-Shift-D: toggle latency profiling
            if chars == "d" && event.modifierFlags.contains(.shift) {
                if let tv = self.termView {
                    tv.profilingEnabled.toggle()
                    fputs("=== Latency profiling \(tv.profilingEnabled ? "ON" : "OFF") ===\n", stderr)
                    fputs("Type to see: PTY roundtrip + draw time + total key→pixel\n", stderr)
                }
                return nil
            }
            #endif

            // Only intercept keys that KeyInput handles (not Cmd-Q, Cmd-C, Cmd-V)
            if ["=", "-", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                "n", "p", "s", "l"].contains(chars) {
                if let data = KeyInput.bytes(for: event) {
                    self.termView?.pty.write(data)
                    return nil  // consumed — don't pass to menu bar
                }
            }
            return event  // pass through
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
