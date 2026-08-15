#!/usr/bin/env bash
#
# onstart.sh — Vast.ai onstart helper: start the wakeup nag daemon.
#
# Intended to be exec'd from templates/onstart.vastai.sh after the project
# is cloned or copied to DATA_DIR (default: this project root).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
BOOTSTRAP_DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ENV_FILE="${WAKEUP_ENV:-$BOOTSTRAP_DATA_DIR/wakeup.env}"
BOOTSTRAP_LOG_FILE="${WAKEUP_LOG:-$BOOTSTRAP_DATA_DIR/wakeup.log}"
BOOTSTRAP_LOG_MAX_BYTES=1048576
BOOTSTRAP_LOG_BACKUP_COUNT=3

bootstrap_log() {
  log_message \
    "$BOOTSTRAP_LOG_FILE" \
    "$BOOTSTRAP_LOG_MAX_BYTES" \
    "$BOOTSTRAP_LOG_BACKUP_COUNT" \
    "$1"
}

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

if [[ ! -f "$ENV_FILE" ]]; then
  bootstrap_log "ERROR: $ENV_FILE is missing. Copy templates/wakeup.env.example and edit."
  bootstrap_log "wakeup daemon not started."
  exit 1
fi

if [[ -n "${WAKEUP_REVISION:-}" ]]; then
  if ! PIN_MSG=$(
    "$SCRIPT_DIR/pin_revision.sh" --repo "$ROOT_DIR" --verify-only \
      "$WAKEUP_REVISION" 2>&1
  ); then
    bootstrap_log "$PIN_MSG"
    bootstrap_log "wakeup daemon not started."
    exit 1
  fi
fi

CONFIG_ERR=$(mktemp)
if ! CONFIG_OUTPUT=$(
  "$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" \
    "$ENV_FILE" --root "$ROOT_DIR" --require-channel 2>"$CONFIG_ERR"
); then
  bootstrap_log "$(cat "$CONFIG_ERR")"
  rm -f "$CONFIG_ERR"
  bootstrap_log "wakeup daemon not started."
  exit 78
