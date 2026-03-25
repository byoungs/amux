use std::process::Command;

fn session_name() -> String {
    // Use a counter to ensure each test gets a unique session
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("amux-integ-{}-{}", std::process::id(), id)
}

fn cleanup(session: &str) {
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", session])
        .output();
}

fn tmux_list_panes(session: &str) -> Vec<String> {
    let output = Command::new("tmux")
        .args([
            "list-panes",
            "-t",
            session,
            "-F",
            "#{pane_index}:#{@amux-title}",
        ])
        .output()
        .expect("list-panes");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| l.to_string())
        .collect()
}

fn pane_positions(session: &str) -> Vec<(i32, i32)> {
    let output = std::process::Command::new("tmux")
        .args([
            "list-panes",
            "-t",
            session,
            "-F",
            "#{pane_left} #{pane_top}",
        ])
        .output()
        .expect("list");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let parts: Vec<&str> = l.split(' ').collect();
            (parts[0].parse().unwrap_or(0), parts[1].parse().unwrap_or(0))
        })
        .collect()
}

fn tmux_option(session: &str, option: &str) -> String {
    let output = Command::new("tmux")
        .args(["show-options", "-t", session, "-v", option])
        .output()
        .expect("show-options");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

#[test]
fn start_creates_session_with_one_pane() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    let panes = tmux_list_panes(&session);
    assert_eq!(panes.len(), 1, "should have 1 pane");
    cleanup(&session);
}

#[test]
fn config_sets_border_style() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    let border_status = tmux_option(&session, "pane-border-status");
    assert_eq!(border_status, "top");
    let border_style = tmux_option(&session, "pane-active-border-style");
    assert!(
        border_style.contains("colour43"),
        "active border should be bright teal: {}",
        border_style
    );
    cleanup(&session);
}

#[test]
fn create_pane_increases_count() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    let panes = tmux_list_panes(&session);
    assert_eq!(panes.len(), 2);
    cleanup(&session);
}

#[test]
fn pane_title_is_set() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::set_title(&session, 0, "my-project").expect("title");
    let panes = tmux_list_panes(&session);
    assert!(
        panes[0].contains("my-project"),
        "title should be set: {:?}",
        panes
    );
    cleanup(&session);
}

#[test]
fn four_panes_in_tiled_layout() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    for i in 1..4 {
        let idx = amux::tmux::create_pane(&session, None).expect("pane");
        amux::tmux::set_title(&session, idx, &format!("pane-{}", i)).expect("title");
    }
    let panes = tmux_list_panes(&session);
    assert_eq!(panes.len(), 4);
    cleanup(&session);
}

#[test]
fn zoom_and_unzoom() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    assert!(!amux::tmux::is_zoomed(&session).expect("check"));
    amux::tmux::toggle_zoom(&session).expect("zoom");
    assert!(amux::tmux::is_zoomed(&session).expect("check"));
    amux::tmux::toggle_zoom(&session).expect("unzoom");
    assert!(!amux::tmux::is_zoomed(&session).expect("check"));
    cleanup(&session);
}

#[test]
fn kill_pane_reduces_count() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 3);
    amux::tmux::kill_pane(&session, 1).expect("kill");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 2);
    cleanup(&session);
}

#[test]
fn key_bindings_are_installed() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");
    let output = Command::new("tmux")
        .args(["list-keys"])
        .output()
        .expect("list-keys");
    let keys = String::from_utf8_lossy(&output.stdout);
    assert!(keys.contains("C-="), "Ctrl-+ (zoom in) missing");
    assert!(keys.contains("C--"), "Ctrl-- (zoom out) missing");
    assert!(keys.contains("C-n"), "Ctrl-n missing");
    assert!(keys.contains("amux zoom-in"), "zoom-in command missing");
    assert!(keys.contains("amux-birdeye"), "birdeye table missing");
    cleanup(&session);
}

