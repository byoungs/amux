# Sticky Pane Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the pane matching algorithm so that adding/removing panes produces deterministic, intuitive placement — passing all 14 sticky pane tests.

**Architecture:** Replace the "reserve last slot" matching strategy with Option A (match existing panes to ALL slots, let the empty slot emerge naturally). This fixes 3 of 4 failing tests. The fourth (`remove_tl_from_5_substitute_fills`) fails because the right-column pane's center (far right, mid-height) is geometrically far from TL (far left, top) — this needs the matching to also run when going_down, not just going_up.

**Tech Stack:** Rust, pure algorithmic changes in `src/sticky.rs` and `src/tmux.rs`

**Worktree:** `.worktrees/fix-sticky-3to4` (branch `fix-sticky-3to4`)

---

## Analysis of Failing Tests

### 1. `add_pane_3_to_4` — FAILS because "reserve last slot" is wrong

Current code: reserves slot 3 (BR) for new pane, matches 3 existing panes to slots 0-2 (TL, TR, BL). The full-height left pane (center 69,40) is closer to BL (69,60) than TL (69,19), so it goes to BL — displacing right-bottom to TL.

**Fix:** Match all 3 existing panes to all 4 slots. The greedy algorithm leaves BL empty (the natural gap), which is where the new pane should go.

### 2. `add_pane_7_to_8` — Same class of bug

Current code reserves slot 7 (BR of 4x2) for the new pane. The right column pane (full-height, mid-height center) gets misplaced.

**Fix:** Same as #1 — match all 7 existing to all 8 slots.

### 3. `remove_tm_from_3x2` — Geometric mismatch

After removing TM from a 3x2, the remaining 5 panes go to a 5-pane layout (2x2 + right column). The current matching (going_down, uses current centers) gets close but BR pane misplaces because the 3x2 column 2 center (x=233) is closer to the 5-pane right column (x=233) than to the 2x2 BR slot (x=93).

**Fix:** Pane 14 (BM, x=139) goes to the right column because its column-mate was removed. Pane 15 (BR, x=233) should go to 2x2 BR (x=93) — but geometrically it's closer to the right column. The fix is to ensure swapping also runs when going_down (currently only runs when going_up).

### 4. `remove_tl_from_5_substitute_fills` — Swap not running on going_down

After removing TL from a 5-pane layout, the right column pane (center far-right, mid-height) should fill the TL gap. But it's geometrically far from TL. Currently the code skips swapping entirely when going_down (`should_swap = going_up && ...`).

**Fix:** Enable swapping when going_down too. The geometric matching alone handles most cases, but when count changes, swapping is needed both directions.

## Key Insight

Two changes fix all 4 tests:

1. **Option A for adding:** Match existing panes to ALL slots (not just first N-1). The leftover slot is where the new pane goes.
2. **Enable swapping when going_down:** The current code only swaps panes when `going_up`. But removal also needs pane reordering to match the best geometric assignment.

---

## File Map

| File | Change | Purpose |
|------|--------|---------|
| `src/sticky.rs` | None | `match_panes_to_slots` already works correctly — the bug is in how it's called |
| `src/tmux.rs:392-454` | Modify | Change `apply_grid_layout` to use Option A and enable going_down swaps |
| `src/sticky.rs:250-284` | Modify | Update `simulate_add_pane` test helper to reflect Option A |

---

### Task 1: Update `simulate_add_pane` test helper to use Option A

The test helper mirrors the production logic. Update it first so we can verify Option A fixes the adding tests before touching production code.

**Files:**
- Modify: `src/sticky.rs:250-284` (the `simulate_add_pane` test helper)

- [ ] **Step 1: Update the test helper to match all panes to all slots**

In `src/sticky.rs`, change the `simulate_add_pane` function. Remove the slot reservation logic — match existing panes to ALL slots, and let the new pane fill whichever slot is left:

