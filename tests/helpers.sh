# Shared test helpers. Source from tests/test_*.sh
# shellcheck shell=bash

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TESTS_DIR/.." && pwd)
BIN_DIR="$ROOT_DIR/bin"
# shellcheck source=../bin/lib.sh
. "$BIN_DIR/lib.sh"
export PYTHONPATH="$BIN_DIR${PYTHONPATH:+:$PYTHONPATH}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

PYTHON=${PYTHON:-$(resolve_python)} || fail "python3 is required"

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

read_daemon_pid() {
  "$PYTHON" "$BIN_DIR/session_id.py" read-pid "$1" --field pid
}

write_lifecycle_env() {
  local dest=$1
  local data_dir=$2
  cat > "$dest" <<EOF
DATA_DIR=$data_dir
ACK_FILE=$data_dir/ACK
INTERVAL_SEC=1
INTERVAL_MAX_SEC=2
ACK_POLL_SEC=1
MAX_ALERTS=2
WAKEUP_DRY_RUN=1
CHANNEL_TIMEOUT_SEC=1
SMTP_TIMEOUT=1
ERROR_DETAIL_MAX_CHARS=2048
LOG_MAX_BYTES=1048576
LOG_BACKUP_COUNT=3
PUBLIC_IP_LOOKUP=0
EOF
}

secure_env() {
  chmod 600 "$1" 2>/dev/null || true
}

start_mock() {
  local kind=$1
  local preset=$2
  local out=$3
  local extra=${4:-}
  # Redirect mock I/O so `$(start_mock ...)` does not wait on the server.
  # shellcheck disable=SC2086
  "$PYTHON" "$TESTS_DIR/mock_${kind}.py" --preset "$preset" --output "$out" $extra \
    >"${out}.stdout" 2>"${out}.stderr" &
  local pid=$!
  local i
  for ((i = 0; i < 50; i++)); do
    if [[ -f "$out" ]] && grep -q '^PORT=' "$out"; then
      echo "$pid"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      [[ -f "${out}.stderr" ]] && cat "${out}.stderr" >&2
      return 1
    fi
    sleep 0.05
  done
  [[ -f "${out}.stderr" ]] && cat "${out}.stderr" >&2
  return 1
}

mock_port() {
  local file=$1
  grep '^PORT=' "$file" | head -n1 | cut -d= -f2 | tr -d '\r'
}
