// LayoutEngine.swift -- Unified layout state machine.
//
// All pane, layout, and zoom state transitions go through `LayoutEngine.computeLayout`.
// It's a pure function: takes a snapshot of current state + an event,
// returns the full set of actions the shell should execute.
//
// Zoom state is derived from tmux's native `window_zoomed_flag` --
// there is no separate level variable. Two states: zoomed (full screen)
// and not-zoomed (working/grid).

/// Snapshot of everything the layout engine needs to make decisions.
public struct LayoutState {
    public var panes: [Pane]
    public var windowW: Int
    public var windowH: Int
    public var borderTop: Int
    public var zoomed: Bool
    public var activePane: Int
    public var paneCount: Int

    public init(
        panes: [Pane], windowW: Int, windowH: Int, borderTop: Int,
        zoomed: Bool, activePane: Int, paneCount: Int
    ) {
        self.panes = panes
        self.windowW = windowW
        self.windowH = windowH
        self.borderTop = borderTop
        self.zoomed = zoomed
        self.activePane = activePane
        self.paneCount = paneCount
    }
}

/// Events that trigger a state transition.
public enum LayoutEvent {
    case addPane(Int)
    case removePane(Int)
    case resize
    case zoomIn
    case zoomOut
    case zoomTo(Int)
    case paneNext
    case panePrev
}

/// The full set of tmux mutations the shell should execute.
public struct LayoutAction {
    public var layoutString: String?
    public var zoom: Bool?
    public var selectPane: Int?
    public var openSpaces: Bool
    public var dismissAlert: Int?
    public var errorMessage: String?

    public init() {
        self.layoutString = nil
        self.zoom = nil
        self.selectPane = nil
        self.openSpaces = false
        self.dismissAlert = nil
        self.errorMessage = nil
    }
}

/// Pure layout state machine.
public enum LayoutEngine {

    /// Pure state transition: given current state and an event, compute all actions.
    public static func computeLayout(state: LayoutState, event: LayoutEvent) -> LayoutAction {
        switch event {
        case .addPane(let id):
            return computeAdd(state: state, newId: id)
        case .removePane(let id):
            return computeRemove(state: state, removedId: id)
        case .resize:
            return computeResize(state: state)
        case .zoomIn:
            return computeZoomIn(state: state)
        case .zoomOut:
            return computeZoomOut(state: state)
        case .zoomTo(let pane):
            return computeZoomTo(state: state, targetPane: pane)
        case .paneNext:
            return computePaneNext(state: state)
        case .panePrev:
            return computePanePrev(state: state)
        }
    }

    private static func buildGridLayout(state: LayoutState, stickyEvent: StickyLayoutEvent) -> String? {
        let effectiveH = max(state.windowH - state.borderTop, 0)
        let newPanes = AmuxLib.computeLayout(
            current: state.panes, event: stickyEvent,
            windowW: state.windowW, windowH: effectiveH
        )
        return buildLayoutString(
            panes: newPanes, windowW: state.windowW,
            windowH: state.windowH, borderTop: state.borderTop
        )
    }

    private static func computeAdd(state: LayoutState, newId: Int) -> LayoutAction {
        var action = LayoutAction()
        if state.panes.count > 1 && state.zoomed {
            action.zoom = false
        }
        action.layoutString = buildGridLayout(state: state, stickyEvent: .add(newId))
        return action
    }

    private static func computeRemove(state: LayoutState, removedId: Int) -> LayoutAction {
        var action = LayoutAction()
        if state.panes.count > 1 && state.zoomed {
            action.zoom = false
        }
        action.layoutString = buildGridLayout(state: state, stickyEvent: .remove(removedId))
        return action
    }

    private static func computeResize(state: LayoutState) -> LayoutAction {
        let action = LayoutAction()
        if state.zoomed {
            return action
        }
        if state.panes.isEmpty {
            return action
        }
        var result = action
        result.layoutString = buildGridLayout(state: state, stickyEvent: .resize)
        return result
    }