// === STRESS TESTS ===

#[test]
fn create_and_kill_many_panes() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for i in 0..8 {
        amux::tmux::create_pane(&session, None)
            .unwrap_or_else(|e| panic!("failed to create pane {}: {}", i + 2, e));
    }
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 9);
    for i in (1..9).rev() {
        amux::tmux::kill_pane(&session, i).expect("kill");
    }
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 1);
    cleanup(&session);
}

#[test]
fn rapid_zoom_unzoom_cycles() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");
    for i in 0..10 {
        amux::tmux::toggle_zoom(&session)
            .unwrap_or_else(|e| panic!("zoom cycle {} failed: {}", i, e));
    }
    assert!(!amux::tmux::is_zoomed(&session).expect("check"));
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    cleanup(&session);
}

#[test]
fn zoom_each_pane_individually() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }
    for i in 0..4 {
        amux::tmux::select_pane(&session, i)
            .unwrap_or_else(|e| panic!("select pane {} failed: {}", i, e));
        amux::tmux::toggle_zoom(&session).expect("zoom");
        assert!(amux::tmux::is_zoomed(&session).expect("check"));
        amux::tmux::toggle_zoom(&session).expect("unzoom");
        assert!(!amux::tmux::is_zoomed(&session).expect("check"));
    }
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    cleanup(&session);
}

#[test]
fn pane_titles_survive_layout_changes() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::set_title(&session, 0, "alpha").expect("title");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::set_title(&session, 1, "beta").expect("title");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::set_title(&session, 2, "gamma").expect("title");
    amux::tmux::apply_grid_layout(&session).expect("tiled");
    let panes = amux::tmux::list_panes(&session).expect("list");
    assert!(panes.iter().any(|p| p.title == "alpha"));
    assert!(panes.iter().any(|p| p.title == "beta"));
    assert!(panes.iter().any(|p| p.title == "gamma"));
    amux::tmux::toggle_zoom(&session).expect("zoom");
    amux::tmux::toggle_zoom(&session).expect("unzoom");
    let panes = amux::tmux::list_panes(&session).expect("list");
    assert!(panes.iter().any(|p| p.title == "alpha"));
    assert!(panes.iter().any(|p| p.title == "beta"));
    assert!(panes.iter().any(|p| p.title == "gamma"));
    cleanup(&session);
}

#[test]
fn split_then_zoom_then_exit() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::enter_split(&session, 0, 1).expect("enter split");
    assert_eq!(amux::tmux::window_count(&session).expect("windows"), 2);
    amux::tmux::exit_split(&session).expect("exit split");
    assert_eq!(amux::tmux::window_count(&session).expect("windows"), 1);
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 3);
    amux::tmux::toggle_zoom(&session).expect("zoom");
    assert!(amux::tmux::is_zoomed(&session).expect("check"));
    amux::tmux::toggle_zoom(&session).expect("unzoom");
    cleanup(&session);
}

#[test]
fn split_with_four_panes_various_pairs() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    amux::tmux::enter_split(&session, 0, 2).expect("split 0+2");
    assert_eq!(amux::tmux::window_count(&session).expect("windows"), 2);
    amux::tmux::exit_split(&session).expect("exit");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    amux::tmux::enter_split(&session, 1, 3).expect("split 1+3");
    assert_eq!(amux::tmux::window_count(&session).expect("windows"), 2);
    amux::tmux::exit_split(&session).expect("exit");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    cleanup(&session);
}

#[test]
fn kill_pane_then_create_maintains_layout() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");
    amux::tmux::create_pane(&session, None).expect("pane");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    amux::tmux::kill_pane(&session, 1).expect("kill");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 3);
    amux::tmux::create_pane(&session, None).expect("new pane");
    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);
    cleanup(&session);
}

