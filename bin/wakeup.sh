#!/usr/bin/env bash
#
# wakeup.sh — nag until ACK appears on this Vast.ai instance boot
#
# Usage:
#   wakeup.sh [--once] [--dry-run] [--test-channels] [--keep-ack]
#
# Reads $WAKEUP_ENV or $DATA_DIR/wakeup.env (default DATA_DIR = project root).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
export PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}"

ONCE=0
DRY_RUN=0
TEST_CHANNELS=0
KEEP_ACK=0
WANT_DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: wakeup.sh [options]

  --once           Send one alert (or acked message if ACK exists) and exit
  --dry-run        Render messages; do not send
  --test-channels  One live send on each configured channel; do not delete ACK
                   Cannot be combined with --dry-run. Overrides WAKEUP_DRY_RUN.
  --keep-ack       Do not delete a leftover ACK at start
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=1 ;;
    --dry-run) WANT_DRY_RUN=1; DRY_RUN=1 ;;
    --test-channels) TEST_CHANNELS=1; ONCE=1; KEEP_ACK=1 ;;
    --keep-ack) KEEP_ACK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

if [[ "$TEST_CHANNELS" -eq 1 && "$WANT_DRY_RUN" -eq 1 ]]; then
  echo "ERROR: --test-channels and --dry-run cannot be combined." >&2
  exit 64
fi

CLI_ONCE=$ONCE
CLI_TEST_CHANNELS=$TEST_CHANNELS
CLI_KEEP_ACK=$KEEP_ACK

BOOTSTRAP_DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ENV_FILE="${WAKEUP_ENV:-$BOOTSTRAP_DATA_DIR/wakeup.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  echo "Copy templates/wakeup.env.example to wakeup.env and edit." >&2
  exit 66
fi

config_args=("$ENV_FILE" --root "$ROOT_DIR" --require-channel)
if [[ "$DRY_RUN" -eq 1 ]]; then
  config_args+=(--dry-run)
fi
CONFIG_OUTPUT=$("$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" "${config_args[@]}") || exit $?
eval "$CONFIG_OUTPUT"

ONCE=$CLI_ONCE
KEEP_ACK=$CLI_KEEP_ACK
TEST_CHANNELS=$CLI_TEST_CHANNELS
if [[ "$CLI_TEST_CHANNELS" -eq 1 ]]; then
  DRY_RUN=0
elif [[ "$WANT_DRY_RUN" -eq 1 ]]; then
  DRY_RUN=1
elif [[ "${WAKEUP_DRY_RUN:-0}" =~ ^(1|yes|true|on)$ ]]; then
  DRY_RUN=1
else
  DRY_RUN=0
fi

LOG_FILE="$WAKEUP_LOG"
ERROR_LOG_FILE="$WAKEUP_ERROR_LOG"
PID_FILE="$WAKEUP_PID"
RUNTIME_DIR="$WAKEUP_RUNTIME"
TEMPLATE_DIR="$WAKEUP_TEMPLATES"

if ! ensure_writable_dir "$DATA_DIR" ||
   ! ensure_writable_dir "$RUNTIME_DIR" ||
   ! ensure_writable_parent "$ACK_FILE" ||
   ! ensure_writable_path "$LOG_FILE" ||
   ! ensure_writable_path "$ERROR_LOG_FILE" ||
   ! ensure_writable_path "$PID_FILE" ||
   ! ensure_writable_path "$STARTED_AT_FILE"; then
  echo "ERROR: wakeup paths are not writable under DATA_DIR=$DATA_DIR" >&2
  exit 73
fi
if ! ensure_templates_readable "$TEMPLATE_DIR"; then
  echo "ERROR: notification templates are not readable under: $TEMPLATE_DIR" >&2
  exit 66
fi

log() {
  log_message "$LOG_FILE" "$LOG_MAX_BYTES" "$LOG_BACKUP_COUNT" "$1"
}

email_enabled() {
  [[ -n "${SMTP_HOST:-}" && -n "${SMTP_FROM:-}" && -n "${SMTP_TO:-}" ]]
}

telegram_enabled() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

sms_enabled() {
  [[ -n "${TWILIO_ACCOUNT_SID:-}" && -n "${TWILIO_AUTH_TOKEN:-}" && -n "${TWILIO_FROM:-}" && -n "${SMS_TO:-}" ]]
}

format_elapsed() {
  local total=$1
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))
  printf '%dh %02dm %02ds' "$h" "$m" "$s"
}