fi
if [[ -s "$CONFIG_ERR" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    bootstrap_log "$line"
  done < "$CONFIG_ERR"
fi
rm -f "$CONFIG_ERR"
eval_shell_exports "$CONFIG_OUTPUT"

LOG_FILE="$WAKEUP_LOG"
ERROR_LOG_FILE="$WAKEUP_ERROR_LOG"
PID_FILE="$WAKEUP_PID"

if ! ensure_writable_dir "$DATA_DIR" ||
   ! ensure_writable_dir "$WAKEUP_RUNTIME" ||
   ! ensure_writable_parent "$ACK_FILE" ||
   ! ensure_writable_parent "$SESSION_ID_FILE" ||
   ! ensure_writable_parent "$ACKED_SESSION_FILE" ||
   ! ensure_writable_parent "$WAKEUP_LOCK" ||
   ! ensure_writable_path "$LOG_FILE" ||
   ! ensure_writable_path "$ERROR_LOG_FILE" ||
   ! ensure_writable_path "$PID_FILE" ||
   ! ensure_writable_path "$STARTED_AT_FILE"; then
  bootstrap_log "ERROR: wakeup paths are not writable under DATA_DIR=$DATA_DIR"
  exit 73
fi
if ! ensure_templates_readable "$WAKEUP_TEMPLATES"; then
  bootstrap_log "ERROR: notification templates are not readable under: $WAKEUP_TEMPLATES"
  exit 66
fi

log() {
  log_message "$LOG_FILE" "$LOG_MAX_BYTES" "$LOG_BACKUP_COUNT" "$1"
}

mirror_output() {
  local stream=$1
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    append_raw_log \
      "$ERROR_LOG_FILE" \
      "$LOG_MAX_BYTES" \
      "$LOG_BACKUP_COUNT" \
      "[$stream] $line"
    if [[ "$stream" == "stderr" ]]; then
      printf '%s\n' "$line" >&2 || true
    else
      printf '%s\n' "$line" || true
    fi
  done
}

SESSION_CLI_ARGS=()
if [[ -n "${WAKEUP_SESSION_ID:-}" ]]; then
  SESSION_CLI_ARGS+=(--session "$WAKEUP_SESSION_ID")
fi
if [[ -n "${WAKEUP_SESSION_PROC:-}" ]]; then
  SESSION_CLI_ARGS+=(--proc-root "$WAKEUP_SESSION_PROC")
fi
if [[ -n "${WAKEUP_SESSION_FALLBACK_DIR:-}" ]]; then
  SESSION_CLI_ARGS+=(--fallback-dir "$WAKEUP_SESSION_FALLBACK_DIR")
fi

LOCK_HELD=0
release_startup_lock() {
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    "$PYTHON" "$SCRIPT_DIR/session_id.py" release-lock "$WAKEUP_LOCK" --pid $$ \
      >/dev/null || true
    LOCK_HELD=0
  fi
}
trap release_startup_lock EXIT

if ! "$PYTHON" "$SCRIPT_DIR/session_id.py" acquire-lock "$WAKEUP_LOCK" \
     --pid $$ --timeout 30 "${SESSION_CLI_ARGS[@]}"; then
  log "ERROR: could not acquire startup lock $WAKEUP_LOCK"
  exit 75
fi
LOCK_HELD=1

SESSION_ID=$(
  "$PYTHON" "$SCRIPT_DIR/session_id.py" ensure "$SESSION_ID_FILE" \
    "${SESSION_CLI_ARGS[@]}"
) || exit 1

WAKEUP_SCRIPT="$SCRIPT_DIR/wakeup.sh"
DAEMON_STATUS=$(
  "$PYTHON" "$SCRIPT_DIR/session_id.py" daemon-status "$PID_FILE" \
    --script "$WAKEUP_SCRIPT" "${SESSION_CLI_ARGS[@]}"
) || DAEMON_STATUS=missing

if [[ "$DAEMON_STATUS" == "running" ]]; then
  existing_pid=$(
    "$PYTHON" "$SCRIPT_DIR/session_id.py" read-pid "$PID_FILE" --field pid
  ) || existing_pid="unknown"
  log "wakeup already running pid=$existing_pid session=$SESSION_ID"
  exit 0
fi

if [[ "$DAEMON_STATUS" == "running-other-session" ]]; then
  old_pid=$(
    "$PYTHON" "$SCRIPT_DIR/session_id.py" read-pid "$PID_FILE" --field pid
  ) || old_pid="unknown"
  log "stopping previous wakeup pid $old_pid for a different session"
  "$PYTHON" "$SCRIPT_DIR/session_id.py" stop-daemon "$PID_FILE" \
    --script "$WAKEUP_SCRIPT" --timeout 5 "${SESSION_CLI_ARGS[@]}" >/dev/null
elif [[ "$DAEMON_STATUS" == "stale" ]]; then
  log "ignoring stale PID file $PID_FILE"
fi

export DATA_DIR ACK_FILE
export WAKEUP_ENV="$ENV_FILE"
export WAKEUP_LOG WAKEUP_ERROR_LOG WAKEUP_PID WAKEUP_RUNTIME WAKEUP_TEMPLATES
export STARTED_AT_FILE INSTANCE_NAME
export SESSION_ID_FILE WAKEUP_LOCK ACKED_SESSION_FILE
export INTERVAL_SEC INTERVAL_MAX_SEC ACK_POLL_SEC MAX_ALERTS WAKEUP_DRY_RUN
export SMTP_TIMEOUT CHANNEL_TIMEOUT_SEC ERROR_DETAIL_MAX_CHARS
export LOG_MAX_BYTES LOG_BACKUP_COUNT
export WAKEUP_LEGACY_EMPTY_ACK
export PUBLIC_IP_LOOKUP PUBLIC_IP_CACHE_FILE
if [[ -n "${WAKEUP_UPTIME_FILE:-}" ]]; then
  export WAKEUP_UPTIME_FILE
fi
if [[ -n "${WAKEUP_PUBLIC_IP:-}" ]]; then
  export WAKEUP_PUBLIC_IP
fi
if [[ -n "${WAKEUP_PUBLIC_IP_CMD:-}" ]]; then
  export WAKEUP_PUBLIC_IP_CMD
fi
if [[ -n "${WAKEUP_PUBLIC_IP_URLS:-}" ]]; then
  export WAKEUP_PUBLIC_IP_URLS
fi
if [[ -n "${TELEGRAM_API_BASE:-}" ]]; then
  export TELEGRAM_API_BASE
fi
if [[ -n "${TWILIO_API_BASE:-}" ]]; then
  export TWILIO_API_BASE
fi
if [[ -n "${WAKEUP_SESSION_ID:-}" ]]; then
  export WAKEUP_SESSION_ID
fi
if [[ -n "${WAKEUP_SESSION_PROC:-}" ]]; then
  export WAKEUP_SESSION_PROC
fi
if [[ -n "${WAKEUP_SESSION_FALLBACK_DIR:-}" ]]; then
  export WAKEUP_SESSION_FALLBACK_DIR
fi

log "starting wakeup daemon from $SCRIPT_DIR session=$SESSION_ID"
# Application events remain in wakeup.log. Mirror stdout and stderr to the
# console and the separately rotated diagnostic log.
nohup "$SCRIPT_DIR/wakeup.sh" \
  > >(mirror_output stdout) \
  2> >(mirror_output stderr) &
child_pid=$!

started=0
for ((i = 0; i < 100; i++)); do
  if ! kill -0 "$child_pid" 2>/dev/null; then
    break
  fi
  if file_pid=$(
    "$PYTHON" "$SCRIPT_DIR/session_id.py" read-pid "$PID_FILE" --field pid 2>/dev/null
  ) && [[ "$file_pid" == "$child_pid" ]]; then
    if "$PYTHON" "$SCRIPT_DIR/session_id.py" verify-daemon "$PID_FILE" \
         --script "$WAKEUP_SCRIPT" "${SESSION_CLI_ARGS[@]}"; then
      started=1
      break
    fi
    if kill -0 "$child_pid" 2>/dev/null; then
      started=1
      break
    fi
  fi
  sleep 0.1
done

if [[ "$started" -ne 1 ]]; then
  log "ERROR: wakeup daemon failed to publish process identity"
  exit 1
fi
log "wakeup daemon pid $child_pid session=$SESSION_ID"
exit 0
