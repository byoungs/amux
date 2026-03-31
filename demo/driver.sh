#!/bin/bash
# Drive the amux demo beats via CLI commands.
# Run in background while VHS records.
#
# VHS hides first ~2s (attach). All times below are DRIVER time.
# Visible time = driver time - 2.
# Rhythm: narr shows → pause → key badge → ACTION → result sits

export AMUX_SESSION="amux-demo"
touch /tmp/amux-demo-go

# --- Beat 1: Grid with plan too small, zoom in ---
# visible 0-4s: narr "plan needs my attention"
# visible 4.5-6s: key badge ⌘ =
# visible 6s: ACTION zoom in
sleep 8     # driver t=8 = visible t=6
amux zoom-in

# --- Beat 2: Reading the plan, notice badge ---
# visible 6-9s: plan sits (no overlay)
# visible 9-11s: narr "done, notice the badge"
# visible 11.5-13s: key badge ⌘ -
# visible 13s: ACTION zoom out
sleep 7     # driver t=15 = visible t=13
amux zoom-out

# --- Beat 3: Permission prompt, quick approve ---
# visible 13-15.5s: narr "permission needed, just approve"
# visible 16-17.5s: key badge ⌘ 3
# visible 17.5s: ACTION jump to pane 3
sleep 4.5   # driver t=19.5 = visible t=17.5
amux zoom 2
sleep 0.5

# Simulate approval: clear the alert and show "approved" in the pane
tmux set-option -p -t "${AMUX_SESSION}:0.2" @amux-alert 0
tmux set-option -t "${AMUX_SESSION}" @amux-alert-count 0

# --- Beat 4: Review code ---
# visible 18-20s: narr "now let me review this code"
# visible 20.5-22s: key badge ⌘ 2
# visible 22s: ACTION jump to code review + zoom in
sleep 4     # driver t=24 = visible t=22
amux zoom 1
sleep 0.3
amux zoom-in

# --- Beat 5: Side-by-side ---
# visible 22-25s: narr "I see an issue, side-by-side"
# visible 25.5-27s: key badge ⌘ L
# visible 27s: ACTION start split
sleep 5     # driver t=29 = visible t=27
amux split-start
sleep 1.5

# visible 28.5s: key badge ⌘ 4, pick pane
amux split-pick 3

# --- Beat 6: Split view sits ---
# visible 29-32s: split view (no overlay)
sleep 3.5   # driver t=34 = visible t=32

# visible 32s: ACTION exit split
amux split-exit

# --- End card ---
# visible 32-38s: tagline
sleep 6
