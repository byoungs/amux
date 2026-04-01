use amux::title_log::format_entry;

#[test]
fn format_entry_includes_all_fields() {
    let entry = format_entry(
        "amux",
        3,
        "ai-scheduler/old-branch",
        "amux/main",
        "update-title",
        "/Users/me/src/amux",
    );
    assert!(entry.contains("session=amux"), "missing session: {entry}");
    assert!(entry.contains("pane=3"), "missing pane: {entry}");
    assert!(
        entry.contains("old=\"ai-scheduler/old-branch\""),
        "missing old title: {entry}"
    );
    assert!(
        entry.contains("new=\"amux/main\""),
        "missing new title: {entry}"
    );
    assert!(
        entry.contains("caller=update-title"),
        "missing caller: {entry}"
    );
    assert!(
        entry.contains("cwd=/Users/me/src/amux"),
        "missing cwd: {entry}"
    );
}

#[test]
fn format_entry_handles_empty_old_title() {
    let entry = format_entry("amux", 0, "", "amux/main", "new", "/Users/me/src/amux");
    assert!(
        entry.contains("old=\"\""),
        "empty old title not quoted: {entry}"
    );
}
