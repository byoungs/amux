# Permission Peek Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect Claude permission prompts in background tmux panes by polling rendered pane text, surface them in a bottom-right badge, and let the user answer (`1`/`2`), engage (`3`), or dismiss (`Esc`) from a `Cmd-Y` popup without leaving their current pane.

**Architecture:** Functional core + imperative shell, matching the codebase (`LayoutEngine` is the model). Pure, tmux-free logic in `AmuxLib` (`PermissionPrompt` parser, `PromptQueue` state machine, answer-key mapping). Two new `Tmux` wrappers (`capturePane`, `sendKeys`) with `FakeTmux` handlers. A `PermissionWatcher` timer in `AmuxTerm` polls every 4s, feeds the queue, and drives a `TerminalView` overlay (badge + popup). `Cmd-Y` toggles the popup.

**Tech Stack:** Swift 5.9, AppKit (AmuxTerm), no XCTest — tests are `enum XTests { static func runAll() }` suites (pure logic, run via `amux-app --run-tests`) and integration suites in `app/Tests/` returning `(passed, failed)` against real tmux (`make validate`).

---

## File Structure

**Create:**
- `app/Sources/AmuxLib/PermissionPrompt.swift` — `PermissionPrompt`/`PromptOption` types, `detectPermissionPrompt(_:)` parser, `answerKeys(for:)` mapping. Pure.
- `app/Sources/AmuxLib/PermissionPromptTests.swift` — parser + mapping unit tests.
- `app/Sources/AmuxLib/PromptQueue.swift` — `QueuedPrompt`, `PromptQueue` FIFO state machine. Pure.
- `app/Sources/AmuxLib/PromptQueueTests.swift` — queue unit tests.
- `app/Sources/AmuxTerm/PermissionWatcher.swift` — timer-driven poll loop (imperative shell).
- `app/Tests/Fixtures/` — real `capture-pane` fixtures from Task 1.
- `app/Tests/PermissionCaptureTests.swift` — integration: real tmux `capture-pane`/`send-keys` round-trips.
- `docs/superpowers/specs/2026-05-26-permission-peek-sendkeys-notes.md` — verified answer-key sequence (Task 1 output).

**Modify:**
- `app/Sources/AmuxLib/Tmux.swift` — add `capturePane`, `sendKeys` wrappers.
- `app/Sources/AmuxLib/FakeTmux.swift` — add `capture-pane`/`send-keys` handlers + `FakePane.content`/`sentKeys` + builders.
- `app/Sources/AmuxLib/FakeTmuxTests.swift` — cover the two new handlers.
- `app/Sources/AmuxLib/KeyAction.swift` — add `AmuxCommand.peek`; map `Cmd-Y` in `KeyCommand`.
- `app/Sources/AmuxTerm/KeyInputTests.swift` — cover `Cmd-Y → .peek`.
- `app/Sources/AmuxTerm/TerminalView.swift` — badge + popup overlay drawing + popup key handling.
- `app/Sources/AmuxTerm/AppDelegate.swift` — start `PermissionWatcher`; route `Cmd-Y` and popup keys; register new test suites in `--run-tests`.
- `app/Tests/main.swift` — register `PermissionCaptureTests`.

---

## Task 1: Spike — capture real fixtures + verify answer keys (human-assisted)

**This task is interactive: it needs a live `claude` session sitting on a real permission prompt inside tmux. It is NOT subagent-automatable. Do it with Brian at the keyboard. It produces committed artifacts that Tasks 2 and 6 depend on — do not write the parser or answer mapping before this lands.**

**Files:**
- Create: `app/Tests/Fixtures/permission-bash.txt`, `permission-edit.txt`, `permission-mcp.txt`
- Create: `docs/superpowers/specs/2026-05-26-permission-peek-sendkeys-notes.md`

- [ ] **Step 1: Capture a real Bash permission box**

In a tmux pane running `claude`, trigger a command that prompts for permission (e.g. ask it to run a shell command). When the box is on screen, from another shell:

```bash
tmux list-panes -a -F '#{session_name}:#{pane_index} #{pane_id} #{pane_title}'   # find the pane id, e.g. %7
tmux capture-pane -p -t %7 -S -30 > app/Tests/Fixtures/permission-bash.txt
```

Expected: `permission-bash.txt` contains the rendered box (borders, the question line, and the numbered options). Open it and confirm the option lines and the exact selection glyph (e.g. `❯`) are present.

- [ ] **Step 2: Capture an edit-file and an MCP-tool prompt the same way**

Repeat Step 1 for a file-edit prompt (`permission-edit.txt`) and an MCP/tool prompt (`permission-mcp.txt`). These cover label/option-count variants ("Do you want to make this edit to X?", 2-option vs 3-option).

- [ ] **Step 3: Verify the answer keystroke mechanism**

With a permission box live on pane `%7`, from another shell test which keystroke selects "Yes":

```bash
tmux send-keys -t %7 1        # hypothesis A: number selects+confirms
# observe the pane: did it accept "Yes" and proceed?
```

If `1` alone did not confirm, test `tmux send-keys -t %7 1 Enter`, and separately test bare `Enter` (accept highlighted default) and `Escape` (cancel). Record exactly what each does.