#[test]
fn config_applied_multiple_times_is_idempotent() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config 1");
    amux::config::apply_config(&session).expect("config 2");
    amux::config::apply_config(&session).expect("config 3");
    let panes = amux::tmux::list_panes(&session).expect("list");
    assert_eq!(panes.len(), 1);
    cleanup(&session);
}

#[test]
fn version_check_passes() {
    amux::tmux::check_version().expect("should pass on tmux 3.6a");
}

#[test]
fn split_requires_at_least_three_panes() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");
    let result = amux::tmux::enter_split(&session, 0, 1);
    assert!(result.is_err(), "split should require at least 3 panes");
    cleanup(&session);
}

// === THREE-LEVEL ZOOM TESTS ===

#[test]
fn zoom_level_starts_at_default() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    // Default level is 2 when not explicitly set
    let level = amux::tmux::get_level(&session).expect("get");
    assert_eq!(level, 2);
    cleanup(&session);
}

#[test]
fn zoom_level_transitions() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");

    // Set to L1
    amux::tmux::set_level(&session, 1).expect("set");
    assert_eq!(amux::tmux::get_level(&session).expect("get"), 1);

    // L1 → L2 via smart_resize
    amux::tmux::smart_resize(&session, 0, amux::MIN_PANE_COLS, amux::MIN_PANE_ROWS)
        .expect("resize");
    amux::tmux::set_level(&session, 2).expect("set");
    assert_eq!(amux::tmux::get_level(&session).expect("get"), 2);

    // L2 → L3 via zoom
    amux::tmux::toggle_zoom(&session).expect("zoom");
    amux::tmux::set_level(&session, 3).expect("set");
    assert_eq!(amux::tmux::get_level(&session).expect("get"), 3);
    assert!(amux::tmux::is_zoomed(&session).expect("check"));

    // L3 → L2 via unzoom
    amux::tmux::toggle_zoom(&session).expect("unzoom");
    amux::tmux::set_level(&session, 2).expect("set");
    assert!(!amux::tmux::is_zoomed(&session).expect("check"));

    // L2 → L1 via restore_tiled
    amux::tmux::restore_tiled(&session).expect("restore");
    amux::tmux::set_level(&session, 1).expect("set");
    assert_eq!(amux::tmux::get_level(&session).expect("get"), 1);

    cleanup(&session);
}

#[test]
fn smart_resize_with_many_panes() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    // Select pane 0 and smart resize
    amux::tmux::select_pane(&session, 0).expect("select");
    amux::tmux::smart_resize(&session, 0, amux::MIN_PANE_COLS, amux::MIN_PANE_ROWS)
        .expect("resize");

    // Verify pane 0 is at least close to minimum
    let panes = amux::tmux::list_panes(&session).expect("list");
    let p0 = panes.iter().find(|p| p.index == 0).expect("pane 0");
    // tmux may not achieve exact size due to constraints, but it should be bigger
    assert!(
        p0.width > 60,
        "pane 0 should be enlarged, got {}x{}",
        p0.width,
        p0.height
    );

    // Restore tiled — all should be equal again
    amux::tmux::restore_tiled(&session).expect("restore");
    let panes = amux::tmux::list_panes(&session).expect("list");
    let widths: Vec<u16> = panes.iter().map(|p| p.width).collect();
    let max_w = widths.iter().max().unwrap();
    let min_w = widths.iter().min().unwrap();
    assert!(
        max_w - min_w <= 2,
        "should be roughly equal after restore: {:?}",
        widths
    );

    cleanup(&session);
}

