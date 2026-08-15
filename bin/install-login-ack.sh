#!/usr/bin/env bash
#
# install-login-ack.sh — append an SSH-login auto-ack snippet to ~/.bashrc
#
# Creates ACK when an interactive SSH session starts (Vast.ai tmux included).
# Skip:  touch ~/.no_login_ack

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

if [[ -f "$ENV_FILE" ]]; then
  CONFIG_OUTPUT=$(
    "$PYTHON" "$SCRIPT_DIR/dump_env_shell.py" "$ENV_FILE" --root "$ROOT_DIR"
  ) || exit $?
  eval "$CONFIG_OUTPUT"
else
  DATA_DIR="$BOOTSTRAP_DATA_DIR"
  ACK_FILE="${ACK_FILE:-$DATA_DIR/ACK}"
fi

snippet=$(cat <<EOF
$MARKER_BEGIN
# Auto-ack Vast.ai wakeup nag on SSH login. Disable: touch ~/.no_login_ack
if [ -n "\${SSH_CONNECTION:-}" ] && [ ! -e "\$HOME/.no_login_ack" ]; then
  mkdir -p "$(dirname "$ACK_FILE")" 2>/dev/null
  touch "$ACK_FILE" 2>/dev/null || true
fi
$MARKER_END
EOF
)

if [[ -f "$BASHRC" ]] && grep -qF "$MARKER_BEGIN" "$BASHRC"; then
  echo "Login-ack snippet already present in $BASHRC"
  exit 0
fi

touch "$BASHRC"
printf '\n%s\n' "$snippet" >> "$BASHRC"
echo "Installed login auto-ack into $BASHRC (ACK=$ACK_FILE)"
