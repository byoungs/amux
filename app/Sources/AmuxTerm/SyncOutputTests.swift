#if DEBUG
import Foundation

/// Tests for DEC 2026 synchronized output (BSU/ESU) handling.
///
/// The bug these pin down: amux advertises `sync` in tmux's terminal-features
/// (Config.swift), so tmux brackets every screen update in
/// `ESC [ ? 2026 h` … `ESC [ ? 2026 l`. The kernel pty splits those updates at
/// arbitrary byte boundaries (1024 bytes in captured traces), and amux paints
/// one frame per read chunk — so it painted frames from the middle of an
/// update, where tmux has the cursor hidden and parked at its scratch drawing
/// position. The next chunk restored it. That off/on cycle is the flicker.
enum SyncOutputTests {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passed += 1
            } else {
                failed += 1
                FileHandle.standardError.write(
                    "FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")\n".data(using: .utf8)!)
            }
        }

        func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

        // --- Test 1: BSU opens an update, ESU closes it ---
        do {
            var scanner = SyncOutputScanner()
            scanner.scan(bytes("\u{1B}[?2026h"))
            check("sync-bsu-opens", scanner.isInsideUpdate)
            scanner.scan(bytes("\u{1B}[?2026l"))
            check("sync-esu-closes", !scanner.isInsideUpdate)
        }

        // --- Test 2: BSU split across read chunks still opens ---
        // This is the whole point: the pty tears the stream mid-sequence.
        do {
            var scanner = SyncOutputScanner()
            scanner.scan(bytes("some text\u{1B}[?20"))
            check("sync-split-not-yet-open", !scanner.isInsideUpdate,
                  "half a BSU must not open an update")
            scanner.scan(bytes("26h"))
            check("sync-split-bsu-opens", scanner.isInsideUpdate,
                  "BSU split across chunks must still be recognized")
        }

        // --- Test 3: 2026 among several DECSET params ---
        do {
            var scanner = SyncOutputScanner()
            scanner.scan(bytes("\u{1B}[?25;2026h"))
            check("sync-multi-param-opens", scanner.isInsideUpdate)
        }

        // --- Test 4: unrelated private modes leave the gate alone ---
        do {
            var scanner = SyncOutputScanner()
            scanner.scan(bytes("\u{1B}[?25l\u{1B}[?1049h\u{1B}[?1006l\u{1B}[H\u{1B}[2J"))
            check("sync-other-modes-ignored", !scanner.isInsideUpdate)
        }

        // --- Test 5: near-misses must not match ---
        do {
            var scanner = SyncOutputScanner()
            scanner.scan(bytes("\u{1B}[?12026h"))       // param is 12026, not 2026
            check("sync-superstring-param-ignored", !scanner.isInsideUpdate)
            scanner.scan(bytes("\u{1B}[?2026$p"))       // DECRQM query, not a set
            check("sync-decrqm-query-ignored", !scanner.isInsideUpdate)
        }

        // --- Test 6: a torn tmux update never exposes a paintable frame ---
        // Chunk 1 is the shape captured from a real two-pane tmux update cut
        // at a 1024-byte pty boundary: BSU, cursor hidden, cursor parked in
        // the pane being drawn. Chunk 2 finishes the update, restores the
        // cursor to the prompt and closes with ESU.
        do {
            let term = VTerminal(rows: 40, cols: 120)
            // Establish a visible cursor at the prompt (row 1, col 22).
            term.write(data: Data(bytes("\u{1B}[?25h\u{1B}[2;23H")))
            term.flushDamage()
            check("sync-torn-precondition", term.cursorVisible && term.cursorRow == 1,
                  "expected visible cursor at row 1, got visible=\(term.cursorVisible) row=\(term.cursorRow)")

            // Chunk 1 — torn: opens the update, hides the cursor, moves it into
            // the other pane, draws, and stops mid-stream.
            term.write(data: Data(bytes(
                "\u{1B}[?2026h\u{1B}[?25l\u{1B}[25;29HTue Jul 28 14:07:44 EDT 2026\u{1B}[K")))
            term.flushDamage()
            check("sync-torn-chunk-holds-frame", term.isInsideSyncUpdate,
                  "renderer must hold: the update is incomplete")
            check("sync-torn-chunk-is-unpaintable", !term.cursorVisible,
                  "torn state is exactly what must never reach the screen")

            // Chunk 2 — completes the update.
            term.write(data: Data(bytes(
                "\u{1B}[26;29HTue Jul 28 14:07:45 EDT 2026\u{1B}[K\u{1B}[2;23H\u{1B}[?25h\u{1B}[?2026l")))
            term.flushDamage()
            check("sync-complete-releases-frame", !term.isInsideSyncUpdate,
                  "ESU must release the held frame")
            check("sync-released-frame-has-cursor", term.cursorVisible && term.cursorRow == 1,
                  "the one painted frame must show the cursor back at the prompt, "
                  + "got visible=\(term.cursorVisible) row=\(term.cursorRow)")
        }

        // --- Test 7: a stream with no BSU is never held ---
        do {
            let term = VTerminal(rows: 40, cols: 120)
            term.write(data: Data(bytes("plain output, no synchronized update\r\n")))
            check("sync-absent-never-holds", !term.isInsideSyncUpdate)
        }

        // --- Test 8: the hold expires so a crashed app can't freeze the view ---
        do {
            check("sync-hold-active-before-timeout",
                  !SyncOutput.holdExpired(openedAt: 100.0, now: 100.05, timeout: 0.15))
            check("sync-hold-expires-after-timeout",
                  SyncOutput.holdExpired(openedAt: 100.0, now: 100.2, timeout: 0.15))
        }

        print("SyncOutput tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("SyncOutput tests failed") }
    }
}
#endif
