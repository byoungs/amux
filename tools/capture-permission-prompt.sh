#!/usr/bin/env bash
# capture-permission-prompt.sh — drive an isolated `claude` session inside a
# dedicated tmux server to capture real Claude Code permission prompts (and
# to verify how send-keys answers them). Used to produce the fixtures in
# app/Tests/Fixtures/ that the permission-prompt parser is tested against.
#
# Isolation: uses `tmux -L amuxpeek`, a SEPARATE tmux server from amux (which
# runs on the default socket). Sessions here are detached and driven only via
# send-keys/capture-pane — never attached — so this never steals keystrokes
# from a running amux.
#
# Forcing a prompt: Claude auto-approves allowlisted tools. To force a prompt,
# either run a non-allowlisted command, or put a `permissions.ask` rule in
# PEEK_DIR/.claude/settings.json, e.g.:
#   { "permissions": { "defaultMode": "default", "ask": ["Bash(echo:*)"] } }
#
# Usage:
#   capture-permission-prompt.sh start            start claude detached in PEEK_DIR
#   capture-permission-prompt.sh send "<text>"    type literal text into the pane
#   capture-permission-prompt.sh enter            press Enter
#   capture-permission-prompt.sh key <tmux-key>   send a tmux key token (e.g. 1, Escape)
#   capture-permission-prompt.sh cap              print the rendered pane
#   capture-permission-prompt.sh capto <file>     write the rendered pane to a file
#   capture-permission-prompt.sh waitfor <regex>  poll until the pane matches (or time out)
#   capture-permission-prompt.sh stop             kill the isolated tmux server
set -euo pipefail

SOCK="amuxpeek"
SESS="cap"
DIR="${PEEK_DIR:-$HOME/src/scratch-claude/proj}"

TM() { tmux -L "$SOCK" "$@"; }

case "${1:-}" in
  start)
    mkdir -p "$DIR"
    TM kill-session -t "$SESS" 2>/dev/null || true
    TM new-session -d -s "$SESS" -x 120 -y 45 -c "$DIR" "claude"
    echo "started $SESS on socket $SOCK in $DIR"
    ;;
  send)
    shift
    TM send-keys -t "$SESS" -l "$*"
    ;;
  enter)
    TM send-keys -t "$SESS" Enter
    ;;
  key)
    shift
    TM send-keys -t "$SESS" "$@"
    ;;
  cap)
    TM capture-pane -p -J -t "$SESS" -S -45
    ;;
  capto)
    shift
    TM capture-pane -p -J -t "$SESS" -S -45 > "$1"
    echo "captured to $1"
    ;;
  waitfor)
    shift
    pat="$*"
    for i in $(seq 1 60); do
      if TM capture-pane -p -J -t "$SESS" | grep -qiE "$pat"; then
        echo "matched: $pat"
        exit 0
      fi
      sleep 0.5
    done
    echo "timeout waiting for: $pat" >&2
    exit 1
    ;;
  stop)
    TM kill-server 2>/dev/null || true
    echo "stopped server $SOCK"
    ;;
  *)
    echo "usage: $0 start|send|enter|key|cap|capto|waitfor|stop" >&2
    exit 1
    ;;
esac