    private static func computeZoomIn(state: LayoutState) -> LayoutAction {
        var action = LayoutAction()
        if !state.zoomed {
            action.zoom = true
            action.dismissAlert = state.activePane
        }
        return action
    }

    private static func computeZoomOut(state: LayoutState) -> LayoutAction {
        var action = LayoutAction()
        if state.zoomed {
            action.zoom = false
        } else {
            action.openSpaces = true
        }
        return action
    }

    private static func computeZoomTo(state: LayoutState, targetPane: Int) -> LayoutAction {
        var action = LayoutAction()
        if targetPane >= state.paneCount {
            action.errorMessage = "Pane \(targetPane + 1) does not exist (have \(state.paneCount))"
            return action
        }
        let samePane = state.activePane == targetPane
        switch (state.zoomed, samePane) {
        case (false, true):
            action.zoom = true
        case (false, false):
            action.selectPane = targetPane
            action.dismissAlert = targetPane
        case (true, true):
            break
        case (true, false):
            action.zoom = false
            action.selectPane = targetPane
            action.dismissAlert = targetPane
        }
        return action
    }

    private static func computePaneNext(state: LayoutState) -> LayoutAction {
        var action = LayoutAction()
        if state.paneCount <= 1 {
            return action
        }
        let next = (state.activePane + 1) % state.paneCount
        if state.zoomed {
            action.zoom = true
        }
        action.selectPane = next
        action.dismissAlert = next
        return action
    }

    private static func computePanePrev(state: LayoutState) -> LayoutAction {
        var action = LayoutAction()
        if state.paneCount <= 1 {
            return action
        }
        let prev = (state.activePane + state.paneCount - 1) % state.paneCount
        if state.zoomed {
            action.zoom = true
        }
        action.selectPane = prev
        action.dismissAlert = prev
        return action
    }
}

// MARK: - Tests

#if DEBUG
public enum LayoutEngineTests {
    public static func makeState(paneCount: Int, zoomed: Bool) -> LayoutState {
        let rects = gridPositions(count: paneCount, width: 280, height: 80)
        let panes = rects.enumerated().map { (i, r) in
            Pane(id: 10 + i, x: r.x, y: r.y, w: r.w, h: r.h)
        }
        return LayoutState(
            panes: panes,
            windowW: 280,
            windowH: 80,
            borderTop: 0,
            zoomed: zoomed,
            activePane: 0,
            paneCount: paneCount
        )
    }

