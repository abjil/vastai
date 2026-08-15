#!/usr/bin/env bash
# SSH auto-ack install, quoting, and uninstall.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

RUNTIME_TEST_ENV="$TMP/runtime-test.env"
write_lifecycle_env "$RUNTIME_TEST_ENV" "$TMP/runtime-data"
OVERRIDE_ACK="$TMP/override/ACK"
EXPECTED_OVERRIDE_ACK=$(cygpath -m "$OVERRIDE_ACK" 2>/dev/null || printf '%s' "$OVERRIDE_ACK")
DATA_DIR="$TMP/wrong-data" \
ACK_FILE="$OVERRIDE_ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$BIN_DIR/ack.sh"
[[ -f "$OVERRIDE_ACK" ]] || fail "ack.sh ignored process ACK_FILE override"

TEST_BASHRC="$TMP/bashrc"
BASHRC="$TEST_BASHRC" \
DATA_DIR="$TMP/wrong-data" \
ACK_FILE="$OVERRIDE_ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$BIN_DIR/install-login-ack.sh" >"$TMP/login-install.out"
grep -q "ack.sh" "$TEST_BASHRC" || fail "login ack snippet does not call ack.sh"
if ! grep -qF "$EXPECTED_OVERRIDE_ACK" "$TEST_BASHRC" &&
   ! grep -qF "$OVERRIDE_ACK" "$TEST_BASHRC"; then
  fail "login ack ignored process ACK_FILE override"
fi
grep -q "SSH_CONNECTION" "$TMP/login-install.out" \
  || fail "install-login-ack did not print the SSH trigger"
grep -q "stops alerts" "$TMP/login-install.out" \
  || fail "install-login-ack did not print the auto-ack risk"
grep -q -- "--uninstall" "$TMP/login-install.out" \
  || fail "install-login-ack did not print the uninstall command"

DATA_DIR="$TMP/wrong-data" \
ACK_FILE="$OVERRIDE_ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$BIN_DIR/ack.sh" >/dev/null
[[ -s "$OVERRIDE_ACK" ]] || fail "ack.sh did not write session token"
[[ -s "$TMP/wrong-data/session.id" ]] || fail "ack.sh ignored DATA_DIR for session.id"
override_token=$(tr -d '[:space:]' < "$TMP/wrong-data/session.id")
grep -qx "$override_token" "$OVERRIDE_ACK" \
  || fail "ACK token does not match session.id"
pass "path overrides are consistent"

UNINSTALL_BASHRC="$TMP/bashrc-uninstall"
printf 'keep-me\n' > "$UNINSTALL_BASHRC"
BASHRC="$UNINSTALL_BASHRC" \
DATA_DIR="$TMP/wrong-data" \
ACK_FILE="$OVERRIDE_ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$BIN_DIR/install-login-ack.sh" >/dev/null
grep -q "keep-me" "$UNINSTALL_BASHRC" || fail "login-ack install clobbered bashrc"
BASHRC="$UNINSTALL_BASHRC" \
  "$BIN_DIR/install-login-ack.sh" --uninstall >"$TMP/login-uninstall.out"
grep -q "Removed login auto-ack" "$TMP/login-uninstall.out" \
  || fail "uninstall did not report removal"
if grep -q "vastai-wakeup login ack" "$UNINSTALL_BASHRC"; then
  fail "uninstall left the login-ack snippet"
fi
grep -q "keep-me" "$UNINSTALL_BASHRC" || fail "uninstall removed unrelated bashrc content"
pass "SSH auto-ack is explicit, quoted, and reversible"
