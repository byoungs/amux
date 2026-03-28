# Text Selection + Cmd-C Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native mouse text selection with Cmd-C copy to system pasteboard, clamped to the tmux pane containing the click.

**Architecture:** Track selection state (start/end cell positions + pane bounds) on TerminalView. Mouse events map pixel coords to cell positions. Selection is clamped to the tmux pane the click started in (queried via `tmux list-panes`). The draw() method renders a highlight overlay for selected cells. Cmd-C reads selected cells from VTerminal, trims trailing spaces per line, and puts the result on NSPasteboard. New PTY output clears the selection.

**Tech Stack:** AppKit (NSEvent mouse handling), NSPasteboard, tmux CLI (for pane bounds)

---

## File Structure

```
app/Sources/AmuxTerm/
  Selection.swift              # NEW — Selection state, pane bounds, text extraction
  TerminalView.swift           # MODIFY — Add mouse handlers, selection rendering, Cmd-C
  KeyInput.swift               # MODIFY — Handle Cmd-C (return nil to let system route to copy:)
  AppDelegate.swift            # MODIFY — Add Copy menu item
```

---

## Task 1: Selection State and Pane Bounds

**Files:**
- Create: `app/Sources/AmuxTerm/Selection.swift`
- Modify: `app/Sources/AmuxTerm/KeyInput.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift`

- [ ] **Step 1: Create `app/Sources/AmuxTerm/Selection.swift`**

```swift
import Foundation

/// A cell position in the terminal grid.
struct CellPos: Equatable {
    let row: Int
    let col: Int
}

/// A rectangle of cells (a tmux pane's visible area).
struct PaneBounds {
    let top: Int
    let left: Int
    let bottom: Int  // inclusive
    let right: Int   // inclusive

    func contains(_ pos: CellPos) -> Bool {
        pos.row >= top && pos.row <= bottom && pos.col >= left && pos.col <= right
    }

    func clamp(_ pos: CellPos) -> CellPos {
        CellPos(
            row: max(top, min(bottom, pos.row)),
            col: max(left, min(right, pos.col))
        )
    }
}

/// Tracks the current text selection state.
/// Selection is always within a single tmux pane.
final class Selection {
    var start: CellPos?
    var end: CellPos?
    var paneBounds: PaneBounds?

    var isActive: Bool { start != nil && end != nil }

    func clear() {
        start = nil
        end = nil
        paneBounds = nil
    }

    /// Get the normalized selection range (start before end in reading order).
    var normalizedRange: (start: CellPos, end: CellPos)? {
        guard let s = start, let e = end else { return nil }
        if s.row < e.row || (s.row == e.row && s.col <= e.col) {
            return (s, e)
        }
        return (e, s)
    }

    /// Check if a cell is within the current selection.
    func contains(row: Int, col: Int) -> Bool {
        guard let range = normalizedRange else { return false }
        let pos = CellPos(row: row, col: col)
        if row < range.start.row || row > range.end.row { return false }
        if row == range.start.row && row == range.end.row {
            return col >= range.start.col && col <= range.end.col
        }
        if row == range.start.row { return col >= range.start.col }
        if row == range.end.row { return col <= range.end.col }
        return true // middle row, fully selected
    }

    /// Query tmux for pane bounds and find which pane contains the given position.
    /// Returns the PaneBounds for the pane at the given cell position, or nil.
    static func queryPaneBounds(session: String, at pos: CellPos) -> PaneBounds? {
        let process = Process()
        let pipe = Pipe()
        let tmuxPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/tmux")
            ? "/opt/homebrew/bin/tmux"
            : "/usr/local/bin/tmux"
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = [
            "list-panes", "-t", session,
            "-F", "#{pane_top} #{pane_left} #{pane_bottom} #{pane_right}"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 4,
                  let top = Int(parts[0]),
                  let left = Int(parts[1]),
                  let bottom = Int(parts[2]),
                  let right = Int(parts[3]) else { continue }

            let bounds = PaneBounds(top: top, left: left, bottom: bottom, right: right)
            if bounds.contains(pos) {
                return bounds
            }
        }
        return nil
    }

    /// Extract selected text from the terminal, trimming trailing spaces per line.
    func extractText(from terminal: VTerminal) -> String? {
        guard let range = normalizedRange else { return nil }
        var lines: [String] = []

        for row in range.start.row...range.end.row {
            var line = ""
            let colStart = (row == range.start.row) ? range.start.col : (paneBounds?.left ?? 0)
            let colEnd = (row == range.end.row) ? range.end.col : (paneBounds?.right ?? terminal.cols - 1)

            for col in colStart...colEnd {
                let cell = terminal.cell(row: row, col: col)
                let s = VTerminal.cellString(cell)
                line += s.isEmpty ? " " : s
            }

            // Trim trailing spaces
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Add Cmd-C passthrough in KeyInput.swift**

In `KeyInput.swift`, add Cmd-C to the passthrough list alongside Cmd-Q and Cmd-V:

```swift
// After the existing Cmd-V line:
// Cmd-C: let the system handle copy via menu
if hasCmd && chars == "c" { return nil }
```

- [ ] **Step 3: Add Copy menu item in AppDelegate.swift**

In the Edit menu section of `applicationDidFinishLaunching`, add a Copy item:

```swift
editMenu.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
```

- [ ] **Step 4: Build and verify**

Run: `cd app && swift build`
Expected: Compiles (copy(_:) doesn't exist yet on TerminalView, but menu items with missing targets just appear grayed out — this should still compile since it's a selector reference).

If it doesn't compile due to the selector, add a stub `@objc func copy(_ sender: Any?) {}` to TerminalView temporarily.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/AmuxTerm/Selection.swift app/Sources/AmuxTerm/KeyInput.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "add Selection state model with pane bounds and text extraction"
```

