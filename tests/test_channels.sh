#!/usr/bin/env bash
# Channel isolation plus mocked SMTP, Telegram, and Twilio adapters.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
MOCK_PIDS=()
cleanup() {
  local pid
  for pid in "${MOCK_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP" || true
}
trap cleanup EXIT

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
secure_env "$ISOLATION_ENV"

DATA_DIR="$ISOLATION_DIR" \
WAKEUP_ENV="$ISOLATION_ENV" \
WAKEUP_LOG="$ISOLATION_DIR/wakeup.log" \
WAKEUP_PID="$ISOLATION_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$ISOLATION_DIR/runtime" \
WAKEUP_SEND_TELEGRAM="$STUB_DIR/fail_telegram.sh" \
WAKEUP_SEND_EMAIL="$STUB_DIR/ok_email.sh" \
WAKEUP_SEND_SMS="$STUB_DIR/ok_sms.sh" \
  "$BIN_DIR/wakeup.sh" --once --keep-ack --test-channels
grep -q 'WARNING: telegram alert failed' "$ISOLATION_DIR/wakeup.log" \
  || fail "failed telegram channel was not logged"
grep -q 'email alert: email sent' "$ISOLATION_DIR/wakeup.log" \
  || fail "email channel did not run after telegram failure"
grep -q 'sms alert: sms sent' "$ISOLATION_DIR/wakeup.log" \
  || fail "sms channel did not run after telegram failure"
if grep -q 'twilio-secret' "$ISOLATION_DIR/wakeup.log"; then
  fail "provider failure leaked a raw secret"
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
secure_env "$TEST_CHANNELS_DRY"
mkdir -p "$TMP/test-channels-dry"
DATA_DIR="$TMP/test-channels-dry" \
WAKEUP_ENV="$TEST_CHANNELS_DRY" \
WAKEUP_LOG="$TMP/test-channels-dry/wakeup.log" \
WAKEUP_PID="$TMP/test-channels-dry/wakeup.pid" \
WAKEUP_RUNTIME="$TMP/test-channels-dry/runtime" \
WAKEUP_SEND_TELEGRAM="$STUB_DIR/ok_email.sh" \
  "$BIN_DIR/wakeup.sh" --test-channels
grep -q 'dry-run: rendered' "$TMP/test-channels-dry/wakeup.log" \
  && fail "--test-channels honored WAKEUP_DRY_RUN=1"
grep -q 'telegram alert: email sent' "$TMP/test-channels-dry/wakeup.log" \
  || fail "--test-channels did not force a live send"
pass "--test-channels overrides WAKEUP_DRY_RUN"

write_channel_env() {
  local dest=$1
  local data_dir=$2
  cat > "$dest" <<EOF
DATA_DIR=$data_dir
TELEGRAM_BOT_TOKEN=telegram-bot-token
TELEGRAM_CHAT_ID=123
TWILIO_ACCOUNT_SID=ACexample
TWILIO_AUTH_TOKEN=twilio-secret
TWILIO_FROM=+15551234567
SMS_TO=+15557654321
SMTP_HOST=127.0.0.1
SMTP_PORT=PLACEHOLDER
SMTP_TLS=0
SMTP_SSL=0
SMTP_FROM=from@example.com
SMTP_TO=to@example.com
SMTP_TIMEOUT=1
CHANNEL_TIMEOUT_SEC=1
ERROR_DETAIL_MAX_CHARS=2048
EOF
  secure_env "$dest"
}

printf 'telegram test\n' > "$TMP/telegram.txt"
printf 'sms test\n' > "$TMP/sms.txt"
printf 'Subject: test\n\nemail body\n' > "$TMP/email.txt"

tg_ok=$(start_mock http telegram-ok "$TMP/tg-ok.meta") || fail "telegram-ok mock failed to start"
MOCK_PIDS+=("$tg_ok")
tw_ok=$(start_mock http twilio-ok "$TMP/tw-ok.meta") || fail "twilio-ok mock failed to start"
MOCK_PIDS+=("$tw_ok")
smtp_ok=$(start_mock smtp success "$TMP/smtp-ok.meta") || fail "smtp-ok mock failed to start"
MOCK_PIDS+=("$smtp_ok")

OK_ENV="$TMP/ok.env"
write_channel_env "$OK_ENV" "$TMP/ok"
sed -i.bak "s/PLACEHOLDER/$(mock_port "$TMP/smtp-ok.meta")/" "$OK_ENV"
TELEGRAM_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tg-ok.meta")" \
TWILIO_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tw-ok.meta")" \
  "$BIN_DIR/send_telegram.sh" "$OK_ENV" "$TMP/telegram.txt" | grep -q 'Telegram sent' \
  || fail "mocked Telegram success failed"
