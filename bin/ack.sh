#!/usr/bin/env bash
#
# ack.sh — create the ACK flag so wakeup.sh stops nagging this boot.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ENV_FILE="${WAKEUP_ENV:-$DATA_DIR/wakeup.env}"

if [[ -f "$ENV_FILE" ]]; then
  eval "$("$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" "$ENV_FILE")"
  DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
fi

ACK_FILE="${ACK_FILE:-$DATA_DIR/ACK}"
mkdir -p "$(dirname "$ACK_FILE")"
touch "$ACK_FILE"
echo "ACK created: $ACK_FILE"
echo "wakeup.sh will stop within ACK_POLL_SEC (default 5s)."
