#!/usr/bin/env bash
set -euo pipefail

# amux installer — clone repo and run setup
# Usage: curl -sSL https://raw.githubusercontent.com/byoungs/amux/main/scripts/install.sh | bash

AMUX_DIR="${AMUX_DIR:-$HOME/src/amux}"

echo "Installing amux to $AMUX_DIR"
echo ""

# Check prerequisites
if ! command -v git &>/dev/null; then
    echo "✗ git is required. Install it first."
    exit 1
fi

if ! command -v cargo &>/dev/null; then
    echo "✗ Rust is required. Install from https://rustup.rs:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

echo "  (tmux will be checked during setup)"
echo ""

# Clone or update
if [ -d "$AMUX_DIR/.git" ]; then
    echo "Updating existing repo at $AMUX_DIR"
    git -C "$AMUX_DIR" pull --ff-only
else
    mkdir -p "$(dirname "$AMUX_DIR")"
    git clone --depth 1 https://github.com/byoungs/amux.git "$AMUX_DIR"
fi

# Run setup
make -C "$AMUX_DIR" setup

echo ""
echo "Done! Run 'amux' to start."
echo ""
echo "Next steps:"
echo "  amux              Launch amux"
echo "  Ctrl-n            Create a new pane"
echo "  Ctrl-+ / Ctrl--   Zoom in / out"
echo "  Ctrl-P            Space picker"
