#!/bin/bash
# Paste this into the Vast.ai instance "onstart" / startup script field.
# Edit WAKEUP_REPO_URL after the GitHub spinoff. Until then, copy this
# project to /workspace/vastai-wakeup and leave the clone block commented.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/workspace/vastai-wakeup}"
# After spinoff:
# WAKEUP_REPO_URL="${WAKEUP_REPO_URL:-https://github.com/YOUR_USER/vastai-wakeup.git}"

mkdir -p /workspace

# --- GitHub clone (enable after spinoff) ---
# if [[ ! -d "$INSTALL_DIR/.git" ]]; then
#   git clone "$WAKEUP_REPO_URL" "$INSTALL_DIR"
# else
#   git -C "$INSTALL_DIR" pull --ff-only || true
# fi

if [[ ! -x "$INSTALL_DIR/bin/onstart.sh" && ! -f "$INSTALL_DIR/bin/onstart.sh" ]]; then
  echo "vastai-wakeup not found at $INSTALL_DIR — copy the project there or enable git clone."
  exit 1
fi

export DATA_DIR="$INSTALL_DIR"
export WAKEUP_ENV="$INSTALL_DIR/wakeup.env"
exec "$INSTALL_DIR/bin/onstart.sh"