/// smart_resize should never shrink a dimension that already meets the minimum.
/// Bug: resize_pane(min_cols, min_rows) forces both dimensions, shrinking height
/// when only width needed enlarging. With 4 panes in a 2x2 grid, resizing one
/// pane's height distorts the entire row layout.
#[test]
fn smart_resize_preserves_sufficient_dimensions() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    // 4 panes in 2x2. Each is ~39x11 at default 80x24.
    let panes = amux::tmux::list_panes(&session).expect("list");
    let p0 = panes.iter().find(|p| p.index == 0).expect("pane 0");
    let height_before = p0.height;

    // Use min_rows much smaller than actual height so only width needs enlarging.
    let min_cols = 60;
    let min_rows = 5;
    assert!(
        p0.width < min_cols,
        "width {} should be below min {}",
        p0.width,
        min_cols
    );
    assert!(
        height_before > min_rows,
        "height {} should be above min {}",
        height_before,
        min_rows
    );

    amux::tmux::smart_resize(&session, 0, min_cols, min_rows).expect("resize");

    let panes = amux::tmux::list_panes(&session).expect("list");
    let p0_after = panes.iter().find(|p| p.index == 0).expect("pane 0");

    // Height should NOT have shrunk toward min_rows
    assert!(
        p0_after.height >= height_before.saturating_sub(1),
        "smart_resize shrunk height from {} to {} (min was {}). \
         Should only resize dimensions that are below minimum.",
        height_before,
        p0_after.height,
        min_rows
    );

    cleanup(&session);
}

#[test]
fn restore_tiled_unzooms_first() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");

    // Zoom in
    amux::tmux::toggle_zoom(&session).expect("zoom");
    assert!(amux::tmux::is_zoomed(&session).expect("check"));

    // Restore tiled should unzoom first
    amux::tmux::restore_tiled(&session).expect("restore");
    assert!(!amux::tmux::is_zoomed(&session).expect("check"));

    cleanup(&session);
}

// === SPACES TESTS ===

#[test]
fn list_sessions_includes_created() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    let sessions = amux::tmux::list_sessions().expect("list");
    assert!(sessions.contains(&session), "session should be listed");
    cleanup(&session);
}

#[test]
fn send_pane_to_session() {
    let s1 = format!("{}-s1", session_name());
    let s2 = format!("{}-s2", session_name());
    cleanup(&s1);
    cleanup(&s2);

    amux::tmux::create_session(&s1).expect("create s1");
    amux::tmux::create_session(&s2).expect("create s2");

    // s1 starts with 1 pane, create a second
    amux::tmux::create_pane(&s1, None).expect("pane");
    assert_eq!(amux::tmux::pane_count(&s1).expect("count"), 2);
    assert_eq!(amux::tmux::pane_count(&s2).expect("count"), 1);

    // Send active pane from s1 to s2
    amux::tmux::send_pane_to_session(&s1, &s2).expect("send");

    assert_eq!(amux::tmux::pane_count(&s1).expect("count"), 1);
    assert_eq!(amux::tmux::pane_count(&s2).expect("count"), 2);

    cleanup(&s1);
    cleanup(&s2);
}

#[test]
fn switch_session_sessions_exist() {
    let s1 = format!("{}-sw1", session_name());
    let s2 = format!("{}-sw2", session_name());
    cleanup(&s1);
    cleanup(&s2);

    amux::tmux::create_session(&s1).expect("create s1");
    amux::tmux::create_session(&s2).expect("create s2");

    // switch_session requires an attached client, which we don't have in tests
    // Just verify the sessions exist
    assert!(amux::tmux::session_exists(&s1));
    assert!(amux::tmux::session_exists(&s2));

    cleanup(&s1);
    cleanup(&s2);
}

// === LAYOUT STABILITY TESTS ===

#[test]
fn layout_two_panes_always_left_right() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane");

    let panes = amux::tmux::list_panes(&session).expect("list");
    assert_eq!(panes.len(), 2);

    // Both panes should be at y=0 (side by side, not stacked)
    // Check via tmux that pane tops are the same
    let output = std::process::Command::new("tmux")
        .args(["list-panes", "-t", &session, "-F", "#{pane_top}"])
        .output()
        .expect("list");
    let tops: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| l.to_string())
        .collect();
    assert_eq!(
        tops[0], tops[1],
        "2 panes should be side-by-side (same top): {:?}",
        tops
    );

    cleanup(&session);
}