- [ ] **Step 4: Write the findings doc**

Create `docs/superpowers/specs/2026-05-26-permission-peek-sendkeys-notes.md` recording: the exact selection glyph, the exact question strings seen, and the verified keystroke(s) for Yes / Yes-don't-ask / cancel. This is the source of truth for Task 2's anchors and Task 6's mapping.

- [ ] **Step 5: Commit**

```bash
git add app/Tests/Fixtures/permission-bash.txt app/Tests/Fixtures/permission-edit.txt app/Tests/Fixtures/permission-mcp.txt docs/superpowers/specs/2026-05-26-permission-peek-sendkeys-notes.md
git commit -m "Add real Claude permission-prompt fixtures and verified answer-key notes"
```

---

## Task 2: PermissionPrompt model + parser

**Files:**
- Create: `app/Sources/AmuxLib/PermissionPrompt.swift`
- Create: `app/Sources/AmuxLib/PermissionPromptTests.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift` (register test suite)

> Build the parser against the **real** `app/Tests/Fixtures/*.txt` from Task 1. The fixture strings in the test below are a reference of the expected shape; replace them with the committed fixtures (load via `String(contentsOfFile:)` in the integration test, Task split below) and adjust the anchors (selection glyph, question strings) to match what Task 1 actually captured.

- [ ] **Step 1: Write the failing test**

Create `app/Sources/AmuxLib/PermissionPromptTests.swift`:

```swift
#if DEBUG
import Foundation

public enum PermissionPromptTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        // Reference fixture shaped like a real `capture-pane` of a Bash prompt.
        let bash = """
        ╭─────────────────────────────────────────────╮
        │ Bash command                                  │
        │                                               │
        │   npm install                                 │
        │   Install dependencies                        │
        │                                               │
        │ Do you want to proceed?                       │
        │ ❯ 1. Yes                                      │
        │   2. Yes, and don't ask again for npm         │
        │   3. No, and tell Claude what to do differently│
        ╰─────────────────────────────────────────────╯
        """

        if let p = detectPermissionPrompt(bash) {
            check("bash-question", p.question == "Do you want to proceed?", p.question)
            check("bash-optcount", p.options.count == 3, "\(p.options.count)")
            check("bash-opt1", p.options.first?.label == "Yes")
            check("bash-opt1-num", p.options.first?.number == 1)
            check("bash-selected", p.options.first?.selected == true)
            check("bash-opt3-label", p.options.last?.label.hasPrefix("No,") == true, p.options.last?.label ?? "nil")
        } else {
            check("bash-detected", false, "parser returned nil")
        }

        // Negative: ordinary chat text with a numbered list must NOT detect.
        let chat = """
        Here are the steps:
        1. Yes you can do that
        2. No you cannot
        Let me know.
        """
        check("chat-not-detected", detectPermissionPrompt(chat) == nil)

        // Negative: empty / whitespace.
        check("empty-not-detected", detectPermissionPrompt("   \n  ") == nil)

        print("PermissionPrompt tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PermissionPrompt tests failed") }
    }
}
#endif
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test` (or `swift run amux-app --run-tests` from `app/`)
Expected: compile error — `detectPermissionPrompt` / `PermissionPrompt` not defined. (Add `PermissionPromptTests.runAll()` to `AppDelegate.swift` `--run-tests` block first; see Step 5.)

- [ ] **Step 3: Write the implementation**

Create `app/Sources/AmuxLib/PermissionPrompt.swift`:

