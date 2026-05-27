// PermissionPrompt.swift — pure detection of a Claude Code permission prompt
// from rendered pane text (as produced by `tmux capture-pane -p -J`).
//
// No tmux dependency. Tested against real captured fixtures
// (app/Tests/Fixtures/permission-*.txt) so the format is ground truth, not a
// guess. See docs/superpowers/specs/2026-05-26-permission-peek-sendkeys-notes.md.
//
// Observed shape (Claude Code 2.1.150): the prompt has no box-drawing border
// (the visible box is color-rendered), so capture yields space-indented text:
//
//      Do you want to proceed?
//      ❯ 1. Yes
//        2. Yes, and don't ask again for: sw_vers *
//        3. No
//
// The selected option is prefixed with `❯`. Option count/labels vary.

import Foundation

public struct PromptOption: Equatable {
    public let number: Int
    public let label: String      // verbatim, e.g. "Yes" / "Yes, and don't ask again…" / "No"
    public let selected: Bool     // true if this row carried the selection glyph

    public init(number: Int, label: String, selected: Bool) {
        self.number = number
        self.label = label
        self.selected = selected
    }
}

public struct PermissionPrompt: Equatable {
    public let question: String
    /// Context lines above the question (tool header, the command being run,
    /// its description) so the user can decide without switching to the pane.
    public let details: [String]
    public let options: [PromptOption]

    public init(question: String, details: [String] = [], options: [PromptOption]) {
        self.question = question
        self.details = details
        self.options = options
    }

    /// The reject option — the one whose label starts with "No". Selecting it
    /// engages (full-screen the pane) rather than answering in place, because
    /// rejecting leaves Claude waiting for typed follow-up.
    ///
    /// Keyed off the label, NOT position: some prompts end with
    /// "Yes, and don't ask again" (reject is Esc-only, no numbered "No"), so
    /// the last option is not reliably the reject. If no numbered "No"
    /// exists, this is nil and every numbered option answers in place.
    public var rejectOption: PromptOption? {
        options.first(where: { $0.label.lowercased().hasPrefix("no") })
    }
}

/// Key tokens that select a given option in Claude's permission menu, sent
/// verbatim to `Tmux.sendKeys`. Verified (Task 1): a bare digit selects AND
/// confirms — no trailing Enter.
public func answerKeys(for option: PromptOption) -> [String] {
    return ["\(option.number)"]
}

/// Selection glyph(s) Claude uses to mark the highlighted option.
private let selectionGlyphs: Set<Character> = ["❯", ">", "›", "»"]

/// Box-drawing characters to strip (defensive — current Claude renders the
/// box with color, not glyphs, but a full-width `─` rule does appear).
private let borderChars: Set<Character> = [
    "│", "╭", "╮", "╰", "╯", "─", "┌", "┐", "└", "┘", "├", "┤", "|",
]

/// Strip border characters and surrounding whitespace from a line.
private func stripBorder(_ line: String) -> String {
    var s = Substring(line)
    while let f = s.first, f.isWhitespace || borderChars.contains(f) { s = s.dropFirst() }
    while let l = s.last, l.isWhitespace || borderChars.contains(l) { s = s.dropLast() }
    return String(s)
}

