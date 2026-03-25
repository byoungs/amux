#!/bin/bash
# Demo driver — run this in a SEPARATE terminal while screen recording.
#
# Usage:
#   1. Start your screen recorder
#   2. In a terminal that is NOT inside amux, run: bash docs/demo-driver.sh
#   3. Watch the demo play out, stop recording when done
#
# This script creates a fresh amux session, runs the demo, then cleans up.

SESSION="amux-demo"
send() { tmux send-keys -t "$SESSION" "$@"; }
pause() { sleep "$1"; }

# Kill any leftover demo session
tmux kill-session -t "$SESSION" 2>/dev/null

echo "Starting amux demo session..."
AMUX_SESSION="$SESSION" amux start &
sleep 2

echo "Starting demo in 3 seconds — switch to the amux-demo window now!"
sleep 3

# === Scene 1: Create panes (bird's eye) ===
echo "  Creating panes..."
send C-n; pause 1.5
send C-n; pause 1.5
send C-n; pause 2

# === Scene 2: Navigate in bird's eye ===
echo "  Navigating bird's eye..."
send Down; pause 0.6
send Right; pause 0.6
send Up; pause 0.6
send Left; pause 1.5

# === Scene 3: Three-level zoom ===
echo "  Zooming in..."
send C-=; pause 1.5
send C-=; pause 2
send C--; pause 1.5
send C--; pause 2

# === Scene 4: Pane switching ===
echo "  Switching panes..."
send C-1; pause 1
send C-2; pause 1
send C-3; pause 1
send C-4; pause 1
send "echo 'Hello from pane 4!'" Enter; pause 1.5
send C--; pause 2

# === Scene 5: Spaces ===
echo "  Showing spaces..."
send C-p; pause 1.5
send n; pause 0.5
send "backend" Enter; pause 2
send C-n; pause 1.5
send C-p; pause 1.5
send 1; pause 2

# === Scene 6: Spatial stickiness ===
echo "  Showing spatial stickiness..."
send C-2; pause 1
send "exit" Enter; pause 2
send C-n; pause 2
send C--; pause 3

echo ""
echo "Demo complete! Stop your screen recorder."
echo "Cleaning up demo session..."
tmux kill-session -t "$SESSION" 2>/dev/null
