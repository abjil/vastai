#!/usr/bin/env bash
#
# install-login-ack.sh — install or remove SSH-login auto-ack in ~/.bashrc
#
# Trigger: any shell where SSH_CONNECTION is set.
# Risk: automation or another operator's SSH login acknowledges this session.
# Skip without uninstall:  touch ~/.no_login_ack
# Uninstall:               install-login-ack.sh --uninstall

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
BOOTSTRAP_DATA_DIR="${DATA_DIR:-$ROOT_DIR}"
ENV_FILE="${WAKEUP_ENV:-$BOOTSTRAP_DATA_DIR/wakeup.env}"
BASHRC="${BASHRC:-$HOME/.bashrc}"
MARKER_BEGIN="# >>> vastai-wakeup login ack >>>"
MARKER_END="# <<< vastai-wakeup login ack <<<"

usage() {
  cat <<'EOF'
Usage: install-login-ack.sh [--uninstall]

  Install an SSH-login auto-ack snippet into ~/.bashrc, or remove it.

  Trigger: SSH_CONNECTION is set in the starting shell.
  Risk: any matching SSH login, including automation, acknowledges the
        current billed session and stops alerts.
  Temporary disable: touch ~/.no_login_ack
EOF
}

print_risk() {
  cat <<EOF
Trigger: any shell where SSH_CONNECTION is set (interactive SSH, including automation).
Risk: that login acknowledges the current billed session and stops alerts.
Temporary disable: touch ~/.no_login_ack
Uninstall: $SCRIPT_DIR/install-login-ack.sh --uninstall
EOF
}

remove_snippet() {
  "$PYTHON" - "$BASHRC" "$MARKER_BEGIN" "$MARKER_END" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
begin, end = sys.argv[2], sys.argv[3]
if not path.is_file():
    raise SystemExit(2)
text = path.read_text(encoding="utf-8")
start = text.find(begin)
stop = text.find(end, start) if start >= 0 else -1
if start < 0 or stop < 0:
    raise SystemExit(1)
stop += len(end)
while stop < len(text) and text[stop] == "\n":
    stop += 1
while start > 0 and text[start - 1] == "\n":
    start -= 1
    if start > 0 and text[start - 1] == "\n":
        break
updated = text[:start] + ("\n" if start and not text[:start].endswith("\n") else "") + text[stop:]
path.write_text(updated, encoding="utf-8")
PY
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  if remove_snippet; then
    echo "Removed login auto-ack from $BASHRC"
    exit 0
  fi
  echo "No login-ack snippet in $BASHRC"
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  echo "Unknown option: $1" >&2
  usage >&2
  exit 64
fi

if [[ -f "$ENV_FILE" ]]; then
  CONFIG_OUTPUT=$(
    "$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" "$ENV_FILE" --root "$ROOT_DIR"
  ) || exit $?
  eval_shell_exports "$CONFIG_OUTPUT"
else
  DATA_DIR="$BOOTSTRAP_DATA_DIR"
  ACK_FILE="${ACK_FILE:-$DATA_DIR/ACK}"
  SESSION_ID_FILE="${SESSION_ID_FILE:-$DATA_DIR/session.id}"
fi

ACK_SH="$SCRIPT_DIR/ack.sh"
quoted_ack_sh=$(printf '%q' "$ACK_SH")
quoted_data_dir=$(printf '%q' "$DATA_DIR")
quoted_ack_file=$(printf '%q' "$ACK_FILE")
quoted_env_file=$(printf '%q' "$ENV_FILE")
quoted_session_file=$(printf '%q' "$SESSION_ID_FILE")

snippet=$(cat <<EOF
$MARKER_BEGIN
# Auto-ack Vast.ai wakeup nag on SSH login. Disable: touch ~/.no_login_ack
# Writes the current session token to ACK; an empty touch is not sufficient.
if [ -n "\${SSH_CONNECTION:-}" ] && [ ! -e "\$HOME/.no_login_ack" ]; then
  DATA_DIR=$quoted_data_dir \\
  ACK_FILE=$quoted_ack_file \\
  SESSION_ID_FILE=$quoted_session_file \\
  WAKEUP_ENV=$quoted_env_file \\
    $quoted_ack_sh >/dev/null 2>&1 || true
fi
$MARKER_END
EOF
)

if [[ -f "$BASHRC" ]] && grep -qF "$MARKER_BEGIN" "$BASHRC"; then
  echo "Login-ack snippet already present in $BASHRC"
  print_risk
  exit 0
fi

touch "$BASHRC"
printf '\n%s\n' "$snippet" >> "$BASHRC"
echo "Installed login auto-ack into $BASHRC (ACK=$ACK_FILE)"
print_risk
