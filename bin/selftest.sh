#!/usr/bin/env bash
#
# selftest.sh — no-network checks for CI and local sanity.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
export PYTHONPATH="$SCRIPT_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

command -v bash >/dev/null || fail "bash is required"
PYTHON=$(resolve_python) || fail "python3 is required"
pass "python: $PYTHON"

for sh in "$SCRIPT_DIR"/*.sh; do
  bash -n "$sh" || fail "bash -n $sh"
done
pass "bash -n all scripts"

# Clean checkouts may not retain executable modes when authored on Windows.
chmod +x "$SCRIPT_DIR"/*.sh || fail "chmod +x bin scripts"
pass "shell scripts executable"

"$PYTHON" -m py_compile \
  "$SCRIPT_DIR/envutil.py" \
  "$SCRIPT_DIR/render_template.py" \
  "$SCRIPT_DIR/dump_env_shell.py" \
  || fail "py_compile"
pass "python3 -m py_compile"

"$PYTHON" - "$SCRIPT_DIR" "$ROOT_DIR/templates/wakeup.env.example" <<'PY' || fail "env parse"
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from envutil import parse_env
env = parse_env(Path(sys.argv[2]))
for key in ("SMTP_HOST", "SMTP_FROM", "SMTP_TO", "INTERVAL_SEC", "DATA_DIR"):
    assert key in env, key
assert env["SMTP_HOST"] == "smtp.gmail.com"
print("parsed", len(env), "keys")
PY
pass "parse wakeup.env.example"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$PYTHON" "$SCRIPT_DIR/render_template.py" \
  --env "$ROOT_DIR/templates/wakeup.env.example" \
  "$ROOT_DIR/templates/alert-email.txt" \
  "$TMP/out.txt" \
  HOSTNAME=testhost \
  VAST_LABEL=C.test \
  PUBLIC_IP=1.2.3.4 \
  STARTED_AT='2026-01-01 00:00:00 UTC' \
  NOW='2026-01-01 00:01:00 UTC' \
  ALERT_NUM=1 \
  UPTIME='1h 00m 00s' \
  ACK_FILE=/tmp/ACK \
  ACK_HINT='touch /tmp/ACK' \
  ELAPSED='0h 01m 00s' \
  KIND=alert

grep -q 'testhost' "$TMP/out.txt" || fail "hostname not rendered"
grep -q 'Subject:' "$TMP/out.txt" || fail "email subject missing"
grep -q '1.2.3.4' "$TMP/out.txt" || fail "public IP not rendered"
pass "render alert-email.txt"

# dry-run once with the example env (no network sends)
export DATA_DIR="$TMP"
export WAKEUP_ENV="$ROOT_DIR/templates/wakeup.env.example"
export WAKEUP_LOG="$TMP/wakeup.log"
export WAKEUP_PID="$TMP/wakeup.pid"
export WAKEUP_RUNTIME="$TMP/runtime"
# Example env has placeholder Telegram/SMTP; --dry-run must not call APIs.
"$SCRIPT_DIR/wakeup.sh" --dry-run --once --keep-ack
[[ -f "$TMP/runtime/alert-email.txt" ]] || fail "dry-run did not write alert-email.txt"
[[ -f "$TMP/wakeup.log" ]] || fail "dry-run did not write log"
pass "wakeup.sh --dry-run --once"

echo
echo "selftest passed"
