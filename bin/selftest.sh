#!/usr/bin/env bash
#
# selftest.sh — no-network checks for CI and local sanity.
# Substantial cases live under tests/; this file is the operator entry point.

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

for sh in "$SCRIPT_DIR"/*.sh "$ROOT_DIR/tests"/*.sh "$ROOT_DIR/templates/onstart.vastai.sh"; do
  bash -n "$sh" || fail "bash -n $sh"
done
pass "bash -n all scripts"

# Clean checkouts may not retain executable modes when authored on Windows.
chmod +x "$SCRIPT_DIR"/*.sh "$ROOT_DIR/tests"/*.sh || fail "chmod +x scripts"
pass "shell scripts executable"

"$PYTHON" -m py_compile \
  "$SCRIPT_DIR/envutil.py" \
  "$SCRIPT_DIR/render_template.py" \
  "$SCRIPT_DIR/dump_env_shell.py" \
  "$SCRIPT_DIR/sanitize_output.py" \
  "$SCRIPT_DIR/session_id.py" \
  "$ROOT_DIR/tests/mock_http.py" \
  "$ROOT_DIR/tests/mock_smtp.py" \
  "$ROOT_DIR/tests/test_envutil.py" \
  "$ROOT_DIR/tests/test_session_id.py" \
  "$ROOT_DIR/tests/test_templates.py" \
  || fail "py_compile"
pass "python3 -m py_compile"

export PYTHON
exec bash "$ROOT_DIR/tests/run.sh"
