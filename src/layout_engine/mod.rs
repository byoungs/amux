//! Unified layout state machine.
//!
//! All pane, layout, and zoom state transitions go through `compute_layout`.
//! It's a pure function: takes a snapshot of current state + an event,
//! returns the full set of actions the shell should execute.
//!
//! Zoom state is derived from tmux's native `window_zoomed_flag` —
//! there is no separate level variable. Two states: zoomed (full screen)
//! and not-zoomed (working/grid).

pub mod log;

use crate::layout;
use crate::sticky::{self, Pane};

/// Snapshot of everything the layout engine needs to make decisions.
#[derive(Debug, Clone)]
pub struct LayoutState {
    pub panes: Vec<Pane>,
    pub window_w: u16,
    pub window_h: u16,
    pub border_top: u16,
    pub zoomed: bool,
    pub active_pane: usize,
    pub pane_count: usize,
}

/// Events that trigger a state transition.
#[derive(Debug, Clone)]
pub enum LayoutEvent {
    AddPane(u32),
    RemovePane(u32),
    Resize,
    ZoomIn,
    ZoomOut,
    ZoomTo(usize),
    PaneNext,
    PanePrev,
}

/// The full set of tmux mutations the shell should execute.
#[derive(Debug, Clone, Default)]
pub struct LayoutAction {
    pub layout_string: Option<String>,
    pub zoom: Option<bool>,
    pub select_pane: Option<usize>,
    pub open_spaces: bool,
    pub dismiss_alert: Option<usize>,
    pub error_message: Option<String>,
}

/// Pure state transition: given current state and an event, compute all actions.
pub fn compute_layout(state: &LayoutState, event: &LayoutEvent) -> LayoutAction {
    match event {
        LayoutEvent::AddPane(id) => compute_add(state, *id),
        LayoutEvent::RemovePane(id) => compute_remove(state, *id),
        LayoutEvent::Resize => compute_resize(state),
        LayoutEvent::ZoomIn => compute_zoom_in(state),
        LayoutEvent::ZoomOut => compute_zoom_out(state),
        LayoutEvent::ZoomTo(pane) => compute_zoom_to(state, *pane),
        LayoutEvent::PaneNext => compute_pane_next(state),
        LayoutEvent::PanePrev => compute_pane_prev(state),
    }
}

fn build_grid_layout(state: &LayoutState, sticky_event: sticky::LayoutEvent) -> Option<String> {
    let effective_h = state.window_h.saturating_sub(state.border_top);
    let new_panes = sticky::compute_layout(&state.panes, sticky_event, state.window_w, effective_h);
    layout::build_layout_string(&new_panes, state.window_w, state.window_h, state.border_top)
}

fn compute_add(state: &LayoutState, new_id: u32) -> LayoutAction {
    let mut action = LayoutAction::default();
    if state.panes.len() > 1 && state.zoomed {
        action.zoom = Some(false);
    }
    action.layout_string = build_grid_layout(state, sticky::LayoutEvent::Add(new_id));
    action
}

fn compute_remove(state: &LayoutState, removed_id: u32) -> LayoutAction {
    let mut action = LayoutAction::default();
    if state.panes.len() > 1 && state.zoomed {
        action.zoom = Some(false);
    }
    action.layout_string = build_grid_layout(state, sticky::LayoutEvent::Remove(removed_id));
    action
}

fn compute_resize(state: &LayoutState) -> LayoutAction {
    let mut action = LayoutAction::default();
    if state.zoomed {
        return action;
    }
    if state.panes.is_empty() {
        return action;
    }
    action.layout_string = build_grid_layout(state, sticky::LayoutEvent::Resize);
    action
}

fn compute_zoom_in(state: &LayoutState) -> LayoutAction {
    let mut action = LayoutAction::default();
    if !state.zoomed {
        action.zoom = Some(true);
        action.dismiss_alert = Some(state.active_pane);
    }
    action
}

fn compute_zoom_out(state: &LayoutState) -> LayoutAction {
    let mut action = LayoutAction::default();
    if state.zoomed {
        action.zoom = Some(false);
    } else {
        action.open_spaces = true;
    }
    action
}

fn compute_zoom_to(state: &LayoutState, target_pane: usize) -> LayoutAction {
    let mut action = LayoutAction::default();
    if target_pane >= state.pane_count {
        action.error_message = Some(format!(
            "Pane {} does not exist (have {})",
            target_pane + 1,
            state.pane_count
        ));
        return action;
    }
    let same_pane = state.active_pane == target_pane;
    match (state.zoomed, same_pane) {
        (false, true) => {
            action.zoom = Some(true);
        }
        (false, false) => {
            action.select_pane = Some(target_pane);
            action.dismiss_alert = Some(target_pane);
        }
        (true, true) => {}
        (true, false) => {
            action.zoom = Some(false);
            action.select_pane = Some(target_pane);
            action.dismiss_alert = Some(target_pane);
        }
    }
    action
}

fn compute_pane_next(state: &LayoutState) -> LayoutAction {
    let mut action = LayoutAction::default();
    if state.pane_count <= 1 {
        return action;
    }
    let next = (state.active_pane + 1) % state.pane_count;
    if state.zoomed {
        action.zoom = Some(true);
    }
    action.select_pane = Some(next);
    action.dismiss_alert = Some(next);
    action
}

