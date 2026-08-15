#!/usr/bin/env bash
#
# ack.sh — record the current container session so wakeup.sh stops nagging.

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
  eval_shell_exports "$CONFIG_OUTPUT"
else
  DATA_DIR="$BOOTSTRAP_DATA_DIR"
  ACK_FILE="${ACK_FILE:-$DATA_DIR/ACK}"
  SESSION_ID_FILE="${SESSION_ID_FILE:-$DATA_DIR/session.id}"
fi

SESSION_CLI_ARGS=()
if [[ -n "${WAKEUP_SESSION_ID:-}" ]]; then
  SESSION_CLI_ARGS+=(--session "$WAKEUP_SESSION_ID")
fi
if [[ -n "${WAKEUP_SESSION_PROC:-}" ]]; then
  SESSION_CLI_ARGS+=(--proc-root "$WAKEUP_SESSION_PROC")
fi
if [[ -n "${WAKEUP_SESSION_FALLBACK_DIR:-}" ]]; then
  SESSION_CLI_ARGS+=(--fallback-dir "$WAKEUP_SESSION_FALLBACK_DIR")
fi

mkdir -p "$(dirname "$ACK_FILE")" "$(dirname "$SESSION_ID_FILE")"
TOKEN=$(
  "$PYTHON" "$SCRIPT_DIR/session_id.py" ack-write "$ACK_FILE" "$SESSION_ID_FILE" \
    "${SESSION_CLI_ARGS[@]}"
) || exit 1
echo "ACK created: $ACK_FILE"
echo "session: $TOKEN"
echo "wakeup.sh will stop within ACK_POLL_SEC (default 5s)."