/// Parse one option line like "❯ 1. Yes" → (1, "Yes", selected:true), else nil.
///
/// Handles narrow-pane rendering where Claude lays the command out in a
/// right-hand column separated by a run of ≥2 spaces — the label keeps only
/// the left (text) portion. Tolerates a missing space after the dot ("2.Yes").
private func parseOption(_ stripped: String) -> PromptOption? {
    var s = Substring(stripped)
    var selected = false
    if let f = s.first, selectionGlyphs.contains(f) {
        selected = true
        s = s.dropFirst().drop(while: { $0.isWhitespace })
    }
    // Expect "<digits>. <text>"
    guard let dot = s.firstIndex(of: "."), dot != s.startIndex else { return nil }
    let numPart = s[s.startIndex..<dot]
    guard !numPart.isEmpty, numPart.allSatisfy({ $0.isNumber }), let number = Int(numPart) else {
        return nil
    }
    var label = s[s.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    // Narrow panes render a right-hand column (e.g. the command) separated by
    // a run of ≥2 spaces; keep only the left (label) portion.
    if let gap = label.range(of: "  ") {
        label = String(label[..<gap.lowerBound])
    }
    label = label.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { return nil }
    return PromptOption(number: number, label: label, selected: selected)
}

/// Detect a permission prompt in rendered pane text.
///
/// Anchors (all required) to avoid false positives on ordinary chat:
///   1. A non-empty question line ending in "?".
///   2. Below it, numbered options 1, 2, … — NOT necessarily on consecutive
///      lines. In narrow panes Claude wraps a long option's command across
///      several lines and uses a right-hand column, so option N+1 may sit a
///      few lines below option N. We scan downward (to the footer or a bound)
///      and accept each line that parses as the next expected number.
///   3. At least two options, one whose label starts with "Yes".
///   4. A live-prompt marker: either the selection glyph `❯` on an option or
///      the "Esc to cancel …" footer. Both appear in every real prompt and are
///      absent from transcript text that merely quotes "Do you want to
///      proceed? / 1. Yes / 2. No", so this kills that false positive (which
///      would otherwise let a stray digit be sent into a pane with no prompt).
///
/// Searched bottom-up because the live prompt sits at the bottom of the pane;
/// this also avoids matching numbered lists higher up in the transcript.
public func detectPermissionPrompt(_ text: String) -> PermissionPrompt? {
    let raw = text.components(separatedBy: "\n")
    let stripped = raw.map(stripBorder)
    var q = stripped.count - 1
    while q >= 0 {
        if !stripped[q].isEmpty, stripped[q].hasSuffix("?"),
           let options = collectOptions(below: q, in: stripped) {
            let details = gatherDetails(above: q, raw: raw, stripped: stripped)
            return PermissionPrompt(question: stripped[q], details: details, options: options)
        }
        q -= 1
    }
    return nil
}

/// Collect numbered options below a question line, tolerating wrapped/column
/// lines between them. Returns nil if fewer than two options or no "Yes".
private func collectOptions(below q: Int, in stripped: [String]) -> [PromptOption]? {
    var options: [PromptOption] = []
    var expected = 1
    var sawFooter = false
    var i = q + 1
    while i < stripped.count, i - q <= 40 {
        let lower = stripped[i].lowercased()
        if lower.contains("esc to cancel") || lower.hasPrefix("esc to") { sawFooter = true; break }
        if let opt = parseOption(stripped[i]), opt.number == expected {
            options.append(opt)
            expected += 1
        }
        i += 1
    }
    // Require a live-prompt marker (anchor #4): the selection glyph on an
    // option or the footer. Quoted/echoed transcript text has neither.
    guard options.count >= 2,
          options.contains(where: { $0.label.hasPrefix("Yes") }),
          sawFooter || options.contains(where: { $0.selected }) else { return nil }
    return options
}

/// True if the (trimmed) line is a horizontal rule — the separator above the
/// permission box. Used as the upper boundary for context gathering.
private func isRule(_ s: String) -> Bool {
    guard s.count >= 8 else { return false }
    let ruleChars: Set<Character> = ["─", "—", "━", "═", "-", "│", "┄", "┈"]
    return s.allSatisfy { ruleChars.contains($0) }
}

/// Gather the context lines above the question (tool header, command,
/// description). Scans upward, stopping at the rule separator above the box or
/// a transcript marker (⏺ tool call / ⎿ output), capped to a small window.
private func gatherDetails(above q: Int, raw: [String], stripped: [String]) -> [String] {
    var details: [String] = []
    var i = q - 1
    var scanned = 0
    while i >= 0, scanned < 14 {
        let rawTrim = raw[i].trimmingCharacters(in: .whitespaces)
        if isRule(rawTrim) || rawTrim.hasPrefix("⏺") || rawTrim.hasPrefix("⎿") { break }
        if !stripped[i].isEmpty { details.append(stripped[i]) }
        i -= 1
        scanned += 1
    }
    return details.reversed()
}