```swift
// PermissionPrompt.swift — pure detection of a Claude permission prompt
// from rendered pane text (as produced by `tmux capture-pane -p`).
// No tmux dependency. Tested against real captured fixtures.

import Foundation

public struct PromptOption: Equatable {
    public let number: Int
    public let label: String      // e.g. "Yes" / "Yes, and don't ask again…" / "No, and tell Claude…"
    public let selected: Bool     // true if this row carried the selection glyph

    public init(number: Int, label: String, selected: Bool) {
        self.number = number
        self.label = label
        self.selected = selected
    }
}

public struct PermissionPrompt: Equatable {
    public let question: String
    public let options: [PromptOption]

    public init(question: String, options: [PromptOption]) {
        self.question = question
        self.options = options
    }

    /// The reject option (Claude always lists "No" last). Selecting it
    /// engages (full-screen the pane) rather than answering in place,
    /// because a bare "No" leaves Claude waiting for typed follow-up.
    public var rejectOption: PromptOption? { options.last }
}

/// Selection glyph(s) Claude uses to mark the highlighted option.
/// Confirm against Task 1's fixtures; add any variant observed.
private let selectionGlyphs: Set<Character> = ["❯", ">", "›", "»"]

/// Strip box-drawing border characters and surrounding whitespace from a line.
private func stripBorder(_ line: String) -> String {
    let borderChars: Set<Character> = ["│", "╭", "╮", "╰", "╯", "─", "┌", "┐", "└", "┘", "├", "┤"]
    var s = line
    while let f = s.first, f.isWhitespace || borderChars.contains(f) { s.removeFirst() }
    while let l = s.last, l.isWhitespace || borderChars.contains(l) { s.removeLast() }
    return s
}

/// Parse one option line like "❯ 1. Yes" → (1, "Yes", selected:true), else nil.
private func parseOption(_ stripped: String) -> PromptOption? {
    var s = stripped
    var selected = false
    if let f = s.first, selectionGlyphs.contains(f) {
        selected = true
        s.removeFirst()
        s = s.trimmingCharacters(in: .whitespaces)
    }
    // Expect "<digits>. <text>"
    guard let dot = s.firstIndex(of: "."), dot != s.startIndex else { return nil }
    let numPart = s[s.startIndex..<dot]
    guard let number = Int(numPart), !numPart.isEmpty else { return nil }
    let label = s[s.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return PromptOption(number: number, label: label, selected: selected)
}

/// Detect a permission prompt in rendered pane text.
///
/// Anchors (all required) to avoid false positives on ordinary chat:
///   1. A run of ≥2 consecutive numbered option lines (1., 2., …).
///   2. At least one option whose label starts with "Yes".
///   3. A non-empty question line ending in "?" immediately above the run.
public func detectPermissionPrompt(_ text: String) -> PermissionPrompt? {
    let rawLines = text.components(separatedBy: "\n")
    let stripped = rawLines.map(stripBorder)

    // Find the start of a contiguous numbered-option run.
    var i = 0
    while i < stripped.count {
        if let first = parseOption(stripped[i]), first.number == 1 {
            var options: [PromptOption] = [first]
            var j = i + 1
            while j < stripped.count, let opt = parseOption(stripped[j]),
                  opt.number == options.count + 1 {
                options.append(opt)
                j += 1
            }
            if options.count >= 2, options.contains(where: { $0.label.hasPrefix("Yes") }) {
                // Walk upward for the nearest non-empty question line.
                var k = i - 1
                while k >= 0, stripped[k].isEmpty { k -= 1 }
                if k >= 0, stripped[k].hasSuffix("?") {
                    return PermissionPrompt(question: stripped[k], options: options)
                }
            }
        }
        i += 1
    }
    return nil
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `PermissionPrompt tests: N passed, 0 failed` and overall `All tests passed`.

- [ ] **Step 5: Register the suite**

In `app/Sources/AmuxTerm/AppDelegate.swift`, inside the `#if DEBUG` `--run-tests` block (after `AlertTests.runAll()`), add:

```swift
            PermissionPromptTests.runAll()
```

- [ ] **Step 6: Commit**

```bash
git add app/Sources/AmuxLib/PermissionPrompt.swift app/Sources/AmuxLib/PermissionPromptTests.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "Add pure permission-prompt parser with fixture-based tests"
```

---

## Task 3: PromptQueue FIFO state machine

**Files:**
- Create: `app/Sources/AmuxLib/PromptQueue.swift`
- Create: `app/Sources/AmuxLib/PromptQueueTests.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift` (register test suite)

- [ ] **Step 1: Write the failing test**

Create `app/Sources/AmuxLib/PromptQueueTests.swift`:

```swift
#if DEBUG
import Foundation

public enum PromptQueueTests {
    public static func runAll() {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let pA = PermissionPrompt(question: "A?", options: [PromptOption(number: 1, label: "Yes", selected: true)])
        let pB = PermissionPrompt(question: "B?", options: [PromptOption(number: 1, label: "Yes", selected: true)])

        var q = PromptQueue()
        // Detection on two panes → FIFO by first-seen order.
        q.update(detections: [.init(session: "s", pane: 0, prompt: pA),
                              .init(session: "s", pane: 1, prompt: pB)])
        check("count2", q.count == 2)
        check("currentA", q.current?.prompt.question == "A?")

        // Re-detecting the same prompts must not duplicate or reorder.
        q.update(detections: [.init(session: "s", pane: 1, prompt: pB),
                              .init(session: "s", pane: 0, prompt: pA)])
        check("still2", q.count == 2)
        check("stillA", q.current?.prompt.question == "A?")

        // advance() drops the head.
        q.advance()
        check("count1", q.count == 1)
        check("currentB", q.current?.prompt.question == "B?")

        // A prompt that vanishes from detections is dropped (answered in-session).
        q.update(detections: [])
        check("count0", q.count == 0)
        check("currentNil", q.current == nil)

        // dismissAll clears everything.
        q.update(detections: [.init(session: "s", pane: 0, prompt: pA)])
        q.dismissAll()
        check("dismissed", q.count == 0)

        print("PromptQueue tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("PromptQueue tests failed") }
    }
}
#endif
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test`
Expected: compile error — `PromptQueue` / `QueuedPrompt` not defined.

- [ ] **Step 3: Write the implementation**

Create `app/Sources/AmuxLib/PromptQueue.swift`:

```swift
// PromptQueue.swift — pure FIFO state machine over detected permission
// prompts across panes. No tmux dependency.

import Foundation

public struct QueuedPrompt: Equatable {
    public let session: String
    public let pane: Int
    public let prompt: PermissionPrompt
    public init(session: String, pane: Int, prompt: PermissionPrompt) {
        self.session = session; self.pane = pane; self.prompt = prompt
    }
    /// Identity = which pane it lives in (not the prompt text).
    var key: String { "\(session):\(pane)" }
}

public struct PromptQueue {
    private var items: [QueuedPrompt] = []

    public init() {}

    public var count: Int { items.count }
    public var current: QueuedPrompt? { items.first }
    public var all: [QueuedPrompt] { items }

    /// Reconcile against a fresh full snapshot of detected prompts:
    ///  - keep existing items still present (preserving FIFO order),
    ///  - append newly detected panes at the tail,
    ///  - drop panes no longer detected (answered elsewhere / closed).
    /// Identity is per-pane; a changed prompt body on the same pane updates in place.
    public mutating func update(detections: [QueuedPrompt]) {
        let byKey = Dictionary(detections.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [QueuedPrompt] = []
        var kept = Set<String>()
        for item in items {
            if let fresh = byKey[item.key] {
                next.append(fresh)        // update body, keep position
                kept.insert(item.key)
            }
        }
        for d in detections where !kept.contains(d.key) {
            next.append(d)                // new pane → tail
            kept.insert(d.key)
        }
        items = next
    }

    /// Remove the head (after it's been answered).
    public mutating func advance() {
        if !items.isEmpty { items.removeFirst() }
    }

    /// Clear the whole queue (Esc → dismiss to background).
    public mutating func dismissAll() {
        items.removeAll()
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `PromptQueue tests: N passed, 0 failed`.

- [ ] **Step 5: Register the suite**

In `AppDelegate.swift` `--run-tests` block add:

```swift
            PromptQueueTests.runAll()
```

- [ ] **Step 6: Commit**

```bash
git add app/Sources/AmuxLib/PromptQueue.swift app/Sources/AmuxLib/PromptQueueTests.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "Add pure FIFO prompt queue with reconciliation tests"
```

---

## Task 4: `capturePane` wrapper + FakeTmux handler

**Files:**
- Modify: `app/Sources/AmuxLib/Tmux.swift`
- Modify: `app/Sources/AmuxLib/FakeTmux.swift`
- Modify: `app/Sources/AmuxLib/FakeTmuxTests.swift`

- [ ] **Step 1: Write the failing test**

In `app/Sources/AmuxLib/FakeTmuxTests.swift`, inside `runAll()`, add (use the file's existing `check` helper):

```swift
        // capture-pane returns the fake pane's content.
        do {
            let fake = FakeTmux()
            fake.addSession("cap", panes: 1)
            fake.setPaneContent("cap", index: 0, content: "line1\nDo you want to proceed?\n❯ 1. Yes")
            Tmux.executor = fake
            let out = try Tmux.capturePane("cap", paneIndex: 0, lines: 25)
            check("capture-content", out.contains("Do you want to proceed?"), out)
        }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test`
Expected: compile error — `Tmux.capturePane` / `setPaneContent` not defined.

- [ ] **Step 3: Add the wrapper**

In `app/Sources/AmuxLib/Tmux.swift`, in the `// MARK: - Pane management` section, add:

```swift
    /// Capture the rendered text of a pane's visible screen plus `lines`
    /// rows of scrollback tail. `-p` prints to stdout, `-J` joins wrapped
    /// lines. Returns "" on failure (non-throwing) so the watcher poll
    /// loop never aborts on a transient tmux error.
    public static func capturePane(_ session: String, paneIndex: Int, lines: Int = 25) -> String {
        let target = "\(session):.\(paneIndex)"
        return runRaw(["capture-pane", "-p", "-J", "-t", target, "-S", "-\(lines)"])
    }
```

- [ ] **Step 4: Add the FakeTmux handler + builder**

In `app/Sources/AmuxLib/FakeTmux.swift`:

Add a stored property to `FakePane` (next to `pipePaneCommand`):

```swift
        public var content: String = ""
```

Add a case to the `execute` switch (next to `case "pipe-pane":`):

```swift
        case "capture-pane":
            return try handleCapturePane(args)
```

Add the handler (near `handlePipePane`):

```swift
    private func handleCapturePane(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("capture-pane: missing -t")
        }
        let (_, _, pane) = resolveTarget(target)
        return pane?.content ?? ""
    }
```

Add a builder in the `extension FakeTmux` block (next to `setPaneOption`):

```swift
    /// Set the captured screen content for a pane (test setup for capture-pane).
    public func setPaneContent(_ session: String, index: Int, content: String) {
        if let p = pane(session, index: index) { p.content = content }
    }
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test`
Expected: `FakeTmux tests` block passes, `All tests passed`.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/AmuxLib/Tmux.swift app/Sources/AmuxLib/FakeTmux.swift app/Sources/AmuxLib/FakeTmuxTests.swift
git commit -m "Add capturePane tmux wrapper and FakeTmux content support"
```

---

## Task 5: `sendKeys` wrapper + FakeTmux handler

**Files:**
- Modify: `app/Sources/AmuxLib/Tmux.swift`
- Modify: `app/Sources/AmuxLib/FakeTmux.swift`
- Modify: `app/Sources/AmuxLib/FakeTmuxTests.swift`

- [ ] **Step 1: Write the failing test**

In `FakeTmuxTests.swift` `runAll()`, add:

```swift
        // send-keys records the keys delivered to the pane.
        do {
            let fake = FakeTmux()
            fake.addSession("sk", panes: 1)
            Tmux.executor = fake
            try Tmux.sendKeys("sk", paneIndex: 0, keys: ["1"])
            check("sendkeys-recorded", fake.pane("sk", index: 0)?.sentKeys == ["1"],
                  "\(fake.pane("sk", index: 0)?.sentKeys ?? [])")
        }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test`
Expected: compile error — `Tmux.sendKeys` / `sentKeys` not defined.

- [ ] **Step 3: Add the wrapper**

In `Tmux.swift` `// MARK: - Pane management`, add:

```swift
    /// Send key tokens to a pane. Each token is a tmux key name ("Enter",
    /// "Escape") or literal text. Used to answer a permission prompt in a
    /// pane the user is not focused on.
    public static func sendKeys(_ session: String, paneIndex: Int, keys: [String]) throws {
        let target = "\(session):.\(paneIndex)"
        try runChecked(["send-keys", "-t", target] + keys, context: "tmux send-keys failed")
    }
```

- [ ] **Step 4: Add the FakeTmux handler**

In `FakeTmux.swift`:

Add to `FakePane`:

```swift
        public var sentKeys: [String] = []
```

Add to the `execute` switch:

```swift
        case "send-keys":
            return try handleSendKeys(args)
```

Add the handler:

```swift
    private func handleSendKeys(_ args: [String]) throws -> String {
        guard let target = flagValue(args, "-t") else {
            throw AmuxError.tmux("send-keys: missing -t")
        }
        let (_, _, pane) = resolveTarget(target)
        // Positional args after the flags are the key tokens.
        pane?.sentKeys.append(contentsOf: positionalArgs(args))
        return ""
    }
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test`
Expected: `All tests passed`.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/AmuxLib/Tmux.swift app/Sources/AmuxLib/FakeTmux.swift app/Sources/AmuxLib/FakeTmuxTests.swift
git commit -m "Add sendKeys tmux wrapper and FakeTmux key recording"
```

---

## Task 6: Answer-key mapping (pure)

**Files:**
- Modify: `app/Sources/AmuxLib/PermissionPrompt.swift`
- Modify: `app/Sources/AmuxLib/PermissionPromptTests.swift`

> Use the keystroke sequence **verified in Task 1**. The mapping below sends the option's digit as a literal token. If Task 1 showed Claude needs a trailing `Enter`, append `"Enter"`; if it showed bare `Enter` confirms the highlighted default, keep the digit form anyway (we always target a specific option by number). Update `answerKeys` and its test together to match the verified behavior before implementing.

- [ ] **Step 1: Write the failing test**

In `PermissionPromptTests.swift` `runAll()`, add:

```swift
        // Answer mapping: a numbered option → its digit token.
        let yes = PromptOption(number: 1, label: "Yes", selected: true)
        check("answer-yes", answerKeys(for: yes) == ["1"], "\(answerKeys(for: yes))")
        let dontask = PromptOption(number: 2, label: "Yes, and don't ask again", selected: false)
        check("answer-2", answerKeys(for: dontask) == ["2"])
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test`
Expected: compile error — `answerKeys` not defined.

- [ ] **Step 3: Write the implementation**

In `PermissionPrompt.swift`, add:

```swift
/// Key tokens that select a given option in Claude's permission menu.
/// Sent verbatim to `Tmux.sendKeys`. Confirm/adjust against Task 1's
/// verified mechanism (see permission-peek-sendkeys-notes.md).
public func answerKeys(for option: PromptOption) -> [String] {
    return ["\(option.number)"]
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test`
Expected: `PermissionPrompt tests: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/AmuxLib/PermissionPrompt.swift app/Sources/AmuxLib/PermissionPromptTests.swift
git commit -m "Add answer-key mapping for permission options"
```

---

## Task 7: PermissionWatcher + integration tests + AppDelegate timer

**Files:**
- Create: `app/Sources/AmuxTerm/PermissionWatcher.swift`
- Create: `app/Tests/PermissionCaptureTests.swift`
- Modify: `app/Tests/main.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift`

> This task crosses into the imperative shell. The pure poll-and-reconcile logic is unit-tested via `FakeTmux`; the real `capture-pane`/`send-keys` round-trip is covered by an integration test against real tmux (`make validate`). The 4s timer wiring itself is verified by running the app (see Task 8 verification).

- [ ] **Step 1: Write the integration test (real tmux)**

Create `app/Tests/PermissionCaptureTests.swift`. Follow the existing `app/Tests/*Tests.swift` shape (each returns `(passed, failed)`, uses `TestHelpers`). It must: create an isolated session, write a fixture's text into a pane (e.g. `tmux send-keys -t <pane> -l "<fixture line>"` per line, or `printf` via a shell command), `Tmux.capturePane`, and assert `detectPermissionPrompt` finds the prompt; then `Tmux.sendKeys` a digit and assert the pane received input. Load the real fixture from `app/Tests/Fixtures/permission-bash.txt`.

```swift
import Foundation
import AmuxLib

enum PermissionCaptureTests {
    static func runAll() -> (passed: Int, failed: Int) {
        var passed = 0, failed = 0
        func check(_ name: String, _ cond: Bool, _ msg: String = "") {
            if cond { passed += 1 } else { failed += 1; print("  FAIL: \(name)\(msg.isEmpty ? "" : " — \(msg)")") }
        }

        let session = TestHelpers.uniqueSession("peek")
        defer { try? Tmux.killSession(session) }
        try? Tmux.createSession(session)

        // Render the committed fixture into the pane via `cat`.
        let fixture = "app/Tests/Fixtures/permission-bash.txt"
        if FileManager.default.fileExists(atPath: fixture) {
            try? Tmux.sendKeys(session, paneIndex: 0, keys: ["-l", "clear; cat \(fixture)"])
            try? Tmux.sendKeys(session, paneIndex: 0, keys: ["Enter"])
            Thread.sleep(forTimeInterval: 0.3)
            let captured = Tmux.capturePane(session, paneIndex: 0, lines: 40)
            check("capture-detects", detectPermissionPrompt(captured) != nil,
                  "captured:\n\(captured)")
        } else {
            check("fixture-present", false, "missing \(fixture) — run Task 1")
        }

        return (passed, failed)
    }
}
```

Register in `app/Tests/main.swift` (after the `Help` line):

```swift
run("PermissionCapture", PermissionCaptureTests.runAll)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make validate`
Expected: FAIL — `PermissionCaptureTests` either missing or asserting because the watcher pieces aren't wired. (If Task 1 fixtures aren't committed yet, it fails on `fixture-present`.)

- [ ] **Step 3: Write the watcher**

Create `app/Sources/AmuxTerm/PermissionWatcher.swift`:

```swift
// PermissionWatcher.swift — polls managed panes for permission prompts.
//
// Imperative shell around the pure PermissionPrompt parser + PromptQueue.
// Every `interval` seconds: list managed sessions, capture each pane
// (skipping the focused pane of the attached session), detect prompts,
// reconcile the queue, and invoke `onChange` so the UI can refresh.

import Foundation
import AmuxLib

final class PermissionWatcher {
    private(set) var queue = PromptQueue()
    private var timer: Timer?
    private let interval: TimeInterval
    /// The session the user's client is attached to + its active pane,
    /// supplied by the app so we can exclude the pane already on screen.
    var attachedSession: () -> (session: String, activePane: Int)?
    var onChange: () -> Void = {}

    init(interval: TimeInterval = 4.0,
         attachedSession: @escaping () -> (session: String, activePane: Int)?) {
        self.interval = interval
        self.attachedSession = attachedSession
    }

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// One poll pass. Pure-ish: gathers detections then reconciles.
    func poll() {
        let attached = attachedSession()
        let sessions = (try? Tmux.listFocusSessions()) ?? []
        var detections: [QueuedPrompt] = []
        for session in sessions {
            let panes = (try? Tmux.listPanes(session)) ?? []
            for pane in panes {
                if let a = attached, a.session == session, a.activePane == pane.index {
                    continue   // user is looking at this pane already
                }
                let text = Tmux.capturePane(session, paneIndex: pane.index)
                if let prompt = detectPermissionPrompt(text) {
                    detections.append(QueuedPrompt(session: session, pane: pane.index, prompt: prompt))
                }
            }
        }
        queue.update(detections: detections)
        onChange()
    }

    /// Answer the head prompt's option, send keys, drop it from the queue.
    func answerCurrent(optionNumber: Int) {
        guard let head = queue.current,
              let opt = head.prompt.options.first(where: { $0.number == optionNumber }) else { return }
        try? Tmux.sendKeys(head.session, paneIndex: head.pane, keys: answerKeys(for: opt))
        queue.advance()
        onChange()
    }

    /// Engage the reject option: switch to that session, full-screen (zoom)
    /// the pane, and send the option's key — so the user lands there with
    /// Claude awaiting "what should I do instead?" ready for typed follow-up.
    func engageReject(optionNumber: Int) {
        guard let head = queue.current,
              let opt = head.prompt.options.first(where: { $0.number == optionNumber }) else { return }
        try? Tmux.switchSession(head.session)
        try? Tmux.selectPane(head.session, paneIndex: head.pane)
        if (try? Tmux.isZoomed(head.session)) != true { try? Tmux.toggleZoom(head.session) }
        try? Tmux.sendKeys(head.session, paneIndex: head.pane, keys: answerKeys(for: opt))
        queue.advance()
        onChange()
    }

    func dismissAll() { queue.dismissAll(); onChange() }
}
```

- [ ] **Step 4: Wire the watcher into AppDelegate**

In `AppDelegate.applicationDidFinishLaunching`, after `startAlertEventServer()`, add:

```swift
        let watcher = PermissionWatcher(attachedSession: { [weak self] in
            guard let self = self, let controller = self.controller else { return nil }
            let active = (try? Tmux.activePaneIndex(controller.session)) ?? -1
            return (controller.session, active)
        })
        watcher.onChange = { [weak self] in
            DispatchQueue.main.async { self?.termView?.updatePeekState(self?.permissionWatcher?.queue) }
        }
        self.permissionWatcher = watcher
        watcher.start()
```

Add the stored property near `alertServer`:

```swift
    var permissionWatcher: PermissionWatcher?
```

(`updatePeekState` is added in Task 8; until then, stub it as an empty `TerminalView` method so this compiles.)

- [ ] **Step 5: Run integration tests**

Run: `make validate`
Expected: `PermissionCapture` passes (real tmux capture detects the fixture). Full suite green.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/AmuxTerm/PermissionWatcher.swift app/Tests/PermissionCaptureTests.swift app/Tests/main.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "Add PermissionWatcher poll loop and real-tmux capture integration test"
```

---

## Task 8: Cmd-Y keybinding + badge/popup overlay

**Files:**
- Modify: `app/Sources/AmuxLib/KeyAction.swift`
- Modify: `app/Sources/AmuxTerm/KeyInputTests.swift`
- Modify: `app/Sources/AmuxTerm/TerminalView.swift`
- Modify: `app/Sources/AmuxTerm/AppDelegate.swift`

> This is the AppKit UI layer. Logic-level pieces (the key mapping) are unit-tested; the overlay rendering and the open→answer→advance→close flow are verified by **running the app** and observing behavior, per the project rule to verify visual changes against real state rather than asserting from code alone.

- [ ] **Step 1: Write the failing test for the key mapping**

In `app/Sources/AmuxTerm/KeyInputTests.swift` `runAll()`, add:

```swift
        check("cmd-y → peek",
              KeyCommand.amuxCommand(for: "y") == .peek)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `make test`
Expected: compile error — `AmuxCommand.peek` not defined.

- [ ] **Step 3: Add the command + mapping**

In `app/Sources/AmuxLib/KeyAction.swift`, add `case peek` to `AmuxCommand`, and in `KeyCommand.amuxCommand(for:)` add before the `default:`:

```swift
        case "y":  return .peek            // Cmd-Y (permission peek)
```

- [ ] **Step 4: Confirm the mapping test passes**

Run: `make test`
Expected: `KeyInput` tests pass.

- [ ] **Step 5: Add popup state + drawing to TerminalView**

In `TerminalView.swift`, add peek state and a method the watcher calls. Reuse the existing overlay/`needsDisplay` pattern (the file already draws `splitSelectedPaneBounds` and `borderOverlays` in `draw(_:)`). Add:

```swift
    // Permission-peek overlay state.
    private(set) var peekCount: Int = 0
    private var peekPopupPrompt: PermissionPrompt?
    private var peekHighlight: Int = 0   // index into the current prompt's options
    var peekPopupOpen: Bool { peekPopupPrompt != nil }

    /// Called by PermissionWatcher.onChange (on main). Updates the badge
    /// count and, if the popup is open, the prompt it shows (nil drains → close).
    func updatePeekState(_ queue: PromptQueue?) {
        peekCount = queue?.count ?? 0
        if peekPopupOpen {
            peekPopupPrompt = queue?.current?.prompt
            if peekHighlight >= (peekPopupPrompt?.options.count ?? 0) { peekHighlight = 0 }
        }
        needsDisplay = true
    }

    func togglePeekPopup(current: PermissionPrompt?) {
        if peekPopupOpen {
            peekPopupPrompt = nil
        } else {
            peekPopupPrompt = current
            // Start highlight on the option Claude shows selected (the ❯ row).
            peekHighlight = current?.options.firstIndex(where: { $0.selected }) ?? 0
        }
        needsDisplay = true
    }

    func closePeekPopup() { peekPopupPrompt = nil; needsDisplay = true }

    /// Move the popup highlight (clamped). Arrow keys call this.
    func movePeekHighlight(_ delta: Int) {
        guard let opts = peekPopupPrompt?.options, !opts.isEmpty else { return }
        peekHighlight = max(0, min(opts.count - 1, peekHighlight + delta))
        needsDisplay = true
    }

    /// The option number under the highlight, for Enter resolution.
    func highlightedOptionNumber(in prompt: PermissionPrompt) -> Int? {
        guard peekHighlight < prompt.options.count else { return nil }
        return prompt.options[peekHighlight].number
    }
```

In `draw(_ dirtyRect:)`, after the existing overlay drawing, draw (a) a bottom-right badge when `peekCount > 0` (a small rounded rect with the count, e.g. `●\(peekCount)`), and (b) when `peekPopupOpen`, a centered panel showing `peekPopupPrompt!.question` and each option as `"\(number). \(label)"`, rendering the option at index `peekHighlight` emphasized (e.g. a `❯` marker + brighter color) so arrow navigation is visible. Mark the reject/last option to signal it engages (e.g. trailing `→ open`). Footer: `"↑↓ / digit select · Enter confirm · Esc dismiss"`. Use `NSAttributedString`/`CTLine` as the existing `cachedLine`/`drawCell` code does, or `NSString.draw(in:withAttributes:)` for simplicity. Keep colors consistent with the existing palette.

- [ ] **Step 6: Route Cmd-Y and popup keys in AppDelegate**

In the `NSEvent.addLocalMonitorForEvents` handler in `AppDelegate`, **before** the `KeyInput.action` call, intercept popup keys when open:

```swift
            if let tv = self.termView, tv.peekPopupOpen,
               let watcher = self.permissionWatcher,
               let prompt = watcher.queue.current?.prompt {
                // Resolve a chosen option number: the reject option (last)
                // engages (full-screen + send key); all others answer in place.
                let resolve: (Int) -> Void = { num in
                    if num == prompt.rejectOption?.number {
                        watcher.engageReject(optionNumber: num)
                        tv.closePeekPopup()
                    } else {
                        watcher.answerCurrent(optionNumber: num)
                        tv.updatePeekState(watcher.queue)
                        if watcher.queue.current == nil { tv.closePeekPopup() }
                    }
                }
                switch event.keyCode {
                case 53: // Escape → dismiss whole queue to background
                    watcher.dismissAll(); tv.closePeekPopup(); return nil
                case 126: tv.movePeekHighlight(-1); return nil   // Up
                case 125: tv.movePeekHighlight(+1); return nil   // Down
                case 36:                                          // Enter → highlighted
                    if let num = tv.highlightedOptionNumber(in: prompt) { resolve(num) }
                    return nil
                default:
                    // Digit → that option directly (mirrors Claude's own keys).
                    let chars = event.charactersIgnoringModifiers ?? ""
                    if let d = Int(chars), prompt.options.contains(where: { $0.number == d }) {
                        resolve(d)
                    }
                    return nil // swallow all other keys while popup is open
                }
            }
```

Then handle the open command in the existing `switch action` block:

```swift
            case .amux(.peek):
                self.termView?.togglePeekPopup(current: self.permissionWatcher?.queue.current?.prompt)
                return nil
```

(Place this case alongside the other `.amux` handling; the generic `.amux(let command): controller.handleAction(command)` must not also fire for `.peek` — match `.amux(.peek)` first.)

- [ ] **Step 7: Verify in the running app**

Build and run with `make dev`. With at least two panes and a Claude prompt pending in a background pane, confirm:
1. The bottom-right badge appears with the count within ~4s.
2. `Cmd-Y` opens the popup showing the oldest prompt's question + options, highlight on Claude's selected option.
3. Arrow keys move the highlight; a digit or Enter on a non-reject option (Yes / Yes-don't-ask) answers in place and advances (or closes when queue empties); the answered pane proceeds.
4. Selecting the last (reject / "No") option full-screens that pane and sends its key — you land there with Claude awaiting follow-up.
5. `Esc` closes the popup to background (badge persists if prompts still pending; nothing answered).

Capture pane state to confirm the answer landed (`tmux capture-pane -p -t <pane>`), per the verify-visual-changes rule.

- [ ] **Step 8: Run the full suite**

Run: `make validate`
Expected: all green.

- [ ] **Step 9: Commit**

```bash
git add app/Sources/AmuxLib/KeyAction.swift app/Sources/AmuxTerm/KeyInputTests.swift app/Sources/AmuxTerm/TerminalView.swift app/Sources/AmuxTerm/AppDelegate.swift
git commit -m "Add Cmd-Y permission-peek popup and bottom-right badge overlay"
```

---

## Self-Review

**Spec coverage:**
- Watch text via `capture-pane` poll → Tasks 4, 7. ✓
- 4s interval → Task 7 (`PermissionWatcher.interval = 4.0`). ✓
- Pure detector against real fixtures → Tasks 1, 2. ✓
- FIFO queue, advance-on-answer, dismiss-all → Task 3. ✓
- Verbatim options + answer/engage/dismiss → Tasks 2, 6, 7, 8. ✓
- Bottom-right badge + `Cmd-Y` popup → Task 8. ✓
- Exclude focused pane → Task 7 (`attachedSession`). ✓
- Verify-before-build spikes → Task 1 **DONE** (2026-05-26): real fixtures committed; answer = bare digit (no Enter) verified; option 3 is plain "No" (engage keyed off the last/reject option). ✓
- Always-on → Task 7 (timer starts at launch, unconditional). ✓

**Known risks the reviewer should weigh:**
- Detector anchors confirmed against the committed Bash fixtures (no box-drawing glyphs — color box; glyph `❯`; question `Do you want to proceed?`). Edit/MCP prompt shapes were NOT capturable in this env (Write allowlisted; MCP needs a server) — if their question wording or option layout differs materially, the parser may need a second fixture later.
- `answerKeys` = bare digit, verified (no trailing Enter).
- Engage is keyed off the **last/reject option**, not a fixed slot — works for 2- and 3-option boxes. If a prompt ever lists a non-No option last, this misfires; revisit if observed.
- Tasks 7-verify and 8-verify need the live app — not subagent-automatable. Sequence those inline with Brian. (Task 1 is already done.)
- Queue identity is per `session:paneIndex`; if a pane index is reused after a pane closes within one poll window, the queue could mis-associate. Acceptable for v1 given the 4s cadence; note for follow-up if it bites.