#[test]
fn layout_close_preserves_positions() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::tmux::create_pane(&session, None).expect("pane 2");
    amux::tmux::create_pane(&session, None).expect("pane 3");
    amux::tmux::create_pane(&session, None).expect("pane 4");

    // 4 panes in 2x2
    let panes_before = amux::tmux::list_panes(&session).expect("list");
    assert_eq!(panes_before.len(), 4);

    // Record dimensions of pane 0 (top-left in 2x2)
    let p0_before = (panes_before[0].width, panes_before[0].height);

    // Kill pane 1 (top-right) — pane 0 should expand to full-height left column
    amux::tmux::kill_pane(&session, 1).expect("kill");

    let panes_after = amux::tmux::list_panes(&session).expect("list");
    assert_eq!(panes_after.len(), 3);

    // Pane 0 should be taller (expanded from half-height in 2x2 to full-height in 3-pane layout)
    assert!(
        panes_after[0].height > p0_before.1,
        "pane 0 should expand: before_h={}, after_h={}",
        p0_before.1,
        panes_after[0].height
    );

    cleanup(&session);
}

#[test]
fn layout_four_panes_is_2x2() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    let output = std::process::Command::new("tmux")
        .args([
            "list-panes",
            "-t",
            &session,
            "-F",
            "#{pane_left} #{pane_top}",
        ])
        .output()
        .expect("list");
    let positions: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect();

    assert_eq!(positions.len(), 4, "should have 4 panes");

    // Should have 2 unique x positions (2 columns) and 2 unique y positions (2 rows)
    let xs: std::collections::HashSet<&str> = positions
        .iter()
        .map(|p| p.split(' ').next().unwrap())
        .collect();
    let ys: std::collections::HashSet<&str> = positions
        .iter()
        .map(|p| p.split(' ').nth(1).unwrap())
        .collect();

    assert_eq!(xs.len(), 2, "should have 2 columns: {:?}", positions);
    assert_eq!(ys.len(), 2, "should have 2 rows: {:?}", positions);

    cleanup(&session);
}

#[test]
fn spatial_stickiness_kill_and_recreate() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }
    // 4 panes in 2x2. Record pane IDs and positions.
    let ids_before = amux::tmux::get_pane_ids(&session).expect("ids");
    let positions_before = pane_positions(&session);

    // Kill pane at index 1 (top-right in 2x2)
    amux::tmux::kill_pane(&session, 1).expect("kill");

    // Pane 0 (was top-left) should still be on the left side
    let positions_after_kill = pane_positions(&session);
    assert!(
        positions_after_kill[0].0 < 10,
        "pane 0 should stay on left after kill: {:?}",
        positions_after_kill
    );

    // Create a new pane — back to 4
    amux::tmux::create_pane(&session, None).expect("new");

    // The 3 surviving panes should be back near their original positions
    let positions_after_create = pane_positions(&session);
    let ids_after = amux::tmux::get_pane_ids(&session).expect("ids");

    // Find surviving pane IDs (those in both before and after)
    let survivors: Vec<u32> = ids_before
        .iter()
        .filter(|id| ids_after.contains(id))
        .copied()
        .collect();

    // Each survivor's position should be close to where it started
    for &surv_id in &survivors {
        let before_idx = ids_before.iter().position(|&id| id == surv_id).unwrap();
        let after_idx = ids_after.iter().position(|&id| id == surv_id).unwrap();
        let (bx, by) = positions_before[before_idx];
        let (ax, ay) = positions_after_create[after_idx];
        let dist = ((bx - ax).abs() + (by - ay).abs()) as u32;
        assert!(
            dist < 20,
            "pane %{} moved too far: ({},{}) -> ({},{}), dist={}",
            surv_id,
            bx,
            by,
            ax,
            ay,
            dist
        );
    }

    cleanup(&session);
}