fn compute_pane_prev(state: &LayoutState) -> LayoutAction {
    let mut action = LayoutAction::default();
    if state.pane_count <= 1 {
        return action;
    }
    let prev = (state.active_pane + state.pane_count - 1) % state.pane_count;
    if state.zoomed {
        action.zoom = Some(true);
    }
    action.select_pane = Some(prev);
    action.dismiss_alert = Some(prev);
    action
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_state(pane_count: usize, zoomed: bool) -> LayoutState {
        let panes = crate::layout::grid_positions(pane_count, 280, 80)
            .into_iter()
            .enumerate()
            .map(|(i, r)| Pane {
                id: 10 + i as u32,
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
            })
            .collect();
        LayoutState {
            panes,
            window_w: 280,
            window_h: 80,
            border_top: 0,
            zoomed,
            active_pane: 0,
            pane_count,
        }
    }

    #[test]
    fn resize_produces_layout_string() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::Resize);
        assert!(action.layout_string.is_some());
        assert!(action.zoom.is_none());
    }

    #[test]
    fn resize_while_zoomed_skips_layout() {
        let state = make_state(4, true);
        let action = compute_layout(&state, &LayoutEvent::Resize);
        assert!(action.layout_string.is_none());
        assert!(action.zoom.is_none());
    }

    #[test]
    fn resize_empty_panes_skips() {
        let state = LayoutState {
            panes: vec![],
            window_w: 280,
            window_h: 80,
            border_top: 0,
            zoomed: false,
            active_pane: 0,
            pane_count: 0,
        };
        let action = compute_layout(&state, &LayoutEvent::Resize);
        assert!(action.layout_string.is_none());
    }

    #[test]
    fn add_produces_layout_and_unzooms_when_zoomed() {
        let state = make_state(4, true);
        let action = compute_layout(&state, &LayoutEvent::AddPane(99));
        assert!(action.layout_string.is_some());
        assert_eq!(action.zoom, Some(false));
    }

    #[test]
    fn add_at_working_does_not_change_zoom() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::AddPane(99));
        assert!(action.layout_string.is_some());
        assert!(action.zoom.is_none());
    }

    #[test]
    fn remove_produces_layout_and_unzooms_when_zoomed() {
        let state = make_state(4, true);
        let action = compute_layout(&state, &LayoutEvent::RemovePane(13));
        assert!(action.layout_string.is_some());
        assert_eq!(action.zoom, Some(false));
    }

    #[test]
    fn zoom_in_from_working() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::ZoomIn);
        assert_eq!(action.zoom, Some(true));
        assert_eq!(action.dismiss_alert, Some(0));
    }

    #[test]
    fn zoom_in_when_already_zoomed_is_noop() {
        let state = make_state(4, true);
        let action = compute_layout(&state, &LayoutEvent::ZoomIn);
        assert!(action.zoom.is_none());
    }

    #[test]
    fn zoom_out_from_zoomed() {
        let state = make_state(4, true);
        let action = compute_layout(&state, &LayoutEvent::ZoomOut);
        assert_eq!(action.zoom, Some(false));
        assert!(!action.open_spaces);
    }

    #[test]
    fn zoom_out_from_working_opens_spaces() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::ZoomOut);
        assert!(action.open_spaces);
        assert!(action.zoom.is_none());
    }

    #[test]
    fn zoom_to_same_pane_at_working_zooms_in() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::ZoomTo(0));
        assert_eq!(action.zoom, Some(true));
    }

    #[test]
    fn zoom_to_different_pane_at_working_selects() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::ZoomTo(2));
        assert_eq!(action.select_pane, Some(2));
        assert!(action.zoom.is_none());
    }

    #[test]
    fn zoom_to_different_pane_when_zoomed_unzooms() {
        let mut state = make_state(4, true);
        state.active_pane = 0;
        let action = compute_layout(&state, &LayoutEvent::ZoomTo(2));
        assert_eq!(action.zoom, Some(false));
        assert_eq!(action.select_pane, Some(2));
    }

    #[test]
    fn zoom_to_nonexistent_pane_returns_error() {
        let state = make_state(4, false);
        let action = compute_layout(&state, &LayoutEvent::ZoomTo(10));
        assert!(action.error_message.is_some());
    }

    #[test]
    fn pane_next_at_working() {
        let mut state = make_state(3, false);
        state.active_pane = 0;
        let action = compute_layout(&state, &LayoutEvent::PaneNext);
        assert_eq!(action.select_pane, Some(1));
        assert!(action.zoom.is_none());
    }

    #[test]
    fn pane_next_wraps() {
        let mut state = make_state(3, false);
        state.active_pane = 2;
        let action = compute_layout(&state, &LayoutEvent::PaneNext);
        assert_eq!(action.select_pane, Some(0));
    }

    #[test]
    fn pane_next_when_zoomed_stays_zoomed() {
        let mut state = make_state(3, true);
        state.active_pane = 0;
        let action = compute_layout(&state, &LayoutEvent::PaneNext);
        assert_eq!(action.select_pane, Some(1));
        assert_eq!(action.zoom, Some(true));
    }

    #[test]
    fn pane_prev_at_working() {
        let mut state = make_state(3, false);
        state.active_pane = 1;
        let action = compute_layout(&state, &LayoutEvent::PanePrev);
        assert_eq!(action.select_pane, Some(0));
    }

    #[test]
    fn pane_prev_wraps() {
        let mut state = make_state(3, false);
        state.active_pane = 0;
        let action = compute_layout(&state, &LayoutEvent::PanePrev);
        assert_eq!(action.select_pane, Some(2));
    }

    #[test]
    fn single_pane_next_is_noop() {
        let state = make_state(1, false);
        let action = compute_layout(&state, &LayoutEvent::PaneNext);
        assert!(action.select_pane.is_none());
    }
}
