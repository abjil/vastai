#!/bin/bash
# Paste this into the Vast.ai instance "onstart" / startup script field.
#
# Set WAKEUP_REVISION to a reviewed tag or commit before enabling this hook.
# Startup fetches that revision and detaches. It does not pull a moving branch,
# and it will not start the notifier if the revision cannot be obtained.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/workspace/vastai-wakeup}"
WAKEUP_REVISION="${WAKEUP_REVISION:-}"

if [[ -z "$WAKEUP_REVISION" ]]; then
  echo "ERROR: WAKEUP_REVISION is required (reviewed tag or commit)."
  echo "Example: export WAKEUP_REVISION=v1.0.0"
  echo "Refusing to start from an unpinned moving branch."
  exit 1
fi

mkdir -p "$(dirname "$INSTALL_DIR")"

if [[ ! -f "$INSTALL_DIR/bin/onstart.sh" || ! -f "$INSTALL_DIR/bin/pin_revision.sh" ]]; then
  echo "vastai-wakeup not found at $INSTALL_DIR"
  echo "Clone a reviewed revision to $INSTALL_DIR before enabling this hook."
  exit 1
fi

# Invoke through Bash because a Windows-authored checkout may lack executable
# file modes. pin_revision.sh fails closed if the revision cannot be obtained.
bash "$INSTALL_DIR/bin/pin_revision.sh" --repo "$INSTALL_DIR" "$WAKEUP_REVISION"
export DATA_DIR="$INSTALL_DIR"
export WAKEUP_ENV="$INSTALL_DIR/wakeup.env"
export WAKEUP_REVISION
exec bash "$INSTALL_DIR/bin/onstart.sh"
