#!/bin/bash
# Simulate streaming test output in pane 2 during recording.
# Started by demo-setup.sh, waits for a signal file before streaming.

ESC=$'\033'
G="${ESC}[32m"  # green
R="${ESC}[31m"  # red
W="${ESC}[1;37m" # white bold
D="${ESC}[90m"  # dim
RST="${ESC}[0m"

# Wait for recording to start (driver creates this file)
while [ ! -f /tmp/amux-demo-go ]; do sleep 0.2; done

clear

echo "${W}Running test suite...${RST}"
echo ""
sleep 0.8

echo "  ${G}✓${RST} auth/login validates credentials ${D}(12ms)${RST}"
sleep 0.6

echo "  ${G}✓${RST} auth/login rejects expired tokens ${D}(3ms)${RST}"
sleep 0.5

echo "  ${G}✓${RST} auth/refresh rotates token pair ${D}(8ms)${RST}"
sleep 0.7

echo "  ${G}✓${RST} auth/middleware blocks unsigned requests ${D}(2ms)${RST}"
sleep 0.5

echo "  ${G}✓${RST} auth/middleware passes valid bearer token ${D}(4ms)${RST}"
sleep 0.6

echo "  ${G}✓${RST} auth/session creates new session ${D}(15ms)${RST}"
sleep 0.8

echo "  ${G}✓${RST} auth/session enforces concurrent limit ${D}(22ms)${RST}"
sleep 0.5

echo "  ${R}✗${RST} auth/session cleanup expired sessions ${D}(145ms)${RST}"
sleep 0.3
echo "    ${R}Expected: 0 expired sessions remaining${RST}"
echo "    ${R}Received: 2 sessions still in table${RST}"
sleep 0.7

echo "  ${G}✓${RST} auth/revoke invalidates token family ${D}(11ms)${RST}"
sleep 0.6

echo "  ${G}✓${RST} auth/revoke blocks reuse of rotated token ${D}(6ms)${RST}"
sleep 0.5

echo "  ${G}✓${RST} db/migration creates sessions table ${D}(34ms)${RST}"
sleep 0.6

echo "  ${G}✓${RST} db/migration backfills existing tokens ${D}(89ms)${RST}"
sleep 0.8

echo ""
echo "${W}Results: 11/12 passed, 1 failed${RST}"
echo "${R}FAIL${RST} auth/session cleanup expired sessions"
sleep 5

# Clean up signal file
rm -f /tmp/amux-demo-go
