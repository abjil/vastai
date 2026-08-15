#!/usr/bin/env bash
# ACK/session match, mismatch, polling, and one-shot final message.
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

SESSION_MATCH="$TMP/session-match"
SESSION_MATCH_ENV="$TMP/session-match.env"
mkdir -p "$SESSION_MATCH"
write_lifecycle_env "$SESSION_MATCH_ENV" "$SESSION_MATCH"
printf '%s\n' "sess-same" > "$SESSION_MATCH/session.id"
printf '%s\n' "sess-same" > "$SESSION_MATCH/ACK"
DATA_DIR="$SESSION_MATCH" \
WAKEUP_ENV="$SESSION_MATCH_ENV" \
WAKEUP_LOG="$SESSION_MATCH/wakeup.log" \
WAKEUP_PID="$SESSION_MATCH/wakeup.pid" \
WAKEUP_RUNTIME="$SESSION_MATCH/runtime" \
WAKEUP_SESSION_ID="sess-same" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
grep -q "ACK matches session sess-same" "$SESSION_MATCH/wakeup.log" \
  || fail "matching ACK was not accepted"
[[ -f "$SESSION_MATCH/runtime/acked-email.txt" ]] \
  || fail "matching ACK did not render the final message"
grep -qx "sess-same" "$SESSION_MATCH/ACK" || fail "matching ACK was rewritten or deleted"
pass "ACK survives notifier restart in the same session"

ALREADY_DIR="$TMP/already-acked"
ALREADY_ENV="$TMP/already-acked.env"
mkdir -p "$ALREADY_DIR"
write_lifecycle_env "$ALREADY_ENV" "$ALREADY_DIR"
printf '%s\n' "sess-same" > "$ALREADY_DIR/session.id"
printf '%s\n' "sess-same" > "$ALREADY_DIR/ACK"
printf '%s\n' "sess-same" > "$ALREADY_DIR/acked.session"
DATA_DIR="$ALREADY_DIR" \
WAKEUP_ENV="$ALREADY_ENV" \
WAKEUP_LOG="$ALREADY_DIR/wakeup.log" \
WAKEUP_PID="$ALREADY_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$ALREADY_DIR/runtime" \
WAKEUP_SESSION_ID="sess-same" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
grep -q "already acknowledged" "$ALREADY_DIR/wakeup.log" \
  || fail "final acknowledgment was not limited to once per session"
[[ ! -e "$ALREADY_DIR/runtime/acked-email.txt" ]] \
  || fail "final acknowledgment was sent a second time"
pass "final acknowledgment is sent at most once per session"

STALE_ACK_DIR="$TMP/stale-ack"
STALE_ACK_ENV="$TMP/stale-ack.env"
mkdir -p "$STALE_ACK_DIR"
write_lifecycle_env "$STALE_ACK_ENV" "$STALE_ACK_DIR"
printf '%s\n' "sess-old" > "$STALE_ACK_DIR/ACK"
DATA_DIR="$STALE_ACK_DIR" \
WAKEUP_ENV="$STALE_ACK_ENV" \
WAKEUP_LOG="$STALE_ACK_DIR/wakeup.log" \
WAKEUP_PID="$STALE_ACK_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$STALE_ACK_DIR/runtime" \
WAKEUP_SESSION_ID="sess-new" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
grep -q "ignoring ACK that does not match session sess-new" "$STALE_ACK_DIR/wakeup.log" \
  || fail "cross-session ACK was not rejected"
[[ -f "$STALE_ACK_DIR/runtime/alert-email.txt" ]] \
  || fail "new session did not alert after a stale ACK"
grep -qx "sess-old" "$STALE_ACK_DIR/ACK" || fail "stale ACK evidence was deleted"
pass "ACK from an earlier session does not silence a later session"

EMPTY_ACK_DIR="$TMP/empty-ack"
EMPTY_ACK_ENV="$TMP/empty-ack.env"
mkdir -p "$EMPTY_ACK_DIR"
write_lifecycle_env "$EMPTY_ACK_ENV" "$EMPTY_ACK_DIR"
: > "$EMPTY_ACK_DIR/ACK"
DATA_DIR="$EMPTY_ACK_DIR" \
WAKEUP_ENV="$EMPTY_ACK_ENV" \
WAKEUP_LOG="$EMPTY_ACK_DIR/wakeup.log" \
WAKEUP_PID="$EMPTY_ACK_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$EMPTY_ACK_DIR/runtime" \
WAKEUP_SESSION_ID="sess-empty" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
[[ -f "$EMPTY_ACK_DIR/runtime/alert-email.txt" ]] \
  || fail "empty legacy ACK was treated as valid"
DATA_DIR="$EMPTY_ACK_DIR" \
WAKEUP_ENV="$EMPTY_ACK_ENV" \
WAKEUP_LOG="$EMPTY_ACK_DIR/wakeup-legacy.log" \
WAKEUP_PID="$EMPTY_ACK_DIR/wakeup-legacy.pid" \
WAKEUP_RUNTIME="$EMPTY_ACK_DIR/runtime-legacy" \
WAKEUP_SESSION_ID="sess-empty" \
  "$BIN_DIR/wakeup.sh" --dry-run --once --keep-ack
grep -q "ACK matches session sess-empty" "$EMPTY_ACK_DIR/wakeup-legacy.log" \
  || fail "--keep-ack did not accept an empty legacy ACK"
pass "empty legacy ACK is stale unless compatibility mode is set"

POLL_DIR="$TMP/ack-poll"
POLL_ENV="$TMP/ack-poll.env"
mkdir -p "$POLL_DIR"
write_lifecycle_env "$POLL_ENV" "$POLL_DIR"
cat >> "$POLL_ENV" <<EOF
INTERVAL_SEC=20
INTERVAL_MAX_SEC=20
ACK_POLL_SEC=1
MAX_ALERTS=1
EOF
DATA_DIR="$POLL_DIR" \
WAKEUP_ENV="$POLL_ENV" \
WAKEUP_LOG="$POLL_DIR/wakeup.log" \
WAKEUP_PID="$POLL_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$POLL_DIR/runtime" \
WAKEUP_SESSION_ID="sess-poll" \
  "$BIN_DIR/onstart.sh"
wait_for_pattern "$POLL_DIR/wakeup.log" "sending alert #1" \
  || fail "ACK poll test did not send the first alert"
poll_pid=$(read_daemon_pid "$POLL_DIR/wakeup.pid")
TEST_DAEMON_PID="$poll_pid"
DATA_DIR="$POLL_DIR" \
WAKEUP_ENV="$POLL_ENV" \
WAKEUP_SESSION_ID="sess-poll" \
  "$BIN_DIR/ack.sh" >/dev/null
for ((i = 0; i < 40; i++)); do
  if ! kill -0 "$poll_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$poll_pid" 2>/dev/null; then
  kill "$poll_pid" 2>/dev/null || true
  fail "ACK was not observed within ACK_POLL_SEC"
fi
TEST_DAEMON_PID=""
grep -q "ACK matches session sess-poll" "$POLL_DIR/wakeup.log" \
  || fail "ACK poll did not send the final message"
pass "ACK polling observes a match without waiting out INTERVAL_SEC"
