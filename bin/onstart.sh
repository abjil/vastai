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

if ! CONFIG_OUTPUT=$(
  "$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" \
    "$ENV_FILE" --root "$ROOT_DIR" --require-channel 2>&1
); then
  bootstrap_log "$CONFIG_OUTPUT"
  bootstrap_log "wakeup daemon not started."
  exit 78
fi
eval "$CONFIG_OUTPUT"

LOG_FILE="$WAKEUP_LOG"
ERROR_LOG_FILE="$WAKEUP_ERROR_LOG"
PID_FILE="$WAKEUP_PID"

if ! ensure_writable_dir "$DATA_DIR" ||
   ! ensure_writable_dir "$WAKEUP_RUNTIME" ||
   ! ensure_writable_parent "$ACK_FILE" ||
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

if [[ -f "$PID_FILE" ]]; then
  old_pid=$(tr -d '[:space:]' < "$PID_FILE" || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "stopping previous wakeup pid $old_pid"
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

export DATA_DIR ACK_FILE
export WAKEUP_ENV="$ENV_FILE"
export WAKEUP_LOG WAKEUP_ERROR_LOG WAKEUP_PID WAKEUP_RUNTIME WAKEUP_TEMPLATES
export STARTED_AT_FILE INSTANCE_NAME
export INTERVAL_SEC INTERVAL_MAX_SEC ACK_POLL_SEC MAX_ALERTS WAKEUP_DRY_RUN
export SMTP_TIMEOUT CHANNEL_TIMEOUT_SEC ERROR_DETAIL_MAX_CHARS
export LOG_MAX_BYTES LOG_BACKUP_COUNT
if [[ -n "${WAKEUP_UPTIME_FILE:-}" ]]; then
  export WAKEUP_UPTIME_FILE
fi

log "starting wakeup daemon from $SCRIPT_DIR"
# Application events remain in wakeup.log. Mirror stdout and stderr to the
# console and the separately rotated diagnostic log.
nohup "$SCRIPT_DIR/wakeup.sh" \
  > >(mirror_output stdout) \
  2> >(mirror_output stderr) &
log "wakeup daemon pid $!"
exit 0