---

## Task 2: Mouse Handlers, Selection Rendering, and Cmd-C

**Files:**
- Modify: `app/Sources/AmuxTerm/TerminalView.swift`

This adds mouse event handling (mouseDown/mouseDragged/mouseUp), renders the selection highlight during draw(), and implements Cmd-C copy.

- [ ] **Step 1: Add selection state and mouse-to-cell conversion to TerminalView**

At the top of the class, add:

```swift
    let selection = Selection()
    private let selectionSession = "amux-dev"  // must match AppDelegate
```

Add a helper method to convert pixel coordinates to cell positions:

```swift
    // MARK: - Selection

    private func cellPosition(for event: NSEvent) -> CellPos {
        let point = convert(event.locationInWindow, from: nil)
        let row = max(0, min(terminal.rows - 1, Int(point.y / cellHeight)))
        let col = max(0, min(terminal.cols - 1, Int(point.x / cellWidth)))
        return CellPos(row: row, col: col)
    }
```

- [ ] **Step 2: Add mouse event handlers**

```swift
    override func mouseDown(with event: NSEvent) {
        let pos = cellPosition(for: event)

        // Query tmux for pane bounds at click position
        if let bounds = Selection.queryPaneBounds(session: selectionSession, at: pos) {
            selection.paneBounds = bounds
            selection.start = bounds.clamp(pos)
            selection.end = selection.start
        } else {
            // No pane found — select across entire grid
            selection.paneBounds = nil
            selection.start = pos
            selection.end = pos
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard selection.start != nil else { return }
        var pos = cellPosition(for: event)
        if let bounds = selection.paneBounds {
            pos = bounds.clamp(pos)
        }
        selection.end = pos
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Selection finalized — if start == end, clear it (it was just a click)
        if selection.start == selection.end {
            selection.clear()
            needsDisplay = true
        }
    }
```

- [ ] **Step 3: Modify draw() to render selection highlight**

In the `draw(_ dirtyRect:)` method, after the cell rendering loop and before the cursor drawing, add:

```swift
        // Draw selection highlight
        if selection.isActive {
            drawSelection(ctx: ctx)
        }
```

Add the drawSelection method:

```swift
    private func drawSelection(ctx: CGContext) {
        let selectionColor = CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.35)
        ctx.setFillColor(selectionColor)

        for row in 0..<terminal.rows {
            for col in 0..<terminal.cols {
                if selection.contains(row: row, col: col) {
                    let x = CGFloat(col) * cellWidth
                    let y = CGFloat(row) * cellHeight
                    ctx.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
                }
            }
        }
    }
```

- [ ] **Step 4: Implement Cmd-C copy**

```swift
    @objc func copy(_ sender: Any?) {
        guard let text = selection.extractText(from: terminal) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clear selection after copy (visual feedback that it worked)
        selection.clear()
        needsDisplay = true
    }
```

- [ ] **Step 5: Clear selection on new PTY output**

Modify the `pty.onOutput` closure in `init` to clear selection when new data arrives:

```swift
        pty.onOutput = { [weak self] data in
            guard let self = self else { return }
            self.terminal.write(data: data)
            self.terminal.isDirty = true
            // Clear selection when terminal content changes
            if self.selection.isActive {
                self.selection.clear()
            }
        }
```

- [ ] **Step 6: Build and verify**

Run: `cd app && swift build`
Expected: Compiles without errors.

- [ ] **Step 7: Manual test**

Launch: `app/.build/debug/amux-term`
Test:
- Click and drag to select text — blue highlight should appear
- Selection stays within the tmux pane (doesn't cross borders)
- Cmd-C copies selected text
- Open another app, Cmd-V — pasted text should match selection
- Selection clears when new terminal output arrives
- Selection clears after Cmd-C
- Single click (no drag) does NOT leave a selection

- [ ] **Step 8: Commit**

```bash
git add app/Sources/AmuxTerm/TerminalView.swift
git commit -m "add native text selection with Cmd-C copy, clamped to pane bounds"
```

---

## Verification Checklist

- [ ] `make app-test` still passes (KeyInput tests)
- [ ] Click-drag selects text with visible blue highlight
- [ ] Selection is clamped to a single tmux pane
- [ ] Cmd-C copies selected text to system pasteboard
- [ ] Pasting in another app shows the correct text
- [ ] Trailing spaces are trimmed per line
- [ ] Selection clears on Cmd-C
- [ ] Selection clears when terminal output changes
- [ ] Single click without drag does not leave selection
