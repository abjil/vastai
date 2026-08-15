#!/usr/bin/env bash
# Configuration startup, CLI flags, and allowlist behavior.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export DATA_DIR="$TMP"
export WAKEUP_ENV="$ROOT_DIR/templates/wakeup.env.example"
export WAKEUP_LOG="$TMP/wakeup.log"
export WAKEUP_PID="$TMP/wakeup.pid"
export WAKEUP_RUNTIME="$TMP/runtime"
"$BIN_DIR/wakeup.sh" --dry-run --once --keep-ack
[[ -f "$TMP/runtime/alert-email.txt" ]] || fail "dry-run did not write alert-email.txt"
[[ -f "$TMP/wakeup.log" ]] || fail "dry-run did not write log"
pass "wakeup.sh --dry-run --once"

CLI_ENV="$TMP/cli-flags.env"
cat > "$CLI_ENV" <<EOF
DATA_DIR=$TMP
WAKEUP_DRY_RUN=0
INTERVAL_SEC=60
INTERVAL_MAX_SEC=900
ACK_POLL_SEC=5
MAX_ALERTS=0
EOF
DATA_DIR="$TMP" \
WAKEUP_ENV="$CLI_ENV" \
WAKEUP_LOG="$TMP/cli-flags.log" \
WAKEUP_PID="$TMP/cli-flags.pid" \
WAKEUP_RUNTIME="$TMP/cli-flags-runtime" \
  "$BIN_DIR/wakeup.sh" --dry-run --once --keep-ack
grep -q 'dry_run=1' "$TMP/cli-flags.log" || fail "CLI --dry-run lost to env file"
grep -q -- '--once: done' "$TMP/cli-flags.log" || fail "CLI --once lost to env file"
pass "CLI flags survive WAKEUP_DRY_RUN from the env file"

if DATA_DIR="$TMP" \
   WAKEUP_ENV="$CLI_ENV" \
   WAKEUP_LOG="$TMP/combo.log" \
   WAKEUP_PID="$TMP/combo.pid" \
   WAKEUP_RUNTIME="$TMP/combo-runtime" \
     "$BIN_DIR/wakeup.sh" --dry-run --test-channels >"$TMP/combo.out" 2>&1; then
  fail "--test-channels accepted --dry-run"
fi
grep -q 'cannot be combined' "$TMP/combo.out" \
  || fail "--test-channels/--dry-run rejection message missing"
pass "--test-channels rejects --dry-run"

INVALID_DATA_DIR="$TMP/invalid-start"
INVALID_ENV="$TMP/invalid-start.env"
mkdir -p "$INVALID_DATA_DIR"
cat > "$INVALID_ENV" <<EOF
DATA_DIR=$INVALID_DATA_DIR
INTERVAL_SEC=invalid
TELEGRAM_BOT_TOKEN=token-only
EOF
secure_env "$INVALID_ENV"
if DATA_DIR="$INVALID_DATA_DIR" \
   WAKEUP_ENV="$INVALID_ENV" \
   WAKEUP_LOG="$INVALID_DATA_DIR/wakeup.log" \
   WAKEUP_PID="$INVALID_DATA_DIR/wakeup.pid" \
     "$BIN_DIR/onstart.sh" >"$TMP/invalid-start.out" 2>&1; then
  fail "onstart accepted invalid configuration"
fi
grep -qF "INTERVAL_SEC" "$TMP/invalid-start.out" \
  || fail "invalid numeric setting was not reported"
grep -qF "TELEGRAM_CHAT_ID" "$TMP/invalid-start.out" \
  || fail "incomplete channel was not reported"
[[ ! -e "$INVALID_DATA_DIR/wakeup.pid" ]] \
  || fail "invalid configuration changed daemon PID state"
pass "invalid startup is rejected before lifecycle changes"

ALLOW_ENV="$TMP/allowlist.env"
cat > "$ALLOW_ENV" <<EOF
WAKEUP_DRY_RUN=1
FOO_ARBITRARY=hacked
EOF
saved_path=$PATH
saved_home=$HOME
allow_out=$("$PYTHON" "$BIN_DIR/dump_env_shell.py" "$ALLOW_ENV" --root "$ROOT_DIR" --dry-run 2>"$TMP/allow.err") \
  || fail "unknown key rejected the allowlist"
if grep -q '^FOO_ARBITRARY=' <<<"$allow_out"; then
  fail "unknown key appeared in shell exports"
fi
(
  eval_shell_exports "$allow_out"
  [[ -z "${FOO_ARBITRARY:-}" ]] || exit 1
  [[ "$PATH" == "$saved_path" ]] || exit 1
  [[ "$HOME" == "$saved_home" ]] || exit 1
) || fail "allowlisted exports changed PATH, HOME, or an unknown key"
grep -q "FOO_ARBITRARY" "$TMP/allow.err" || fail "unknown key was not warned"

RESERVED_ENV="$TMP/reserved.env"
cat > "$RESERVED_ENV" <<EOF
PATH=/tmp/evil-path
HOME=/tmp/evil-home
PYTHONPATH=/tmp/evil-python
WAKEUP_DRY_RUN=1
EOF
if "$PYTHON" "$BIN_DIR/dump_env_shell.py" "$RESERVED_ENV" --root "$ROOT_DIR" --dry-run \
     >"$TMP/reserved.out" 2>"$TMP/reserved.err"; then
  fail "reserved names were exported"
fi
grep -q "PATH" "$TMP/reserved.err" || fail "reserved PATH was not rejected"
if grep -q '^PATH=' "$TMP/reserved.out"; then
  fail "reserved PATH appeared in shell exports"
fi
pass "allowlist rejects reserved names and ignores unknown keys"
