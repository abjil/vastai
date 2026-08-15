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
  "$SCRIPT_DIR/sanitize_output.py" \
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

"$PYTHON" - "$SCRIPT_DIR" "$ROOT_DIR" <<'PY' || fail "config validation"
import tempfile
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from envutil import ConfigError, load_config, sanitize_detail

root = Path(sys.argv[2])
example = root / "templates" / "wakeup.env.example"
config = load_config(example, root_dir=root, require_channel=True)
assert config["LOG_MAX_BYTES"] == "1048576"
assert config["LOG_BACKUP_COUNT"] == "3"

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = Path(tmp)
    env_file = tmp_path / "wakeup.env"
    env_file.write_text(
        "\n".join(
            [
                f"DATA_DIR={tmp_path / 'file-data'}",
                "INTERVAL_SEC=60",
                "INTERVAL_MAX_SEC=900",
                "ACK_POLL_SEC=5",
                "MAX_ALERTS=0",
                "WAKEUP_DRY_RUN=1",
                "SMTP_USER=file-user",
                "SMTP_PASSWORD=file-secret",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    override_ack = tmp_path / "override-ACK"
    loaded = load_config(
        env_file,
        root_dir=root,
        environ={
            "DATA_DIR": str(tmp_path / "override-data"),
            "ACK_FILE": str(override_ack),
            "INTERVAL_SEC": "7",
            "SMTP_PASSWORD": "process-secret",
        },
        dry_run=True,
    )
    assert loaded["DATA_DIR"] == str(tmp_path / "override-data")
    assert loaded["ACK_FILE"] == str(override_ack)
    assert loaded["INTERVAL_SEC"] == "7"
    assert loaded["SMTP_PASSWORD"] == "file-secret"

    invalid = tmp_path / "invalid.env"
    invalid.write_text(
        "INTERVAL_SEC=zero\nWAKEUP_DRY_RUN=1\n",
        encoding="utf-8",
    )
    try:
        load_config(invalid, root_dir=root, dry_run=True)
    except ConfigError as exc:
        assert "INTERVAL_SEC" in str(exc)
    else:
        raise AssertionError("invalid numeric setting was accepted")

    partial = tmp_path / "partial.env"
    partial.write_text(
        "TELEGRAM_BOT_TOKEN=token-only\n",
        encoding="utf-8",
    )
    try:
        load_config(partial, root_dir=root, require_channel=True)
    except ConfigError as exc:
        assert "TELEGRAM_CHAT_ID" in str(exc)
    else:
        raise AssertionError("partial channel was accepted")

    no_channels = tmp_path / "no-channels.env"
    no_channels.write_text("", encoding="utf-8")
    try:
        load_config(no_channels, root_dir=root, require_channel=True)
    except ConfigError as exc:
        assert "notification channel" in str(exc)
    else:
        raise AssertionError("normal operation accepted no channels")
    load_config(no_channels, root_dir=root, require_channel=True, dry_run=True)

detail = "prefix secret-token " + ("x" * 3000)
clean = sanitize_detail(detail, secrets=["secret-token"], limit=2048)
assert "secret-token" not in clean
assert "[REDACTED]" in clean
assert len(clean) <= 2048

import base64
sid = "ACexample"
token = "twilio-secret"
basic = base64.b64encode(f"{sid}:{token}".encode("utf-8")).decode("ascii")
twilio_clean = sanitize_detail(
    f"Authorization Basic {basic} token={token}",
    config={"TWILIO_ACCOUNT_SID": sid, "TWILIO_AUTH_TOKEN": token},
    limit=2048,
)
assert token not in twilio_clean
assert basic not in twilio_clean
assert "[REDACTED]" in twilio_clean
print("configuration precedence and validation passed")
PY
pass "configuration precedence, validation, and sanitization"

TMP=$(mktemp -d)
TEST_DAEMON_PID=""
cleanup() {
  if [[ -n "$TEST_DAEMON_PID" ]] && kill -0 "$TEST_DAEMON_PID" 2>/dev/null; then
    kill "$TEST_DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

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

CLI_ENV="$TMP/cli-flags.env"
cat > "$CLI_ENV" <<EOF
DATA_DIR=$TMP
WAKEUP_DRY_RUN=0
DRY_RUN=0
ONCE=0
KEEP_ACK=0
TEST_CHANNELS=0
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
  "$SCRIPT_DIR/wakeup.sh" --dry-run --once --keep-ack
grep -q 'dry_run=1' "$TMP/cli-flags.log" || fail "CLI --dry-run lost to env file"
grep -q -- '--once: done' "$TMP/cli-flags.log" || fail "CLI --once lost to env file"
pass "CLI flags survive env-file reserved keys"

if DATA_DIR="$TMP" \
   WAKEUP_ENV="$CLI_ENV" \
   WAKEUP_LOG="$TMP/combo.log" \
   WAKEUP_PID="$TMP/combo.pid" \
   WAKEUP_RUNTIME="$TMP/combo-runtime" \
     "$SCRIPT_DIR/wakeup.sh" --dry-run --test-channels >"$TMP/combo.out" 2>&1; then
  fail "--test-channels accepted --dry-run"
fi
grep -q 'cannot be combined' "$TMP/combo.out" \
  || fail "--test-channels/--dry-run rejection message missing"
pass "--test-channels rejects --dry-run"

STUB_DIR="$TMP/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/fail_telegram.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "telegram leaked twilio-secret and Authorization Basic QUNleGFtcGxlOnR3aWxpby1zZWNyZXQ="
exit 7
EOF
cat > "$STUB_DIR/ok_email.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "email sent"
exit 0
EOF
cat > "$STUB_DIR/ok_sms.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "sms sent"
exit 0
EOF
chmod +x "$STUB_DIR"/*.sh

ISOLATION_DIR="$TMP/isolation"
ISOLATION_ENV="$TMP/isolation.env"
mkdir -p "$ISOLATION_DIR"
cat > "$ISOLATION_ENV" <<EOF
DATA_DIR=$ISOLATION_DIR
ACK_FILE=$ISOLATION_DIR/ACK
INTERVAL_SEC=60
INTERVAL_MAX_SEC=900
ACK_POLL_SEC=5
MAX_ALERTS=1
WAKEUP_DRY_RUN=0
TELEGRAM_BOT_TOKEN=telegram-bot-token
TELEGRAM_CHAT_ID=123
SMTP_HOST=smtp.example.com
SMTP_FROM=from@example.com
SMTP_TO=to@example.com
TWILIO_ACCOUNT_SID=ACexample
TWILIO_AUTH_TOKEN=twilio-secret
TWILIO_FROM=+15551234567
SMS_TO=+15557654321
ERROR_DETAIL_MAX_CHARS=2048
LOG_MAX_BYTES=1048576
LOG_BACKUP_COUNT=3
EOF

DATA_DIR="$ISOLATION_DIR" \
WAKEUP_ENV="$ISOLATION_ENV" \
WAKEUP_LOG="$ISOLATION_DIR/wakeup.log" \
WAKEUP_PID="$ISOLATION_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$ISOLATION_DIR/runtime" \
WAKEUP_SEND_TELEGRAM="$STUB_DIR/fail_telegram.sh" \
WAKEUP_SEND_EMAIL="$STUB_DIR/ok_email.sh" \
WAKEUP_SEND_SMS="$STUB_DIR/ok_sms.sh" \
  "$SCRIPT_DIR/wakeup.sh" --once --keep-ack --test-channels
grep -q 'WARNING: telegram alert failed' "$ISOLATION_DIR/wakeup.log" \
  || fail "failed telegram channel was not logged"
grep -q 'email alert: email sent' "$ISOLATION_DIR/wakeup.log" \
  || fail "email channel did not run after telegram failure"
grep -q 'sms alert: sms sent' "$ISOLATION_DIR/wakeup.log" \
  || fail "sms channel did not run after telegram failure"
if grep -q 'twilio-secret' "$ISOLATION_DIR/wakeup.log"; then
  fail "provider failure leaked a raw secret"
fi
if grep -q 'ACexample:twilio-secret' "$ISOLATION_DIR/wakeup.log"; then
  fail "provider failure leaked a derived secret"
fi
if grep -q 'QUNleGFtcGxlOnR3aWxpby1zZWNyZXQ=' "$ISOLATION_DIR/wakeup.log"; then
  fail "provider failure leaked Twilio Basic auth"
fi
grep -q '[REDACTED]' "$ISOLATION_DIR/wakeup.log" \
  || fail "provider failure was not sanitized"
pass "channel isolation and provider sanitization"

TEST_CHANNELS_DRY="$TMP/test-channels-dry.env"
cat > "$TEST_CHANNELS_DRY" <<EOF
DATA_DIR=$TMP/test-channels-dry
ACK_FILE=$TMP/test-channels-dry/ACK
WAKEUP_DRY_RUN=1
TELEGRAM_BOT_TOKEN=telegram-bot-token
TELEGRAM_CHAT_ID=123
INTERVAL_SEC=60
INTERVAL_MAX_SEC=900
ACK_POLL_SEC=5
MAX_ALERTS=1
EOF
mkdir -p "$TMP/test-channels-dry"
DATA_DIR="$TMP/test-channels-dry" \
WAKEUP_ENV="$TEST_CHANNELS_DRY" \
WAKEUP_LOG="$TMP/test-channels-dry/wakeup.log" \
WAKEUP_PID="$TMP/test-channels-dry/wakeup.pid" \
WAKEUP_RUNTIME="$TMP/test-channels-dry/runtime" \
WAKEUP_SEND_TELEGRAM="$STUB_DIR/ok_email.sh" \
  "$SCRIPT_DIR/wakeup.sh" --test-channels
grep -q 'dry-run: rendered' "$TMP/test-channels-dry/wakeup.log" \
  && fail "--test-channels honored WAKEUP_DRY_RUN=1"
grep -q 'telegram alert: email sent' "$TMP/test-channels-dry/wakeup.log" \
  || fail "--test-channels did not force a live send"
pass "--test-channels overrides WAKEUP_DRY_RUN"

unset DATA_DIR WAKEUP_ENV WAKEUP_LOG WAKEUP_ERROR_LOG WAKEUP_PID
unset WAKEUP_RUNTIME WAKEUP_TEMPLATES STARTED_AT_FILE ACK_FILE
unset WAKEUP_SEND_TELEGRAM WAKEUP_SEND_EMAIL WAKEUP_SEND_SMS

wait_for_pattern() {
  local file=$1
  local pattern=$2
  local attempts=${3:-100}
  local i
  for ((i = 0; i < attempts; i++)); do
    if [[ -f "$file" ]] && grep -qF "$pattern" "$file"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

INVALID_DATA_DIR="$TMP/invalid-start"
INVALID_ENV="$TMP/invalid-start.env"
mkdir -p "$INVALID_DATA_DIR"
cat > "$INVALID_ENV" <<EOF
DATA_DIR=$INVALID_DATA_DIR
INTERVAL_SEC=invalid
TELEGRAM_BOT_TOKEN=token-only
EOF
if DATA_DIR="$INVALID_DATA_DIR" \
   WAKEUP_ENV="$INVALID_ENV" \
   WAKEUP_LOG="$INVALID_DATA_DIR/wakeup.log" \
   WAKEUP_PID="$INVALID_DATA_DIR/wakeup.pid" \
     "$SCRIPT_DIR/onstart.sh" >"$TMP/invalid-start.out" 2>&1; then
  fail "onstart accepted invalid configuration"
fi
grep -qF "INTERVAL_SEC" "$TMP/invalid-start.out" \
  || fail "invalid numeric setting was not reported"
grep -qF "TELEGRAM_CHAT_ID" "$TMP/invalid-start.out" \
  || fail "incomplete channel was not reported"
[[ ! -e "$INVALID_DATA_DIR/wakeup.pid" ]] \
  || fail "invalid configuration changed daemon PID state"
pass "invalid startup is rejected before lifecycle changes"

RUNTIME_TEST_DIR="$TMP/runtime-test"
RUNTIME_TEST_ENV="$TMP/runtime-test.env"
UPTIME_FILE="$TMP/uptime"
mkdir -p "$RUNTIME_TEST_DIR"
cat > "$RUNTIME_TEST_ENV" <<EOF
DATA_DIR=$RUNTIME_TEST_DIR
ACK_FILE=$RUNTIME_TEST_DIR/ACK
INTERVAL_SEC=1
INTERVAL_MAX_SEC=2
ACK_POLL_SEC=1
MAX_ALERTS=2
WAKEUP_DRY_RUN=1
CHANNEL_TIMEOUT_SEC=1
ERROR_DETAIL_MAX_CHARS=2048
LOG_MAX_BYTES=1048576
LOG_BACKUP_COUNT=3
EOF
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
  "$SCRIPT_DIR/onstart.sh"

wait_for_pattern "$RUNTIME_TEST_DIR/runtime/alert-email.txt" "Host uptime: 0h 00m 10s" \
  || fail "first alert did not use initial uptime"
cp "$RUNTIME_TEST_DIR/runtime/alert-email.txt" "$TMP/alert-1.txt"

printf '20.0 0.0\n' > "$UPTIME_FILE"
wait_for_pattern "$RUNTIME_TEST_DIR/runtime/alert-email.txt" "Host uptime: 0h 00m 20s" \
  || fail "second alert did not refresh uptime"
cp "$RUNTIME_TEST_DIR/runtime/alert-email.txt" "$TMP/alert-2.txt"

daemon_pid=$(tr -d '[:space:]' < "$RUNTIME_TEST_DIR/wakeup.pid")
TEST_DAEMON_PID="$daemon_pid"
touch "$RUNTIME_TEST_DIR/ACK"
for _ in $(seq 1 100); do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$daemon_pid" 2>/dev/null; then
  kill "$daemon_pid" 2>/dev/null || true
  fail "dry-run daemon did not exit after ACK"
fi
TEST_DAEMON_PID=""

[[ $(grep -c 'wakeup started pid=' "$RUNTIME_TEST_DIR/wakeup.log") -eq 1 ]] \
  || fail "wakeup startup log was duplicated"
[[ $(grep -c 'channels:' "$RUNTIME_TEST_DIR/wakeup.log") -eq 1 ]] \
  || fail "channel log was duplicated"
wait_for_pattern "$RUNTIME_TEST_DIR/wakeup-error.log" "[stdout]" \
  || fail "daemon stdout was not mirrored"
pass "onstart logging and fresh uptime"

OVERRIDE_ACK="$TMP/override/ACK"
EXPECTED_OVERRIDE_ACK=$(cygpath -m "$OVERRIDE_ACK" 2>/dev/null || printf '%s' "$OVERRIDE_ACK")
DATA_DIR="$TMP/wrong-data" \
ACK_FILE="$OVERRIDE_ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$SCRIPT_DIR/ack.sh"
[[ -f "$OVERRIDE_ACK" ]] || fail "ack.sh ignored process ACK_FILE override"

TEST_BASHRC="$TMP/bashrc"
BASHRC="$TEST_BASHRC" \
DATA_DIR="$TMP/wrong-data" \
ACK_FILE="$OVERRIDE_ACK" \
WAKEUP_ENV="$RUNTIME_TEST_ENV" \
  "$SCRIPT_DIR/install-login-ack.sh"
grep -qF "touch \"$EXPECTED_OVERRIDE_ACK\"" "$TEST_BASHRC" \
  || fail "login ack ignored process ACK_FILE override"
pass "path overrides are consistent"

ROTATION_LOG="$TMP/rotation.log"
"$PYTHON" - "$ROTATION_LOG" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text("x" * 128, encoding="utf-8")
PY
log_message "$ROTATION_LOG" 100 3 "rotated record" >/dev/null
[[ -f "$ROTATION_LOG.1" ]] || fail "log rotation did not retain first backup"
[[ $(wc -c < "$ROTATION_LOG") -lt 100 ]] || fail "rotated log is unexpectedly large"
pass "size-based log rotation"

echo
echo "selftest passed"
