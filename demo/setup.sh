#!/bin/bash
# Set up the amux demo session with realistic AI agent content.
# Run before VHS recording.

SESSION="amux-demo"
BIN="amux"
ESC=$'\033'

tmux kill-session -t "$SESSION" 2>/dev/null
tmux new-session -d -s "$SESSION" -x 160 -y 45
AMUX_SESSION="$SESSION" $BIN refresh
tmux set-option -t "$SESSION" @amux-level 2

# Create 3 more panes (4 total)
AMUX_SESSION="$SESSION" $BIN new "myapp/review"
AMUX_SESSION="$SESSION" $BIN new "myapp/permissions"
AMUX_SESSION="$SESSION" $BIN new "myapp/main"
AMUX_SESSION="$SESSION" $BIN layout "$SESSION" 2>/dev/null

# Rename pane 1
tmux set-option -p -t "${SESSION}:0.0" @amux-title "myapp/plan"
sleep 0.5

# Helper: fill a pane with content from a temp file
fill_pane() {
    local target="$1"
    local content="$2"
    local tmpfile="/tmp/amux-demo-$$"
    # Pad with leading newlines so the 'cat' command scrolls off the top
    printf '\n%.0s' {1..50} > "$tmpfile"
    printf '%b\n' "$content" >> "$tmpfile"
    tmux send-keys -t "$target" "clear" Enter
    sleep 0.2
    tmux send-keys -t "$target" "cat '$tmpfile'" Enter
    sleep 0.5
}

# --- Pane 1 (index 0): Plan output — long, will be cut off at grid size ---
PLAN="${ESC}[1;37m## Implementation Plan${ESC}[0m

${ESC}[1;36m### Step 1: Extract token validation${ESC}[0m
  Create ${ESC}[33msrc/auth/validate.rs${ESC}[0m with pure validation logic
  - Move ${ESC}[33mvalidate_jwt()${ESC}[0m from middleware.rs
  - Add expiry check, signature verification
  - Unit tests: 6 cases (valid, expired, malformed, wrong-key)

${ESC}[1;36m### Step 2: Add refresh token rotation${ESC}[0m
  Update ${ESC}[33msrc/auth/tokens.rs${ESC}[0m
  - Generate new refresh token on each use
  - Store token family for reuse detection
  - Invalidate entire family on reuse attempt

${ESC}[1;36m### Step 3: Database migration${ESC}[0m
  Create ${ESC}[33mmigrations/20260329_sessions.sql${ESC}[0m
  - Add ${ESC}[33msessions${ESC}[0m table with TTL column
  - Add composite index on ${ESC}[33m(user_id, expires_at)${ESC}[0m
  - Backfill from existing token store

${ESC}[1;36m### Step 4: Integration tests${ESC}[0m
  - Token lifecycle: create, refresh, expire, revoke
  - Concurrent session limits (max 3 per user)
  - Rate limiting on auth endpoints
  - Refresh token reuse detection

${ESC}[1;36m### Step 5: Update API documentation${ESC}[0m
  - Document new auth flow in OpenAPI spec
  - Add migration guide for v1 → v2 tokens
  - Update Postman collection with new endpoints

${ESC}[1;32mReady to proceed. 5 steps, estimated 12 files changed.${ESC}[0m"

fill_pane "${SESSION}:0.0" "$PLAN"

# --- Pane 2 (index 1): Code review output ---
REVIEW="${ESC}[1;37m## Code Review: auth-refactor${ESC}[0m

${ESC}[33msrc/auth/middleware.rs${ESC}[0m
${ESC}[32m+ pub fn validate_request(req: &Request) -> Result<Claims> {${ESC}[0m
${ESC}[32m+     let token = extract_bearer(req)?;${ESC}[0m
${ESC}[32m+     validate_jwt(&token)${ESC}[0m
${ESC}[32m+ }${ESC}[0m

${ESC}[90mL45-89: Good extraction. The old inline parsing was getting unwieldy.${ESC}[0m

${ESC}[33msrc/auth/tokens.rs${ESC}[0m
${ESC}[32m+ pub fn rotate_refresh_token(family: &TokenFamily) -> Result<TokenPair> {${ESC}[0m
${ESC}[32m+     if family.is_reused() {${ESC}[0m
${ESC}[31m+         revoke_family(family.id)?;  // nuclear option${ESC}[0m
${ESC}[32m+         return Err(AuthError::TokenReuse);${ESC}[0m
${ESC}[32m+     }${ESC}[0m

${ESC}[1;33mComment:${ESC}[0m ${ESC}[90mThe revoke_family call should also invalidate active
  sessions, not just tokens. Otherwise a stolen token can still
  be used until it expires naturally.${ESC}[0m

${ESC}[33mtests/auth_test.rs${ESC}[0m
${ESC}[90mTest coverage looks good. Consider adding a test for the race
  condition where two refresh requests arrive simultaneously.${ESC}[0m

${ESC}[1;37mOverall: Approve with comments. 2 items to address.${ESC}[0m"

fill_pane "${SESSION}:0.1" "$REVIEW"

# --- Pane 3 (index 2): Permission prompt ---
PROMPT="${ESC}[1;37mAnalyzing codebase for auth-related files...${ESC}[0m

Scanned 847 files in ${ESC}[33msrc/${ESC}[0m

${ESC}[1;37mI need to modify these files:${ESC}[0m

  ${ESC}[33msrc/auth/middleware.rs${ESC}[0m  — extract validation logic
  ${ESC}[33msrc/auth/tokens.rs${ESC}[0m      — add rotation
  ${ESC}[33msrc/auth/mod.rs${ESC}[0m         — update exports
  ${ESC}[33mtests/auth_test.rs${ESC}[0m      — add new test cases

${ESC}[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ESC}[0m

${ESC}[1;33mAllow editing these 4 files? (y/n)${ESC}[0m"

fill_pane "${SESSION}:0.2" "$PROMPT"

# --- Pane 4 (index 3): Active Claude Code session ---
ACTIVE="${ESC}[1;37mOn branch auth-refactor${ESC}[0m
Changes not staged for commit:

  ${ESC}[31mmodified:   src/auth/middleware.rs${ESC}[0m
  ${ESC}[31mmodified:   src/auth/tokens.rs${ESC}[0m
  ${ESC}[32mnew file:   src/auth/validate.rs${ESC}[0m
  ${ESC}[32mnew file:   tests/auth_test.rs${ESC}[0m

4 files changed"

fill_pane "${SESSION}:0.3" "$ACTIVE"

# --- Set active pane and alerts ---
# Pane 1 (plan) is active so first zoom-in goes straight to it.
# Alerts on pane 1 (plan done) and pane 3 (permissions needed).
tmux select-pane -t "${SESSION}:0.0"
tmux set-option -p -t "${SESSION}:0.0" @amux-alert 1
tmux set-option -p -t "${SESSION}:0.2" @amux-alert 1
tmux set-option -t "$SESSION" @amux-alert-count 2

echo "Demo session '$SESSION' ready."