TELEGRAM_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tg-ok.meta")" \
TWILIO_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tw-ok.meta")" \
  "$BIN_DIR/send_sms.sh" "$OK_ENV" "$TMP/sms.txt" | grep -q 'SMS sent' \
  || fail "mocked Twilio success failed"
"$BIN_DIR/send_email_from_template.sh" "$OK_ENV" "$TMP/email.txt" | grep -q 'Email sent' \
  || fail "mocked SMTP success failed"
pass "mocked Telegram, Twilio, and SMTP success"

tg_err=$(start_mock http telegram-http "$TMP/tg-err.meta") || fail "telegram-http mock failed"
MOCK_PIDS+=("$tg_err")
tw_err=$(start_mock http twilio-http "$TMP/tw-err.meta") || fail "twilio-http mock failed"
MOCK_PIDS+=("$tw_err")
smtp_err=$(start_mock smtp fail "$TMP/smtp-err.meta") || fail "smtp-fail mock failed"
MOCK_PIDS+=("$smtp_err")

ERR_ENV="$TMP/err.env"
write_channel_env "$ERR_ENV" "$TMP/err"
sed -i.bak "s/PLACEHOLDER/$(mock_port "$TMP/smtp-err.meta")/" "$ERR_ENV"
if TELEGRAM_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tg-err.meta")" \
     "$BIN_DIR/send_telegram.sh" "$ERR_ENV" "$TMP/telegram.txt" \
     >"$TMP/tg-err.out" 2>&1; then
  fail "Telegram HTTP failure was treated as success"
fi
grep -q 'HTTP 403' "$TMP/tg-err.out" || fail "Telegram HTTP failure was not reported"
if grep -q 'telegram-bot-token' "$TMP/tg-err.out"; then
  fail "Telegram HTTP failure leaked the bot token"
fi
if TWILIO_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tw-err.meta")" \
     "$BIN_DIR/send_sms.sh" "$ERR_ENV" "$TMP/sms.txt" \
     >"$TMP/tw-err.out" 2>&1; then
  fail "Twilio HTTP failure was treated as success"
fi
grep -q 'HTTP 500' "$TMP/tw-err.out" || fail "Twilio HTTP failure was not reported"
if grep -q 'twilio-secret' "$TMP/tw-err.out"; then
  fail "Twilio HTTP failure leaked the auth token"
fi
if "$BIN_DIR/send_email_from_template.sh" "$ERR_ENV" "$TMP/email.txt" \
     >"$TMP/smtp-err.out" 2>&1; then
  fail "SMTP failure was treated as success"
fi
pass "mocked provider HTTP/SMTP failures"

tg_to=$(start_mock http telegram-timeout "$TMP/tg-to.meta") || fail "telegram-timeout mock failed"
MOCK_PIDS+=("$tg_to")
tw_to=$(start_mock http twilio-timeout "$TMP/tw-to.meta") || fail "twilio-timeout mock failed"
MOCK_PIDS+=("$tw_to")
smtp_to=$(start_mock smtp timeout "$TMP/smtp-to.meta") || fail "smtp-timeout mock failed"
MOCK_PIDS+=("$smtp_to")

TO_ENV="$TMP/timeout.env"
write_channel_env "$TO_ENV" "$TMP/timeout"
sed -i.bak "s/PLACEHOLDER/$(mock_port "$TMP/smtp-to.meta")/" "$TO_ENV"
start_ts=$(date +%s)
if TELEGRAM_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tg-to.meta")" \
     "$BIN_DIR/send_telegram.sh" "$TO_ENV" "$TMP/telegram.txt" \
     >"$TMP/tg-to.out" 2>&1; then
  fail "Telegram timeout was treated as success"
fi
if TWILIO_API_BASE="http://127.0.0.1:$(mock_port "$TMP/tw-to.meta")" \
     "$BIN_DIR/send_sms.sh" "$TO_ENV" "$TMP/sms.txt" \
     >"$TMP/tw-to.out" 2>&1; then
  fail "Twilio timeout was treated as success"
fi
if "$BIN_DIR/send_email_from_template.sh" "$TO_ENV" "$TMP/email.txt" \
     >"$TMP/smtp-to.out" 2>&1; then
  fail "SMTP timeout was treated as success"
fi
elapsed=$(( $(date +%s) - start_ts ))
if [[ "$elapsed" -ge 8 ]]; then
  fail "provider timeouts waited too long (${elapsed}s)"
fi
pass "mocked provider timeouts stay bounded"
