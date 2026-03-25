use amux::sticky::{match_panes_to_slots, PaneCenter, SlotCenter};

#[test]
fn four_to_three_keeps_corners() {
    let panes = vec![
        PaneCenter { id: 1, cx: 70, cy: 20, prev_cx: None, prev_cy: None },
        PaneCenter { id: 3, cx: 70, cy: 60, prev_cx: None, prev_cy: None },
        PaneCenter { id: 4, cx: 210, cy: 60, prev_cx: None, prev_cy: None },
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 40 },
        SlotCenter { cx: 210, cy: 20 },
        SlotCenter { cx: 210, cy: 60 },
    ];
    let result = match_panes_to_slots(&panes, &slots, false);
    assert_eq!(result[0], Some(1), "top-left pane should take left slot");
    assert_eq!(result[2], Some(4), "bottom-right pane should keep bottom-right");
    assert_eq!(result[1], Some(3));
}

#[test]
fn snap_back_on_recreate() {
    let panes = vec![
        PaneCenter { id: 1, cx: 70, cy: 40, prev_cx: Some(70), prev_cy: Some(20) },
        PaneCenter { id: 3, cx: 210, cy: 20, prev_cx: Some(70), prev_cy: Some(60) },
        PaneCenter { id: 4, cx: 210, cy: 60, prev_cx: Some(210), prev_cy: Some(60) },
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 20 },
        SlotCenter { cx: 210, cy: 20 },
        SlotCenter { cx: 70, cy: 60 },
        SlotCenter { cx: 210, cy: 60 },
    ];
    let result = match_panes_to_slots(&panes, &slots, true);
    assert_eq!(result[0], Some(1), "pane 1 snaps back to top-left");
    assert_eq!(result[2], Some(3), "pane 3 snaps back to bottom-left");
    assert_eq!(result[3], Some(4), "pane 4 snaps back to bottom-right");
    assert_eq!(result[1], None, "top-right slot is empty for new pane");
}

#[test]
fn new_pane_no_history_gets_unmatched_slot() {
    let panes = vec![
        PaneCenter { id: 1, cx: 70, cy: 40, prev_cx: None, prev_cy: None },
        PaneCenter { id: 2, cx: 210, cy: 40, prev_cx: None, prev_cy: None },
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 40 },
        SlotCenter { cx: 210, cy: 20 },
        SlotCenter { cx: 210, cy: 60 },
    ];
    let result = match_panes_to_slots(&panes, &slots, true);
    assert_eq!(result[0], Some(1), "left pane stays left");
    let assigned_count = result.iter().filter(|id| id.is_some()).count();
    assert_eq!(assigned_count, 2, "only 2 panes assigned");
    assert!(result.contains(&None), "one slot should be empty for new pane");
}

#[test]
fn single_pane_no_crash() {
    let panes = vec![
        PaneCenter { id: 1, cx: 140, cy: 40, prev_cx: None, prev_cy: None },
    ];
    let slots = vec![
        SlotCenter { cx: 140, cy: 40 },
    ];
    let result = match_panes_to_slots(&panes, &slots, false);
    assert_eq!(result, vec![Some(1)]);
}

#[test]
fn first_layout_no_saved_centers() {
    // All panes have (0,0) — should still assign without panic
    let panes = vec![
        PaneCenter { id: 1, cx: 0, cy: 0, prev_cx: None, prev_cy: None },
        PaneCenter { id: 2, cx: 0, cy: 0, prev_cx: None, prev_cy: None },
    ];
    let slots = vec![
        SlotCenter { cx: 70, cy: 40 },
        SlotCenter { cx: 210, cy: 40 },
    ];
    let result = match_panes_to_slots(&panes, &slots, false);
    // Both should be assigned (order doesn't matter for equal distances)
    let mut sorted: Vec<u32> = result.iter().filter_map(|&id| id).collect();
    sorted.sort();
    assert_eq!(sorted, vec![1, 2]);
}