    public static func runAll() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool, _ message: String = "") {
            if condition { passed += 1 }
            else { failed += 1; print("FAIL: \(name)\(message.isEmpty ? "" : " -- \(message)")") }
        }

        // resize produces layout string
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .resize)
            check("resize produces layout string", action.layoutString != nil)
            check("resize does not change zoom", action.zoom == nil)
        }

        // resize while zoomed skips layout
        do {
            let state = makeState(paneCount: 4, zoomed: true)
            let action = LayoutEngine.computeLayout(state: state, event: .resize)
            check("resize while zoomed skips layout", action.layoutString == nil)
            check("resize while zoomed no zoom change", action.zoom == nil)
        }

        // resize empty panes skips
        do {
            let state = LayoutState(
                panes: [], windowW: 280, windowH: 80, borderTop: 0,
                zoomed: false, activePane: 0, paneCount: 0
            )
            let action = LayoutEngine.computeLayout(state: state, event: .resize)
            check("resize empty panes skips", action.layoutString == nil)
        }

        // add produces layout and unzooms when zoomed
        do {
            let state = makeState(paneCount: 4, zoomed: true)
            let action = LayoutEngine.computeLayout(state: state, event: .addPane(99))
            check("add produces layout when zoomed", action.layoutString != nil)
            check("add unzooms when zoomed", action.zoom == false)
        }

        // add at working does not change zoom
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .addPane(99))
            check("add produces layout at working", action.layoutString != nil)
            check("add does not change zoom at working", action.zoom == nil)
        }

        // remove produces layout and unzooms when zoomed
        do {
            let state = makeState(paneCount: 4, zoomed: true)
            let action = LayoutEngine.computeLayout(state: state, event: .removePane(13))
            check("remove produces layout when zoomed", action.layoutString != nil)
            check("remove unzooms when zoomed", action.zoom == false)
        }

        // zoom in from working
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomIn)
            check("zoom in sets zoom true", action.zoom == true)
            check("zoom in dismisses active pane alert", action.dismissAlert == 0)
        }

        // zoom in when already zoomed is noop
        do {
            let state = makeState(paneCount: 4, zoomed: true)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomIn)
            check("zoom in when zoomed is noop", action.zoom == nil)
        }

        // zoom out from zoomed
        do {
            let state = makeState(paneCount: 4, zoomed: true)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomOut)
            check("zoom out sets zoom false", action.zoom == false)
            check("zoom out does not open spaces", action.openSpaces == false)
        }

        // zoom out from working opens spaces
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomOut)
            check("zoom out from working opens spaces", action.openSpaces == true)
            check("zoom out from working no zoom change", action.zoom == nil)
        }

        // zoom to same pane at working zooms in
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomTo(0))
            check("zoom to same pane zooms in", action.zoom == true)
        }

        // zoom to different pane at working selects
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomTo(2))
            check("zoom to different pane selects", action.selectPane == 2)
            check("zoom to different pane no zoom", action.zoom == nil)
        }

        // zoom to different pane when zoomed unzooms
        do {
            var state = makeState(paneCount: 4, zoomed: true)
            state.activePane = 0
            let action = LayoutEngine.computeLayout(state: state, event: .zoomTo(2))
            check("zoom to different when zoomed unzooms", action.zoom == false)
            check("zoom to different when zoomed selects", action.selectPane == 2)
        }

        // zoom to nonexistent pane returns error
        do {
            let state = makeState(paneCount: 4, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .zoomTo(10))
            check("zoom to nonexistent returns error", action.errorMessage != nil)
        }

        // pane next at working
        do {
            var state = makeState(paneCount: 3, zoomed: false)
            state.activePane = 0
            let action = LayoutEngine.computeLayout(state: state, event: .paneNext)
            check("pane next selects next", action.selectPane == 1)
            check("pane next no zoom change", action.zoom == nil)
        }

        // pane next wraps
        do {
            var state = makeState(paneCount: 3, zoomed: false)
            state.activePane = 2
            let action = LayoutEngine.computeLayout(state: state, event: .paneNext)
            check("pane next wraps to 0", action.selectPane == 0)
        }

        // pane next when zoomed stays zoomed
        do {
            var state = makeState(paneCount: 3, zoomed: true)
            state.activePane = 0
            let action = LayoutEngine.computeLayout(state: state, event: .paneNext)
            check("pane next zoomed selects next", action.selectPane == 1)
            check("pane next zoomed stays zoomed", action.zoom == true)
        }

        // pane prev at working
        do {
            var state = makeState(paneCount: 3, zoomed: false)
            state.activePane = 1
            let action = LayoutEngine.computeLayout(state: state, event: .panePrev)
            check("pane prev selects prev", action.selectPane == 0)
        }

        // pane prev wraps
        do {
            var state = makeState(paneCount: 3, zoomed: false)
            state.activePane = 0
            let action = LayoutEngine.computeLayout(state: state, event: .panePrev)
            check("pane prev wraps to last", action.selectPane == 2)
        }

        // single pane next is noop
        do {
            let state = makeState(paneCount: 1, zoomed: false)
            let action = LayoutEngine.computeLayout(state: state, event: .paneNext)
            check("single pane next is noop", action.selectPane == nil)
        }

        print("LayoutEngine tests: \(passed) passed, \(failed) failed")
        if failed > 0 { fatalError("LayoutEngine tests failed") }
    }
}
#endif
