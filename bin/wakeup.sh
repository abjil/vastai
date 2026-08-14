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

usage() {
  cat <<'EOF'
Usage: wakeup.sh [options]

  --once           Send one alert (or acked message if ACK exists) and exit
  --dry-run        Render messages; do not send
  --test-channels  One send on each configured channel; do not delete ACK
  --keep-ack       Do not delete a leftover ACK at start
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) ONCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --test-channels) TEST_CHANNELS=1; ONCE=1; KEEP_ACK=1 ;;
    --keep-ack) KEEP_ACK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
mkdir -p "$DATA_DIR"
ENV_FILE="${WAKEUP_ENV:-$DATA_DIR/wakeup.env}"
LOG_FILE="${WAKEUP_LOG:-$DATA_DIR/wakeup.log}"
PID_FILE="${WAKEUP_PID:-$DATA_DIR/wakeup.pid}"
RUNTIME_DIR="${WAKEUP_RUNTIME:-$DATA_DIR/runtime}"
TEMPLATE_DIR="${WAKEUP_TEMPLATES:-$ROOT_DIR/templates}"

log() {
  local msg=$1
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s: %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$msg" | tee -a "$LOG_FILE"
}

if [[ ! -f "$ENV_FILE" ]]; then
  log "ERROR: env file not found: $ENV_FILE"
  log "Copy templates/wakeup.env.example to wakeup.env and edit."
  exit 66
fi

_PRESET_DATA_DIR="${DATA_DIR:-}"
_PRESET_ACK_FILE="${ACK_FILE:-}"
_PRESET_LOG_FILE="${WAKEUP_LOG:-}"
_PRESET_PID_FILE="${WAKEUP_PID:-}"
_PRESET_RUNTIME_DIR="${WAKEUP_RUNTIME:-}"

eval "$("$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" "$ENV_FILE")"

# Explicit process environment wins over wakeup.env (used by tests and onstart).
[[ -n "$_PRESET_DATA_DIR" ]] && DATA_DIR="$_PRESET_DATA_DIR"
[[ -n "$_PRESET_ACK_FILE" ]] && ACK_FILE="$_PRESET_ACK_FILE"
[[ -n "$_PRESET_LOG_FILE" ]] && WAKEUP_LOG="$_PRESET_LOG_FILE"
[[ -n "$_PRESET_PID_FILE" ]] && WAKEUP_PID="$_PRESET_PID_FILE"
[[ -n "$_PRESET_RUNTIME_DIR" ]] && WAKEUP_RUNTIME="$_PRESET_RUNTIME_DIR"

# Env file may relocate data dir; re-apply defaults that depend on it.
DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ACK_FILE="${ACK_FILE:-$DATA_DIR/ACK}"
LOG_FILE="${WAKEUP_LOG:-$DATA_DIR/wakeup.log}"
PID_FILE="${WAKEUP_PID:-$DATA_DIR/wakeup.pid}"
RUNTIME_DIR="${WAKEUP_RUNTIME:-$DATA_DIR/runtime}"
STARTED_AT_FILE="${STARTED_AT_FILE:-$DATA_DIR/started_at}"
INSTANCE_NAME="${INSTANCE_NAME:-vastai}"
INTERVAL_SEC="${INTERVAL_SEC:-60}"
INTERVAL_MAX_SEC="${INTERVAL_MAX_SEC:-900}"
ACK_POLL_SEC="${ACK_POLL_SEC:-5}"
MAX_ALERTS="${MAX_ALERTS:-0}"
if [[ "${WAKEUP_DRY_RUN:-0}" =~ ^(1|yes|true|on)$ ]]; then
  DRY_RUN=1
fi

mkdir -p "$DATA_DIR" "$RUNTIME_DIR"

email_enabled() {
  [[ -n "${SMTP_HOST:-}" && -n "${SMTP_FROM:-}" && -n "${SMTP_TO:-}" ]]
}

telegram_enabled() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

sms_enabled() {
  [[ -n "${TWILIO_ACCOUNT_SID:-}" && -n "${TWILIO_AUTH_TOKEN:-}" && -n "${TWILIO_FROM:-}" && -n "${SMS_TO:-}" ]]
}

any_channel() {
  email_enabled || telegram_enabled || sms_enabled
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
  if [[ -r /proc/uptime ]]; then
    UPTIME_SEC=${UPTIME_SEC:-$(cut -d. -f1 /proc/uptime)}
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
  local rc=0
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    log "$label: $out"
  else
    log "WARNING: $label failed (rc=$rc): $out"
  fi
}

send_channels() {
  local kind=$1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: rendered $kind messages in $RUNTIME_DIR (not sent)"
    return 0
  fi
  if telegram_enabled; then
    send_one "telegram $kind" "$SCRIPT_DIR/send_telegram.sh" "$ENV_FILE" "$RUNTIME_DIR/${kind}-telegram.txt"
  fi
  if email_enabled; then
    send_one "email $kind" "$SCRIPT_DIR/send_email_from_template.sh" "$ENV_FILE" "$RUNTIME_DIR/${kind}-email.txt"
  fi
  if sms_enabled; then
    send_one "sms $kind" "$SCRIPT_DIR/send_sms.sh" "$ENV_FILE" "$RUNTIME_DIR/${kind}-sms.txt"
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

if ! any_channel && [[ "$DRY_RUN" -eq 0 ]]; then
  log "ERROR: no notification channel configured. Set SMTP_* and/or TELEGRAM_* and/or TWILIO_* in $ENV_FILE"
fi

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
