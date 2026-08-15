#!/usr/bin/env bash
# Sequential/concurrent onstart, stale PID, and cleanup ownership.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
TEST_DAEMON_PID=""
cleanup() {
  if [[ -n "$TEST_DAEMON_PID" ]] && kill -0 "$TEST_DAEMON_PID" 2>/dev/null; then
    kill "$TEST_DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

SEQ_DIR="$TMP/sequential"
SEQ_ENV="$TMP/sequential.env"
mkdir -p "$SEQ_DIR"
write_lifecycle_env "$SEQ_ENV" "$SEQ_DIR"
DATA_DIR="$SEQ_DIR" \
WAKEUP_ENV="$SEQ_ENV" \
WAKEUP_LOG="$SEQ_DIR/wakeup.log" \
WAKEUP_PID="$SEQ_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$SEQ_DIR/runtime" \
WAKEUP_SESSION_ID="sess-seq" \
  "$BIN_DIR/onstart.sh"
wait_for_pattern "$SEQ_DIR/wakeup.log" "wakeup started pid=" \
  || fail "sequential onstart did not start a daemon"
seq_pid=$(read_daemon_pid "$SEQ_DIR/wakeup.pid")
TEST_DAEMON_PID="$seq_pid"
DATA_DIR="$SEQ_DIR" \
WAKEUP_ENV="$SEQ_ENV" \
WAKEUP_LOG="$SEQ_DIR/wakeup.log" \
WAKEUP_PID="$SEQ_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$SEQ_DIR/runtime" \
WAKEUP_SESSION_ID="sess-seq" \
  "$BIN_DIR/onstart.sh"
seq_pid_again=$(read_daemon_pid "$SEQ_DIR/wakeup.pid")
[[ "$seq_pid" == "$seq_pid_again" ]] || fail "sequential onstart replaced a healthy daemon"
kill -0 "$seq_pid" 2>/dev/null || fail "sequential onstart left no running daemon"
grep -q "already running" "$SEQ_DIR/wakeup.log" \
  || fail "sequential onstart did not report the existing daemon"
[[ "$(grep -c 'wakeup started pid=' "$SEQ_DIR/wakeup.log")" -eq 1 ]] \
  || fail "sequential onstart started more than one daemon"
pass "sequential onstart leaves exactly one daemon"

CONCUR_DIR="$TMP/concurrent"
CONCUR_ENV="$TMP/concurrent.env"
mkdir -p "$CONCUR_DIR"
write_lifecycle_env "$CONCUR_ENV" "$CONCUR_DIR"
DATA_DIR="$CONCUR_DIR" \
WAKEUP_ENV="$CONCUR_ENV" \
WAKEUP_LOG="$CONCUR_DIR/wakeup.log" \
WAKEUP_PID="$CONCUR_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$CONCUR_DIR/runtime" \
WAKEUP_SESSION_ID="sess-concur" \
  "$BIN_DIR/onstart.sh" &
concur_one=$!
DATA_DIR="$CONCUR_DIR" \
WAKEUP_ENV="$CONCUR_ENV" \
WAKEUP_LOG="$CONCUR_DIR/wakeup.log" \
WAKEUP_PID="$CONCUR_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$CONCUR_DIR/runtime" \
WAKEUP_SESSION_ID="sess-concur" \
  "$BIN_DIR/onstart.sh" &
concur_two=$!
wait "$concur_one" || fail "first concurrent onstart failed"
wait "$concur_two" || fail "second concurrent onstart failed"
wait_for_pattern "$CONCUR_DIR/wakeup.log" "wakeup started pid=" \
  || fail "concurrent onstart did not start a daemon"
concur_pid=$(read_daemon_pid "$CONCUR_DIR/wakeup.pid")
kill -0 "$concur_pid" 2>/dev/null || fail "concurrent onstart left no running daemon"
[[ "$(grep -c 'wakeup started pid=' "$CONCUR_DIR/wakeup.log")" -eq 1 ]] \
  || fail "concurrent onstart started more than one daemon"
grep -q "already running" "$CONCUR_DIR/wakeup.log" \
  || fail "concurrent onstart did not serialize onto one daemon"
if [[ -n "$TEST_DAEMON_PID" ]] && kill -0 "$TEST_DAEMON_PID" 2>/dev/null; then
  kill "$TEST_DAEMON_PID" 2>/dev/null || true
fi
TEST_DAEMON_PID="$concur_pid"
if [[ -n "$seq_pid" ]] && kill -0 "$seq_pid" 2>/dev/null; then
  kill "$seq_pid" 2>/dev/null || true
fi
pass "concurrent onstart leaves exactly one daemon"

STALE_PID_DIR="$TMP/stale-pid"
STALE_PID_ENV="$TMP/stale-pid.env"
mkdir -p "$STALE_PID_DIR"
write_lifecycle_env "$STALE_PID_ENV" "$STALE_PID_DIR"
sleep 120 &
stale_sleep_pid=$!
"$PYTHON" "$BIN_DIR/session_id.py" write "$STALE_PID_DIR/wakeup.pid" \
  "pid=${stale_sleep_pid}
starttime=1
session=sess-stale
script=/not/wakeup.sh"
DATA_DIR="$STALE_PID_DIR" \
WAKEUP_ENV="$STALE_PID_ENV" \
WAKEUP_LOG="$STALE_PID_DIR/wakeup.log" \
WAKEUP_PID="$STALE_PID_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$STALE_PID_DIR/runtime" \
WAKEUP_SESSION_ID="sess-stale" \
  "$BIN_DIR/onstart.sh"
wait_for_pattern "$STALE_PID_DIR/wakeup.log" "wakeup started pid=" \
  || fail "onstart did not start after a stale PID file"
kill -0 "$stale_sleep_pid" 2>/dev/null \
  || fail "a stale PID signaled an unrelated process"
stale_daemon_pid=$(read_daemon_pid "$STALE_PID_DIR/wakeup.pid")
[[ "$stale_daemon_pid" != "$stale_sleep_pid" ]] \
  || fail "onstart reused the unrelated stale PID"
kill "$stale_sleep_pid" 2>/dev/null || true
if [[ -n "$TEST_DAEMON_PID" ]] && kill -0 "$TEST_DAEMON_PID" 2>/dev/null; then
  kill "$TEST_DAEMON_PID" 2>/dev/null || true
fi
TEST_DAEMON_PID="$stale_daemon_pid"
pass "stale PID cannot signal an unrelated process"

OWN_DIR="$TMP/ownership"
OWN_ENV="$TMP/ownership.env"
mkdir -p "$OWN_DIR"
write_lifecycle_env "$OWN_ENV" "$OWN_DIR"
DATA_DIR="$OWN_DIR" \
WAKEUP_ENV="$OWN_ENV" \
WAKEUP_LOG="$OWN_DIR/wakeup.log" \
WAKEUP_PID="$OWN_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$OWN_DIR/runtime" \
WAKEUP_SESSION_ID="sess-own" \
  "$BIN_DIR/onstart.sh"
wait_for_pattern "$OWN_DIR/wakeup.log" "wakeup started pid=" \
  || fail "ownership test daemon did not start"
own_pid=$(read_daemon_pid "$OWN_DIR/wakeup.pid")
"$PYTHON" "$BIN_DIR/session_id.py" write "$OWN_DIR/wakeup.pid" \
  "pid=123456
starttime=99
session=sess-newer
script=/tmp/newer/wakeup.sh"
kill "$own_pid" 2>/dev/null || true
for ((i = 0; i < 50; i++)); do
  if ! kill -0 "$own_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
newer_pid=$(
  "$PYTHON" "$BIN_DIR/session_id.py" read-pid "$OWN_DIR/wakeup.pid" --field pid
)
[[ "$newer_pid" == "123456" ]] \
  || fail "old process cleanup removed a newer process identity"
if [[ -n "$TEST_DAEMON_PID" ]] && kill -0 "$TEST_DAEMON_PID" 2>/dev/null; then
  kill "$TEST_DAEMON_PID" 2>/dev/null || true
fi
TEST_DAEMON_PID=""
pass "PID cleanup is conditional on state ownership"
