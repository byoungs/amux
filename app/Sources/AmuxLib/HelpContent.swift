/// Help screen content — all keyboard shortcuts and descriptions.
///
/// Used by the help TUI (amux-cli help) and by tests to verify
/// completeness. Data only — no rendering logic.
public enum HelpContent {
    public struct Entry {
        public let key: String
        public let description: String

        public init(key: String, description: String) {
            self.key = key
            self.description = description
        }
    }

    public struct Section {
        public let title: String
        public let entries: [Entry]

        public init(title: String, entries: [Entry]) {
            self.title = title
            self.entries = entries
        }
    }

    public static let sections: [Section] = [
        Section(title: "Navigation", entries: [
            Entry(key: "⌘+ ⌘=", description: "Zoom in — focus the active pane full-screen"),
            Entry(key: "⌘-", description: "Zoom out — return to grid, or open Spaces if already in grid"),
            Entry(key: "⌘]", description: "Next pane — cycle forward through panes"),
            Entry(key: "⌘[", description: "Previous pane — cycle backward through panes"),
            Entry(key: "⌘1-9", description: "Focus pane by number — zoom directly to pane N"),
        ]),
        Section(title: "Pane Management", entries: [
            Entry(key: "⌘n", description: "New pane — create a new shell pane"),
            Entry(key: "⌘l", description: "Split — enter split-pick mode to view two panes side by side"),
            Entry(key: "⌘s", description: "Send — move the active pane to another space"),
        ]),
        Section(title: "Spaces", entries: [
            Entry(key: "⌘p", description: "Spaces — open the space picker to switch workspaces"),
        ]),
        Section(title: "General", entries: [
            Entry(key: "⌘? ⌘/", description: "Help — show this screen"),
            Entry(key: "⌘q", description: "Quit — close the application"),
            Entry(key: "⌘c", description: "Copy — copy selected text to clipboard"),
            Entry(key: "⌘v", description: "Paste — paste from clipboard"),
        ]),
        Section(title: "Split-Pick Mode", entries: [
            Entry(key: "←→↑↓", description: "Navigate — move selection between panes"),
            Entry(key: "1-9", description: "Pick pane — select pane by number"),
            Entry(key: "Enter", description: "Confirm — split with the selected pane"),
            Entry(key: "Esc", description: "Cancel — exit split-pick mode"),
        ]),
    ]
}
