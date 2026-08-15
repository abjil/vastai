#!/usr/bin/env bash
# Loop behavior: --once, MAX_ALERTS, backoff cap, and refreshed facts.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
TEST_DAEMON_PID=""
cleanup() {
  stop_process "$TEST_DAEMON_PID"
  rm -rf "$TMP"
}
trap cleanup EXIT

RUNTIME_TEST_DIR="$TMP/runtime-test"
RUNTIME_TEST_ENV="$TMP/runtime-test.env"
UPTIME_FILE="$TMP/uptime"
mkdir -p "$RUNTIME_TEST_DIR"
write_lifecycle_env "$RUNTIME_TEST_ENV" "$RUNTIME_TEST_DIR"
printf '10.0 0.0\n' > "$UPTIME_FILE"

DATA_DIR="$RUNTIME_TEST_DIR" \
ACK_FILE="$RUNTIME_TEST_DIR/ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
WAKEUP_LOG="$RUNTIME_TEST_DIR/wakeup.log" \
WAKEUP_ERROR_LOG="$RUNTIME_TEST_DIR/wakeup-error.log" \
WAKEUP_PID="$RUNTIME_TEST_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$RUNTIME_TEST_DIR/runtime" \
STARTED_AT_FILE="$RUNTIME_TEST_DIR/started_at" \
WAKEUP_UPTIME_FILE="$UPTIME_FILE" \
  "$BIN_DIR/onstart.sh"

wait_for_pattern "$RUNTIME_TEST_DIR/runtime/alert-email.txt" "Host uptime: 0h 00m 10s" \
  || fail "first alert did not use initial uptime"
printf '20.0 0.0\n' > "$UPTIME_FILE"
wait_for_pattern "$RUNTIME_TEST_DIR/runtime/alert-email.txt" "Host uptime: 0h 00m 20s" \
  || fail "second alert did not refresh uptime"
daemon_pid=$(read_daemon_pid "$RUNTIME_TEST_DIR/wakeup.pid")
TEST_DAEMON_PID="$daemon_pid"
DATA_DIR="$RUNTIME_TEST_DIR" \
ACK_FILE="$RUNTIME_TEST_DIR/ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$BIN_DIR/ack.sh" >/dev/null
for ((i = 0; i < 100; i++)); do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$daemon_pid" 2>/dev/null; then
  stop_process "$daemon_pid"
  fail "dry-run daemon did not exit after ACK"
fi
TEST_DAEMON_PID=""
[[ "$(grep -c 'wakeup started pid=' "$RUNTIME_TEST_DIR/wakeup.log")" -eq 1 ]] \
  || fail "wakeup startup log was duplicated"
[[ "$(grep -c 'channels:' "$RUNTIME_TEST_DIR/wakeup.log")" -eq 1 ]] \
  || fail "channel log was duplicated"
wait_for_pattern "$RUNTIME_TEST_DIR/wakeup-error.log" "[stdout]" \
  || fail "daemon stdout was not mirrored"
pass "first alert, refreshed facts, and one-record logging"

MAX_DIR="$TMP/max-alerts"
MAX_ENV="$TMP/max-alerts.env"
mkdir -p "$MAX_DIR"
write_lifecycle_env "$MAX_ENV" "$MAX_DIR"
cat >> "$MAX_ENV" <<EOF
MAX_ALERTS=1
INTERVAL_SEC=1
INTERVAL_MAX_SEC=1
EOF
DATA_DIR="$MAX_DIR" \
WAKEUP_ENV="$MAX_ENV" \
WAKEUP_LOG="$MAX_DIR/wakeup.log" \
WAKEUP_PID="$MAX_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$MAX_DIR/runtime" \
WAKEUP_SESSION_ID="sess-max" \
  "$BIN_DIR/onstart.sh"
wait_for_pattern "$MAX_DIR/wakeup.log" "MAX_ALERTS=1 reached" \
  || fail "MAX_ALERTS did not stop further sends"
max_pid=$(read_daemon_pid "$MAX_DIR/wakeup.pid")
TEST_DAEMON_PID="$max_pid"
[[ "$(grep -c 'sending alert #' "$MAX_DIR/wakeup.log")" -eq 1 ]] \
  || fail "MAX_ALERTS sent more than one alert"
stop_process "$max_pid"
TEST_DAEMON_PID=""
pass "MAX_ALERTS stops further sends"

BACK_DIR="$TMP/backoff"
BACK_ENV="$TMP/backoff.env"
mkdir -p "$BACK_DIR"
write_lifecycle_env "$BACK_ENV" "$BACK_DIR"
cat >> "$BACK_ENV" <<EOF
MAX_ALERTS=0
INTERVAL_SEC=1
INTERVAL_MAX_SEC=2
EOF
DATA_DIR="$BACK_DIR" \
WAKEUP_ENV="$BACK_ENV" \
WAKEUP_LOG="$BACK_DIR/wakeup.log" \
WAKEUP_PID="$BACK_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$BACK_DIR/runtime" \
WAKEUP_SESSION_ID="sess-back" \
  "$BIN_DIR/onstart.sh"
wait_for_pattern "$BACK_DIR/wakeup.log" "sending alert #3" 80 \
  || fail "backoff test did not reach a third alert"
back_pid=$(read_daemon_pid "$BACK_DIR/wakeup.pid")
TEST_DAEMON_PID="$back_pid"
grep -q 'sending alert #1 (next interval 1s)' "$BACK_DIR/wakeup.log" \
  || fail "first interval was not INTERVAL_SEC"
grep -q 'sending alert #2 (next interval 2s)' "$BACK_DIR/wakeup.log" \
  || fail "second interval did not double"
grep -q 'sending alert #3 (next interval 2s)' "$BACK_DIR/wakeup.log" \
  || fail "backoff was not capped at INTERVAL_MAX_SEC"
stop_process "$back_pid"
TEST_DAEMON_PID=""
pass "backoff doubles and caps at INTERVAL_MAX_SEC"
