#!/usr/bin/env bash
# Log rotation and sanitization.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ROTATION_LOG="$TMP/rotation.log"
"$PYTHON" - "$ROTATION_LOG" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text("x" * 128, encoding="utf-8")
PY
log_message "$ROTATION_LOG" 100 3 "rotated record" >/dev/null
[[ -f "$ROTATION_LOG.1" ]] || fail "log rotation did not retain first backup"
[[ "$(wc -c < "$ROTATION_LOG")" -lt 100 ]] || fail "rotated log is unexpectedly large"
pass "size-based log rotation"