```rust
    fn simulate_add_pane(
        existing: &[PaneCenter],
        new_pane_id: u32,
        new_total: usize,
        w: u16,
        h: u16,
    ) -> Vec<u32> {
        let rects = grid_positions(new_total, w, h);
        let slot_centers = centers_from_rects(&rects);

        // Option A: match existing panes to ALL slots.
        // The leftover slot(s) are where new panes go.
        let matched = match_panes_to_slots(existing, &slot_centers, true);

        let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
        let all_ids: Vec<u32> = existing
            .iter()
            .map(|p| p.id)
            .chain(std::iter::once(new_pane_id))
            .collect();
        let mut unmatched = all_ids.iter().filter(|id| !matched_ids.contains(id));
        let mut ordered: Vec<u32> = matched
            .iter()
            .map(|opt| match opt {
                Some(id) => *id,
                None => *unmatched.next().unwrap(),
            })
            .collect();
        for &id in unmatched {
            ordered.push(id);
        }
        ordered
    }
```

The only change is removing these two lines:
```rust
        let new_count = new_total - existing.len();
        let available = slot_centers.len() - new_count;
```
And changing `&slot_centers[..available]` to `&slot_centers` in the `match_panes_to_slots` call.

- [ ] **Step 2: Run the adding tests to verify Option A fixes them**

Run: `cargo test sticky::tests::add_pane`

Expected: `add_pane_3_to_4`, `add_pane_4_to_5`, `add_pane_5_to_6`, `add_pane_6_to_7` should all PASS. `add_pane_7_to_8` should also PASS now.

- [ ] **Step 3: Run ALL sticky tests to check for regressions**

Run: `cargo test sticky::tests`

Expected: The 3 adding tests that previously failed should now PASS. `remove_tl_from_5_substitute_fills` and `remove_tm_from_3x2` will still FAIL (they need the going_down fix in Task 2). All other tests should still PASS.

- [ ] **Step 4: Commit the test helper fix**

```
git add src/sticky.rs
git commit -m "test: update simulate_add_pane to use Option A matching"
```

---

### Task 2: Update `simulate_remove_pane` to also swap panes

The current `simulate_remove_pane` helper does simple matching without swapping. But the production code needs to swap panes when going_down too. Update the helper to reflect this.

**Files:**
- Modify: `src/sticky.rs:287-303` (the `simulate_remove_pane` test helper)

- [ ] **Step 1: Verify which removal tests currently fail**

Run: `cargo test sticky::tests::remove`

Note which tests fail. Expected: `remove_tl_from_5_substitute_fills` and `remove_tm_from_3x2` fail.

- [ ] **Step 2: Analyze why they fail**

For `remove_tl_from_5_substitute_fills`:
- After removing TL (pane 10) from 5-pane layout, remaining panes are at positions:
  - Pane 11 (TR of 2x2): center ~(93, 19)
  - Pane 12 (BL of 2x2): center ~(0, 60)
  - Pane 13 (BR of 2x2): center ~(93, 60)
  - Pane 14 (right column): center ~(233, 40)
- Target is 4-pane 2x2 with slots at TL(69,19), TR(210,19), BL(69,60), BR(210,60)
- Geometric matching: 11→TL(dist), 12→BL(close), 13→BR(far), 14→TR(far)
- The issue is that pane 14 (x=233) is closer to TR (x=210) than pane 11 (x=93) is. But pane 11 (x=93) is closer to TL (x=69). So greedy: 12→BL, 11→TL, 14→TR, 13→BR. That gives [11, 14, 12, 13] but the test expects [14, 11, 12, 13].

Actually, the geometric matching might produce the right answer here. Let me check more carefully. The issue may be that the test helper and production code differ in how they handle this. The `simulate_remove_pane` helper is straightforward — it should work if the geometry works.

Looking at actual 5-pane slot centers at 280x80 — the 2x2 part uses 3-column layout (col_w = 92):
- TL: x=0, w=92 → center (46, 19)
- TR: x=93, w=92 → center (139, 19)
- BL: x=0, w=92 → center (46, 60)
- BR: x=93, w=92 → center (139, 60)
- R: x=186, w=94 → center (233, 40)

Target 4-pane 2x2 at 280x80 (col_w = 139):
- TL: center (69, 19)
- TR: center (210, 19)
- BL: center (69, 60)
- BR: center (210, 60)

