#!/usr/bin/env bash
#
# onstart.sh — Vast.ai onstart helper: start the wakeup nag daemon.
#
# Intended to be exec'd from templates/onstart.vastai.sh after the project
# is cloned or copied to DATA_DIR (default: this project root).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ENV_FILE="${WAKEUP_ENV:-$DATA_DIR/wakeup.env}"
LOG_FILE="${WAKEUP_LOG:-$DATA_DIR/wakeup.log}"
PID_FILE="${WAKEUP_PID:-$DATA_DIR/wakeup.pid}"

mkdir -p "$DATA_DIR"

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

log() {
  printf '%s: %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$1" | tee -a "$LOG_FILE"
}

if [[ ! -f "$ENV_FILE" ]]; then
  log "ERROR: $ENV_FILE is missing. Copy templates/wakeup.env.example and edit."
  log "wakeup daemon not started."
  exit 1
fi

if [[ -f "$PID_FILE" ]]; then
  old_pid=$(tr -d '[:space:]' < "$PID_FILE" || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "stopping previous wakeup pid $old_pid"
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

export DATA_DIR
export WAKEUP_ENV="$ENV_FILE"
export WAKEUP_LOG="$LOG_FILE"
export WAKEUP_PID="$PID_FILE"

log "starting wakeup daemon from $SCRIPT_DIR"
# wakeup.sh appends to wakeup.log itself; keep stdout for nohup leftovers.
nohup "$SCRIPT_DIR/wakeup.sh" >>"$LOG_FILE" 2>&1 &
log "wakeup daemon pid $!"
exit 0
