#!/usr/bin/env bash
#
# ack.sh — create the ACK flag so wakeup.sh stops nagging this boot.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
BOOTSTRAP_DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ENV_FILE="${WAKEUP_ENV:-$BOOTSTRAP_DATA_DIR/wakeup.env}"

if [[ -f "$ENV_FILE" ]]; then
  CONFIG_OUTPUT=$(
    "$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" "$ENV_FILE" --root "$ROOT_DIR"
  ) || exit $?
  eval "$CONFIG_OUTPUT"
else
  DATA_DIR="$BOOTSTRAP_DATA_DIR"
  ACK_FILE="${ACK_FILE:-$DATA_DIR/ACK}"
fi

mkdir -p "$(dirname "$ACK_FILE")"
touch "$ACK_FILE"
echo "ACK created: $ACK_FILE"
echo "wakeup.sh will stop within ACK_POLL_SEC (default 5s)."