Distances from 5-pane positions to 4-pane slots:
- Pane 11 (139,19) → TL(69,19)=70²=4900, TR(210,19)=71²=5041
- Pane 12 (46,60) → BL(69,60)=23²=529, BR(210,60)=164²=26896
- Pane 13 (139,60) → BL(69,60)=70²=4900, BR(210,60)=71²=5041
- Pane 14 (233,40) → TL(69,19)=164²+21²=27337, TR(210,19)=23²+21²=970

Sorted: 12→BL(529), 14→TR(970), 11→TL(4900), 13→BL(4900-taken)...
Greedy: 12→BL, 14→TR, 11→TL, 13→BR

Result: [11, 14, 12, 13] = [TL=11, TR=14, BL=12, BR=13]

Test expects: [14, 11, 12, 13] = [TL=14, TR=11, BL=12, BR=13]

So geometric matching gives 14→TR, but test wants 14→TL. The test says "R fills the gap left by TL" — meaning the substitute fills exactly the position that was vacated, and everyone else stays.

The geometric answer (14→TR, 11→TL) is actually reasonable — it minimizes total movement. But the desired behavior is "substitute fills the exact gap." This requires knowing WHICH slot was vacated.

This means pure geometric matching can't solve this — we need structural awareness of which pane was removed and which slot is vacant.

**Resolution:** This test requires the production code to have structural awareness. For now, accept that geometric matching produces [11, 14, 12, 13] and update the test expectation, OR add a more sophisticated matching strategy.

Looking at the user's stated rule: "the full-height column pane fills the hole." The "hole" is the TL position. Geometrically though, 14 is closer to TR than TL.

I think the geometric matching actually produces a BETTER result here — 14 going to TR is less physical movement than 14 going to TL. The user may accept this once they see it in practice. But the test as written requires structural rules.

**Decision:** For this plan, we'll focus on the changes that use geometric matching (Option A) which fixes the adding tests. The removal tests that require structural awareness will be addressed in a follow-up. Mark `remove_tl_from_5_substitute_fills` as a known limitation for now.

Actually, re-reading the conversation more carefully — the user wants the substitute to fill the gap. Let me reconsider. The geometric matching gives [11, 14, 12, 13] which means:
- TL: pane 11 (was at TR of 2x2 in the 5-pane layout)
- TR: pane 14 (was right column)
- BL: pane 12 (stays)
- BR: pane 13 (stays)

So BL and BR stay, and the top row reshuffles. That's not terrible. But the user explicitly wanted: "the right column pane fills the hole. Everyone else stays." That means 14→TL, 11→TR, 12→BL, 13→BR.

For pane 11 to "stay" at TR, it needs to go from 5-pane TR (x=139) to 4-pane TR (x=210). That IS movement — the column got wider. For pane 14 to fill TL, it goes from right column (x=233) to TL (x=69) — a big jump. Geometrically this is MORE total movement.

The user's rule prioritizes "concept stability" (the substitute fills the conceptual gap) over "pixel stability." This is a valid design choice but requires structural rules, not just geometry.

**Revised approach:** Instead of pure geometry for removals, use a two-phase approach:
1. First, identify which slots the non-removed, non-column panes should keep (they stay in the same relative positions)
2. Then, the column pane fills the remaining slot

This can be implemented as: when going_down from an odd count (balanced+column → balanced), the right-column pane's previous slot assignment gets the vacated slot.

Actually, there's a simpler approach. The `simulate_remove_pane` helper currently has no awareness of the structural rules. We don't need to change `match_panes_to_slots` — we need a different calling pattern for the structural cases.

Let me step back and think about what the production code needs to do differently for each case. The 4 cases:

**For adding (going_up):**
- Change: match all panes to all slots instead of reserving last slot

**For removing (going_down):**
- The geometric matching works for MOST removal cases (the 8 passing removal tests prove this)
- The 2 failing removal tests are where panes jump columns. The fix is: when going from balanced+column to balanced, the column pane should preferentially fill the vacated slot
- But the production code doesn't know which slot was vacated — it just sees the remaining panes and the new layout

I think the simplest fix for the removal tests is to also match to all slots and enable swapping when going_down. Let me re-check the math...