collect_facts() {
  local alert_num=$1
  local kind=$2
  HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname || echo unknown)
  VAST_LABEL="${VAST_CONTAINERLABEL:-}"
  if [[ -z "$VAST_LABEL" && -f "${HOME:-/root}/.vast_containerlabel" ]]; then
    VAST_LABEL=$(tr -d '\r\n' < "${HOME:-/root}/.vast_containerlabel")
  fi
  [[ -n "$VAST_LABEL" ]] || VAST_LABEL=unknown
  PUBLIC_IP=unknown
  if [[ "$DRY_RUN" -eq 0 ]]; then
    PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)
    if [[ -z "$PUBLIC_IP" ]]; then
      PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null || true)
    fi
    PUBLIC_IP=$(printf '%s' "$PUBLIC_IP" | tr -d '[:space:]')
    [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP=unknown
  fi
  if [[ -n "${WAKEUP_UPTIME_FILE:-}" && -r "$WAKEUP_UPTIME_FILE" ]]; then
    UPTIME_SEC=$(cut -d. -f1 "$WAKEUP_UPTIME_FILE")
    if [[ "$UPTIME_SEC" =~ ^[0-9]+$ ]]; then
      UPTIME_VAL=$(format_elapsed "$UPTIME_SEC")
    else
      UPTIME_VAL=unknown
    fi
  elif [[ -r /proc/uptime ]]; then
    UPTIME_SEC=$(cut -d. -f1 /proc/uptime)
    UPTIME_VAL=$(format_elapsed "$UPTIME_SEC")
  else
    UPTIME_VAL=$(uptime -p 2>/dev/null || echo unknown)
  fi
  NOW_VAL=$(date -u +'%Y-%m-%d %H:%M:%S UTC')
  local started=0
  if [[ -f "$STARTED_AT_FILE" ]]; then
    started=$(tr -d '[:space:]' < "$STARTED_AT_FILE" || true)
  fi
  local now_epoch
  now_epoch=$(date +%s)
  local elapsed=0
  if [[ "$started" =~ ^[0-9]+$ ]]; then
    elapsed=$((now_epoch - started))
    if [[ "$elapsed" -lt 0 ]]; then
      elapsed=0
    fi
  fi
  ELAPSED_VAL=$(format_elapsed "$elapsed")
  STARTED_AT_VAL=$(date -u -d "@${started}" +'%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo unknown)
  ACK_HINT="touch ${ACK_FILE}"
  KIND_VAL=$kind
  ALERT_NUM_VAL=$alert_num
}

write_facts_env() {
  "$PYTHON" - "$RUNTIME_DIR/facts.env" \
    "$INSTANCE_NAME" "$HOSTNAME_VAL" "$VAST_LABEL" "$PUBLIC_IP" \
    "$STARTED_AT_VAL" "$NOW_VAL" "$ALERT_NUM_VAL" "$UPTIME_VAL" \
    "$ACK_FILE" "$ACK_HINT" "$ELAPSED_VAL" "$KIND_VAL" <<'PY'
import shlex
import sys
from pathlib import Path

dest = Path(sys.argv[1])
keys = [
    "INSTANCE_NAME", "HOSTNAME", "VAST_LABEL", "PUBLIC_IP",
    "STARTED_AT", "NOW", "ALERT_NUM", "UPTIME",
    "ACK_FILE", "ACK_HINT", "ELAPSED", "KIND",
]
vals = sys.argv[2:]
lines = [f"{k}={shlex.quote(v)}" for k, v in zip(keys, vals)]
dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

render_kind() {
  local kind=$1
  local email_tpl telegram_tpl sms_tpl
  if [[ "$kind" == "acked" ]]; then
    email_tpl="$TEMPLATE_DIR/acked-email.txt"
    telegram_tpl="$TEMPLATE_DIR/acked-telegram.txt"
    sms_tpl="$TEMPLATE_DIR/acked-sms.txt"
  else
    email_tpl="$TEMPLATE_DIR/alert-email.txt"
    telegram_tpl="$TEMPLATE_DIR/alert-telegram.txt"
    sms_tpl="$TEMPLATE_DIR/alert-sms.txt"
  fi
  "$PYTHON" "$SCRIPT_DIR/render_template.py" --env "$ENV_FILE" --env "$RUNTIME_DIR/facts.env" \
    "$email_tpl" "$RUNTIME_DIR/${kind}-email.txt"
  "$PYTHON" "$SCRIPT_DIR/render_template.py" --env "$ENV_FILE" --env "$RUNTIME_DIR/facts.env" \
    "$telegram_tpl" "$RUNTIME_DIR/${kind}-telegram.txt"
  "$PYTHON" "$SCRIPT_DIR/render_template.py" --env "$ENV_FILE" --env "$RUNTIME_DIR/facts.env" \
    "$sms_tpl" "$RUNTIME_DIR/${kind}-sms.txt"
}

send_one() {
  local label=$1
  shift
  local out=""
  local sanitized=""
  local rc=0
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  if ! sanitized=$(
    printf '%s' "$out" |
      "$PYTHON" "$SCRIPT_DIR/sanitize_output.py" \
        --env "$ENV_FILE" --limit "$ERROR_DETAIL_MAX_CHARS"
  ); then
    sanitized="[provider output could not be sanitized]"
  fi
  if [[ "$rc" -eq 0 ]]; then
    log "$label: $sanitized"
  else
    log "WARNING: $label failed (rc=$rc): $sanitized"
  fi
}

send_channels() {
  local kind=$1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: rendered $kind messages in $RUNTIME_DIR (not sent)"
    return 0
  fi
  if telegram_enabled; then
    send_one "telegram $kind" \
      "${WAKEUP_SEND_TELEGRAM:-$SCRIPT_DIR/send_telegram.sh}" \
      "$ENV_FILE" "$RUNTIME_DIR/${kind}-telegram.txt"
  fi
  if email_enabled; then
    send_one "email $kind" \
      "${WAKEUP_SEND_EMAIL:-$SCRIPT_DIR/send_email_from_template.sh}" \
      "$ENV_FILE" "$RUNTIME_DIR/${kind}-email.txt"
  fi
  if sms_enabled; then
    send_one "sms $kind" \
      "${WAKEUP_SEND_SMS:-$SCRIPT_DIR/send_sms.sh}" \
      "$ENV_FILE" "$RUNTIME_DIR/${kind}-sms.txt"
  fi
}

sleep_checking_ack() {
  local remaining=$1
  local chunk
  while [[ "$remaining" -gt 0 ]]; do
    if [[ -f "$ACK_FILE" ]]; then
      return 0
    fi
    chunk=$ACK_POLL_SEC
    if [[ "$chunk" -gt "$remaining" ]]; then
      chunk=$remaining
    fi
    sleep "$chunk"
    remaining=$((remaining - chunk))
  done
  return 1
}

notify_kind() {
  local kind=$1
  local alert_num=$2
  collect_facts "$alert_num" "$kind"
  write_facts_env
  render_kind "$kind"
  send_channels "$kind"
}

if [[ "$KEEP_ACK" -eq 0 ]]; then
  if [[ -f "$ACK_FILE" ]]; then
    log "removing leftover ACK from a previous session: $ACK_FILE"
    rm -f "$ACK_FILE"
  fi
fi

date +%s > "$STARTED_AT_FILE"
echo $$ > "$PID_FILE"
cleanup() {
  rm -f "$PID_FILE"
}
trap cleanup EXIT

tg_on=no
em_on=no
sms_on=no
telegram_enabled && tg_on=yes
email_enabled && em_on=yes
sms_enabled && sms_on=yes
log "wakeup started pid=$$ instance=${INSTANCE_NAME} data=$DATA_DIR dry_run=$DRY_RUN"
log "channels: telegram=$tg_on email=$em_on sms=$sms_on"

ALERT_NUM=0
INTERVAL=$INTERVAL_SEC

while true; do
  if [[ -f "$ACK_FILE" ]]; then
    log "ACK present at $ACK_FILE — sending final message and exiting"
    notify_kind acked "$ALERT_NUM"
    log "acked after $ALERT_NUM alert(s); exiting"
    exit 0
  fi

  if [[ "$MAX_ALERTS" -gt 0 && "$ALERT_NUM" -ge "$MAX_ALERTS" ]]; then
    log "MAX_ALERTS=$MAX_ALERTS reached; still waiting for ACK (no further sends this interval)"
  else
    ALERT_NUM=$((ALERT_NUM + 1))
    log "sending alert #$ALERT_NUM (next interval ${INTERVAL}s)"
    notify_kind alert "$ALERT_NUM"
  fi

  if [[ "$ONCE" -eq 1 ]]; then
    log "--once: done"
    exit 0
  fi

  if sleep_checking_ack "$INTERVAL"; then
    continue
  fi

  next=$((INTERVAL * 2))
  if [[ "$next" -gt "$INTERVAL_MAX_SEC" ]]; then
    next=$INTERVAL_MAX_SEC
  fi
  INTERVAL=$next
done
