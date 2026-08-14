#!/bin/bash
# Paste this into the Vast.ai instance "onstart" / startup script field.
#
# Install and test a reviewed revision of https://github.com/abjil/vastai at
# /workspace/vastai-wakeup before enabling this hook. Startup intentionally
# does not clone or update code from a moving branch.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/workspace/vastai-wakeup}"

mkdir -p /workspace

if [[ ! -f "$INSTALL_DIR/bin/onstart.sh" ]]; then
  echo "vastai-wakeup not found at $INSTALL_DIR"
  echo "Install a reviewed revision before enabling this onstart hook."
  exit 1
fi

export DATA_DIR="$INSTALL_DIR"
export WAKEUP_ENV="$INSTALL_DIR/wakeup.env"
# Invoke through Bash because a Windows-authored checkout may lack executable
# file modes. onstart.sh restores executable bits for the remaining scripts.
exec bash "$INSTALL_DIR/bin/onstart.sh"