For `remove_tl_from_5_substitute_fills` with all-slot matching:
Going_down uses current centers. Remaining panes and 4-pane targets:
- Pane 11 at (139,19) → TL(69,19)=4900, TR(210,19)=5041 → prefers TL
- Pane 12 at (46,60) → BL(69,60)=529 → strong preference for BL
- Pane 13 at (139,60) → BL(69,60)=4900, BR(210,60)=5041 → prefers BL
- Pane 14 at (233,40) → TR(210,19)=970, BR(210,60)=929 → prefers BR

Greedy sorted: 12→BL(529), 14→BR(929), 14→TR(970-skip), 11→TL(4900), 13→BL(4900-skip), 11→TR(5041)...

Result: 12→BL, 14→BR, 11→TL, 13→TR
Ordered: [11, 13, 12, 14]

Test expects: [14, 11, 12, 13]

Still different. The geometric answer puts 14 at BR and 13 at TR. The user wants 14 at TL.

This confirms: geometric matching CANNOT produce the desired result for this test case. The substitute-fills-gap rule requires structural knowledge.

OK, so the plan needs to account for this. Let me think about the minimal change...

The simplest structural rule for removal from a balanced+column layout:
1. Identify that we're going from balanced+column (odd, ≥5) to balanced (even)
2. Find the right-column pane (last slot in the odd layout)
3. Find which slot in the balanced layout is closest to the removed pane's position
4. Assign the right-column pane to that slot
5. Match remaining panes normally

This can be done as a pre-assignment before calling `match_panes_to_slots`. We pre-assign the column pane to the vacated slot, then let geometric matching handle the rest.

For `remove_tl_from_5_substitute_fills`:
- Previous count: 5 (balanced+column). Right-column pane = pane 14.
- Current count: 4 (balanced). Find closest slot to removed TL: TL.
- Pre-assign 14→TL. Match remaining [11,12,13] to [TR,BL,BR].
- 11(139,19)→TR(210,19)=5041, 12(46,60)→BL(69,60)=529, 13(139,60)→BR(210,60)=5041
- Greedy: 12→BL, then 11→TR and 13→BR (both dist 5041, 11 first alphabetically... actually by pair order)
- Result: [14, 11, 12, 13] ✓

For `remove_tm_from_3x2`:
- Previous count: 6 (balanced 3x2). This is balanced → balanced+column (odd).
- Need: column-mate rule. When removing from column, the column-mate takes the right column position.

Hmm, this is 6→5, going from balanced (6) to balanced+column (5). The rule is: column-mate of removed pane takes the full-height column.

For this case:
- Removed: pane 11 (TM at x=139, y=19)
- Column-mate: pane 14 (BM at x=139, y=60)
- Pre-assign 14→right column (slot 4 of 5-pane layout)
- Match remaining [10,12,13,15] to slots [TL,TR,BL,BR]
- 10(46,19)→TL(46,19)=0, 12(233,19)→TR(93,19)=140²=19600 or TL=187²=..., 13(46,60)→BL(46,60)=0, 15(233,60)→BR(93,60)=140²=19600
- Greedy: 10→TL(0), 13→BL(0), then 12→TR and 15→BR
- Result: [10, 12, 13, 15, 14] ✓

So the structural rule works for both cases. The implementation:

For **balanced → balanced+column** (6→5, 8→7, etc.):
- Identify the column of the removed pane (which of the N columns it was in)
- Its column-mate goes to the right column slot
- Other panes match geometrically to the remaining 2x2 slots

For **balanced+column → balanced** (5→4, 7→6, etc.):
- The right-column pane is the "substitute"
- It fills the slot closest to the removed pane's position
- Other panes match geometrically

But the production code in `apply_grid_layout` doesn't know which pane was removed — it just sees the current pane list and the previous count. It would need to compare current IDs against... what? It doesn't store the previous ID list.

Hmm, but the production code DOES store previous pane centers. So it has the old centers but not the old IDs. Actually, `read_all_pane_centers` reads the current panes' stored centers. The removed pane is just... gone.

The production code could detect the structural case by:
1. Checking prev_count vs current count
2. Knowing the layout pattern (balanced vs balanced+column) from the count
3. Using the geometric matching with additional constraints

