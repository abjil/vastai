#!/usr/bin/env bash
# Clean-checkout behavior when Git did not preserve executable modes.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
ONSTART_PID=""
cleanup() {
  if [[ -n "$ONSTART_PID" ]] && kill -0 "$ONSTART_PID" 2>/dev/null; then
    kill "$ONSTART_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP" || true
}
trap cleanup EXIT

COPY="$TMP/checkout"
mkdir -p "$COPY"
cp -R "$BIN_DIR" "$COPY/bin"
cp -R "$ROOT_DIR/templates" "$COPY/templates"
chmod a-x "$COPY/bin"/*.sh 2>/dev/null || true

DATA_DIR="$TMP/data"
mkdir -p "$DATA_DIR"
write_lifecycle_env "$TMP/wakeup.env" "$DATA_DIR"
DATA_DIR="$DATA_DIR" \
WAKEUP_ENV="$TMP/wakeup.env" \
WAKEUP_LOG="$DATA_DIR/wakeup.log" \
WAKEUP_PID="$DATA_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$DATA_DIR/runtime" \
  bash "$COPY/bin/wakeup.sh" --dry-run --once
[[ -f "$DATA_DIR/runtime/alert-email.txt" ]] \
  || fail "bash wakeup.sh failed without executable mode"
pass "wakeup.sh runs through bash without executable Git modes"

DATA_DIR="$DATA_DIR" \
WAKEUP_ENV="$TMP/wakeup.env" \
WAKEUP_LOG="$DATA_DIR/onstart.log" \
WAKEUP_PID="$DATA_DIR/onstart.pid" \
WAKEUP_RUNTIME="$DATA_DIR/onstart-runtime" \
  bash "$COPY/bin/onstart.sh" >/dev/null
if [[ ! -x "$COPY/bin/wakeup.sh" && "$(uname -s)" == "Linux" ]]; then
  fail "onstart did not restore executable bits"
fi
ONSTART_PID=$(read_daemon_pid "$DATA_DIR/onstart.pid" || true)
if [[ -n "$ONSTART_PID" ]]; then
  kill "$ONSTART_PID" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    if ! kill -0 "$ONSTART_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
fi
ONSTART_PID=""
pass "onstart restores executable bits on a clean checkout"