#[test]
fn apply_layout_twice_preserves_centers() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    amux::tmux::apply_grid_layout(&session).expect("layout 1");
    let positions_1 = pane_positions(&session);

    amux::tmux::apply_grid_layout(&session).expect("layout 2");
    let positions_2 = pane_positions(&session);

    assert_eq!(
        positions_1, positions_2,
        "layout should be stable on reapply"
    );

    cleanup(&session);
}

#[test]
fn stickiness_survives_rapid_changes() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    // Rapid kill/create cycles
    for _ in 0..3 {
        amux::tmux::kill_pane(&session, 1).expect("kill");
        amux::tmux::create_pane(&session, None).expect("new");
    }

    assert_eq!(amux::tmux::pane_count(&session).expect("count"), 4);

    // Should still be a valid 2x2 layout
    let positions = pane_positions(&session);
    let xs: std::collections::HashSet<i32> = positions.iter().map(|p| p.0).collect();
    let ys: std::collections::HashSet<i32> = positions.iter().map(|p| p.1).collect();
    assert_eq!(xs.len(), 2, "should have 2 columns: {:?}", positions);
    assert_eq!(ys.len(), 2, "should have 2 rows: {:?}", positions);

    cleanup(&session);
}

// === PANE SIZE EQUALITY TESTS (border-status compensation) ===

fn pane_sizes(session: &str) -> Vec<(u16, u16)> {
    let output = std::process::Command::new("tmux")
        .args([
            "list-panes",
            "-t",
            session,
            "-F",
            "#{pane_width} #{pane_height}",
        ])
        .output()
        .expect("list-panes");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let parts: Vec<&str> = l.split(' ').collect();
            (parts[0].parse().unwrap(), parts[1].parse().unwrap())
        })
        .collect()
}

/// With pane-border-status top, all panes in a 2x2 grid should have equal heights.
#[test]
fn four_panes_equal_height_with_border_status() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");

    for _ in 0..3 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    let sizes = pane_sizes(&session);
    assert_eq!(sizes.len(), 4);

    let heights: Vec<u16> = sizes.iter().map(|s| s.1).collect();
    let max_h = *heights.iter().max().unwrap();
    let min_h = *heights.iter().min().unwrap();

    assert!(
        max_h - min_h <= 1,
        "all panes should have roughly equal height, got {:?} (diff {})",
        sizes,
        max_h - min_h
    );

    cleanup(&session);
}

/// 3 panes: right column panes should have roughly equal height with border-status.
#[test]
fn three_panes_right_column_equal_with_border_status() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");

    for _ in 0..2 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    let sizes = pane_sizes(&session);
    assert_eq!(sizes.len(), 3);

    let right_diff = (sizes[1].1 as i32 - sizes[2].1 as i32).unsigned_abs() as u16;
    assert!(
        right_diff <= 1,
        "right column panes should have roughly equal height: {:?} (diff {})",
        sizes,
        right_diff
    );

    cleanup(&session);
}

/// 6 panes in 3x2 grid should all have roughly equal heights with border-status.
#[test]
fn six_panes_equal_height_with_border_status() {
    let session = session_name();
    cleanup(&session);
    amux::tmux::create_session(&session).expect("create");
    amux::config::apply_config(&session).expect("config");

    for _ in 0..5 {
        amux::tmux::create_pane(&session, None).expect("pane");
    }

    let sizes = pane_sizes(&session);
    assert_eq!(sizes.len(), 6);

    let heights: Vec<u16> = sizes.iter().map(|s| s.1).collect();
    let max_h = *heights.iter().max().unwrap();
    let min_h = *heights.iter().min().unwrap();

    assert!(
        max_h - min_h <= 1,
        "all panes should have roughly equal height, got {:?} (diff {})",
        sizes,
        max_h - min_h
    );

    cleanup(&session);
}