Actually, the simplest approach for production: instead of pre-assigning based on "which pane was removed" (which we don't know), we can use a different matching strategy for the structural cases:

**For balanced+column → balanced (going_down, odd → even):**
- The pane with the largest x-coordinate (rightmost) is the column pane
- It should get the slot closest to where the gap is
- We can detect the "gap" by comparing pane positions to the new layout

Actually, even simpler: for the test helper, we can encode the structural rules directly since the helper has all the information. For production code, we rely on the fact that the column pane (rightmost) will have a stored center from the right column position, and we need it to jump to where the gap is.

OK I think I'm overcomplicating this. Let me write a clean plan.

The key insight: the test helpers `simulate_add_pane` and `simulate_remove_pane` need to be updated to reflect the DESIRED algorithm. Then the production code in `apply_grid_layout` needs to match.

For the plan:
1. Task 1: Fix adding (Option A) — test helper + verify
2. Task 2: Fix removal structural rules — test helper + verify
3. Task 3: Update production code in apply_grid_layout to match

Let me rewrite the plan with this approach.

- [ ] **Step 2: No changes needed to `simulate_remove_pane`**

The `simulate_remove_pane` helper uses explicit target slot rects and basic geometric matching. The two failing removal tests fail because pure geometric matching doesn't understand the structural rules (column-mate expands, substitute fills gap).

The fix requires structural awareness. Skip to Task 3 which implements the structural rules as a separate matching function.

- [ ] **Step 3: Run removal tests to confirm current state**

Run: `cargo test sticky::tests::remove`

Expected: `remove_tl_from_5_substitute_fills` and `remove_tm_from_3x2` FAIL. All others PASS.

---

### Task 3: Implement structural matching for removal cases

The geometric matching works for most cases but fails when panes need to jump columns during layout transitions. Add a structural matching function that encodes the column-mate and substitute rules.

**Files:**
- Modify: `src/sticky.rs` — add `match_panes_structural` function and update `simulate_remove_pane`

- [ ] **Step 1: Add the structural matching function**

Add this function to `src/sticky.rs` (above the `#[cfg(test)]` module):

```rust
/// Structural matching for removal transitions.
///
/// When the layout shape changes (balanced ↔ balanced+column), pure geometric
/// matching can misplace panes that need to jump columns. This function uses
/// structural rules instead:
///
/// - **Balanced → balanced+column** (6→5, 8→7): the removed pane's column-mate
///   takes the full-height right column. Other panes fill the balanced part.
///
/// - **Balanced+column → balanced** (5→4, 7→6): the right-column pane fills
///   the slot vacated by the removed pane. Other panes stay.
///
/// Falls back to geometric matching for cases that don't match these patterns.
pub fn match_panes_structural(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    prev_count: usize,
    new_count: usize,
) -> Vec<Option<u32>> {
    let prev_balanced = prev_count >= 4 && prev_count % 2 == 0;
    let new_balanced = new_count >= 4 && new_count % 2 == 0;
    let prev_has_column = prev_count >= 5 && prev_count % 2 == 1;
    let new_has_column = new_count >= 5 && new_count % 2 == 1;

    // Balanced+column → balanced (5→4, 7→6): substitute fills gap
    if prev_has_column && new_balanced && new_count == prev_count - 1 {
        return match_substitute_fills_gap(panes, slots, prev_count);
    }

    // Balanced → balanced+column (6→5, 8→7): column-mate expands
    if prev_balanced && new_has_column && new_count == prev_count - 1 {
        return match_column_mate_expands(panes, slots, prev_count);
    }

    // Default: geometric matching
    match_panes_to_slots(panes, slots, false)
}

/// The right-column pane from the previous layout fills the gap left by the
/// removed pane. All other panes stay in their relative positions.
fn match_substitute_fills_gap(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    prev_count: usize,
) -> Vec<Option<u32>> {
    // The right-column pane is the one with the largest cx (rightmost).
    let substitute_idx = panes
        .iter()
        .enumerate()
        .max_by_key(|(_, p)| p.cx)
        .map(|(i, _)| i);

    if let Some(sub_idx) = substitute_idx {
        // Match all OTHER panes to slots geometrically first
        let others: Vec<PaneCenter> = panes
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != sub_idx)
            .map(|(_, p)| p.clone())
            .collect();

        let matched = match_panes_to_slots(&others, slots, false);

        // Find the unoccupied slot — that's where the substitute goes
        let mut result = matched;
        for slot in result.iter_mut() {
            if slot.is_none() {
                *slot = Some(panes[sub_idx].id);
                break;
            }
        }
        result
    } else {
        match_panes_to_slots(panes, slots, false)
    }
}

/// The column-mate of the removed pane takes the full-height right column.
/// The remaining panes fill the balanced part.
fn match_column_mate_expands(
    panes: &[PaneCenter],
    slots: &[SlotCenter],
    prev_count: usize,
) -> Vec<Option<u32>> {
    // In the previous balanced grid, columns had 2 panes each.
    // The removed pane left its column-mate alone. The column-mate is the
    // pane whose cx doesn't have a partner (other pane with same cx).
    //
    // Find the pane whose cx is unique (no other pane shares it ±10%).
    let column_mate_idx = find_lone_column_pane(panes);

    let right_col_slot = slots.len() - 1; // Last slot is the right column

    if let Some(mate_idx) = column_mate_idx {
        // Pre-assign the column-mate to the right column slot
        let others: Vec<PaneCenter> = panes
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != mate_idx)
            .map(|(_, p)| p.clone())
            .collect();

        // Match others to all slots EXCEPT the right column
        let other_slots = &slots[..right_col_slot];
        let mut result = match_panes_to_slots(&others, other_slots, false);

        // Append the column-mate in the right column slot
        result.push(Some(panes[mate_idx].id));
        result
    } else {
        match_panes_to_slots(panes, slots, false)
    }
}

/// Find the pane that is alone in its column (no other pane shares a similar cx).
/// In a balanced grid, each column has exactly 2 panes at the same x position.
/// After one is removed, the survivor has no column partner.
fn find_lone_column_pane(panes: &[PaneCenter]) -> Option<usize> {
    for (i, p) in panes.iter().enumerate() {
        let has_partner = panes.iter().enumerate().any(|(j, other)| {
            j != i && (p.cx - other.cx).abs() < 10
        });
        if !has_partner {
            return Some(i);
        }
    }
    None
}
```

- [ ] **Step 2: Update `simulate_remove_pane` to use structural matching**

In `src/sticky.rs`, update the test helper:

```rust
    fn simulate_remove_pane(
        panes_before: &[PaneCenter],
        removed_id: u32,
        target_rects: &[Rect],
    ) -> Vec<u32> {
        let remaining: Vec<PaneCenter> = panes_before
            .iter()
            .filter(|p| p.id != removed_id)
            .cloned()
            .collect();
        let slots = centers_from_rects(target_rects);
        let matched = match_panes_structural(
            &remaining,
            &slots,
            panes_before.len(),
            target_rects.len(),
        );
        matched.iter().map(|opt| opt.unwrap()).collect()
    }
```

- [ ] **Step 3: Run all sticky tests**

Run: `cargo test sticky::tests`

Expected: All 14 tests PASS.

- [ ] **Step 4: Commit**

```
git add src/sticky.rs
git commit -m "feat: add structural matching for column-mate and substitute rules"
```

---

### Task 4: Update production code in `apply_grid_layout`

Now that the test helpers reflect the desired algorithm, update the production code in `tmux.rs` to match.

**Files:**
- Modify: `src/tmux.rs:392-454` (the `count_changed` block in `apply_grid_layout`)

- [ ] **Step 1: Replace the matching logic in `apply_grid_layout`**

In `src/tmux.rs`, replace the matching block inside `if count_changed { ... }` (lines 394-454) with:

```rust
    if count_changed {
        let rects = crate::layout::grid_positions(ids.len(), w, effective_h);
        let slot_centers: Vec<crate::sticky::SlotCenter> = rects
            .iter()
            .map(|r| {
                let (cx, cy) = crate::sticky::rect_center(r.x, r.y, r.w, r.h);
                crate::sticky::SlotCenter { cx, cy }
            })
            .collect();

        let pane_centers = crate::sticky::read_all_pane_centers(session).unwrap_or_default();
        let going_up = (ids.len() as i32) > prev_count;

        // Build matching input — only include panes that have saved center data.
        // New panes (no center data) are excluded and fill leftover slots.
        let match_input: Vec<crate::sticky::PaneCenter> = ids
            .iter()
            .filter_map(|&id| {
                pane_centers
                    .iter()
                    .find(|p| p.id == id)
                    .filter(|p| p.cx != 0 || p.cy != 0 || p.prev_cx.is_some())
                    .cloned()
            })
            .collect();

        let matched = if going_up {
            // Adding panes: match existing to ALL slots, new panes fill leftovers
            crate::sticky::match_panes_to_slots(&match_input, &slot_centers, true)
        } else {
            // Removing panes: use structural matching for column-mate/substitute rules
            crate::sticky::match_panes_structural(
                &match_input,
                &slot_centers,
                prev_count as usize,
                ids.len(),
            )
        };

        let matched_ids: Vec<u32> = matched.iter().filter_map(|&id| id).collect();
        let mut unmatched_iter = ids.iter().filter(|id| !matched_ids.contains(id));
        let mut ordered_ids: Vec<u32> = matched
            .iter()
            .map(|opt| match opt {
                Some(id) => *id,
                None => *unmatched_iter.next().unwrap_or(&ids[0]),
            })
            .collect();
        for &id in unmatched_iter {
            ordered_ids.push(id);
        }

        // Swap panes when the ordering differs from tmux's index order.
        // This runs for BOTH going_up and going_down — both directions can
        // require pane reordering after layout shape changes.
        let has_spatial_history = match_input.iter().any(|p| p.prev_cx.is_some())
            || !going_up; // going_down always has spatial history (panes have centers)
        if has_spatial_history && ordered_ids != ids {
            swap_panes_to_order(session, &ids, &ordered_ids)?;
        }
    }
```

- [ ] **Step 2: Run all tests (unit + integration)**

Run: `cargo test`

Expected: All tests pass — both the 14 sticky unit tests and the tmux integration tests.

- [ ] **Step 3: Build and verify**

Run: `make dev`

The binary is now live. Test manually by:
1. Creating 3 panes (left + right-top + right-bottom)
2. Press Ctrl-N to add a 4th — right column should stay, new pane fills BL
3. Press Ctrl-N to add a 5th — 2x2 stays, new full-height column on right

- [ ] **Step 4: Commit**

```
git add src/tmux.rs
git commit -m "feat: fix sticky pane matching for add/remove transitions

Use Option A for adding: match existing panes to all slots instead of
reserving the last slot. The leftover slot naturally becomes the new
pane's position.

Use structural matching for removal: column-mate expands when removing
from balanced grids, substitute fills gap when removing from
balanced+column layouts.

Enable pane swapping for both going_up and going_down transitions."
```

---

### Task 5: Squash and prepare for review

**Files:** None (git operations only)

- [ ] **Step 1: Run the full check suite**

Run: `make test`

Expected: All checks pass (lint + test + build).

- [ ] **Step 2: Squash commits on the branch**

```
git log --oneline
git rebase -r main
```

Verify clean history, then squash to a single commit:

```
git reset --soft main
git commit -m "feat: sticky pane matching with balanced+column layouts

New alternating layout pattern: balanced grids (even counts) alternate
with balanced+column layouts (odd counts >= 5). Adding a pane to a
balanced grid appends a full-height column on the right. Adding to a
balanced+column layout splits the column.

Matching algorithm changes:
- Adding: match existing panes to ALL slots (Option A), letting the
  new pane fill whichever slot is left over
- Removing from balanced: column-mate expands to full-height column
- Removing from balanced+column: right-column pane fills the gap

Also updates grid_positions for 5/7/9-pane layouts, build_layout_string
for the new tree structure, and adds comprehensive tests covering all
add/remove transitions from 3-9 panes."
```

- [ ] **Step 3: Verify the squashed commit passes**

Run: `make test`

Expected: All pass.
