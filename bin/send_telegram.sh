#!/usr/bin/env bash
#
# send_telegram.sh — send a plaintext file via Telegram Bot API
#
# Usage:
#   send_telegram.sh <ENV_FILE> <MESSAGE_FILE>
#
# Required .env:
#   TELEGRAM_BOT_TOKEN
#   TELEGRAM_CHAT_ID     # comma-separated chat ids allowed

set -euo pipefail

usage() {
  echo "Usage: $0 <ENV_FILE> <MESSAGE_FILE>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
ENV_FILE=$1
MESSAGE_FILE=$2

[[ -f "$ENV_FILE" ]] || { echo "ERROR: ENV_FILE '$ENV_FILE' not found." >&2; exit 66; }
[[ -f "$MESSAGE_FILE" ]] || { echo "ERROR: MESSAGE_FILE '$MESSAGE_FILE' not found." >&2; exit 66; }

"$PYTHON" - "$SCRIPT_DIR" "$ENV_FILE" "$MESSAGE_FILE" <<'PY'
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from envutil import parse_env, split_list

env = parse_env(Path(sys.argv[2]))
token = env.get("TELEGRAM_BOT_TOKEN", "").strip()
chat_ids = split_list(env.get("TELEGRAM_CHAT_ID", ""))
text = Path(sys.argv[3]).read_text(encoding="utf-8", errors="replace").strip()
if len(text) > 4000:
    text = text[:3990] + "\n…"

if not token or not chat_ids:
    raise SystemExit("ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are required.")
if not text:
    raise SystemExit("ERROR: message file is empty.")

errors = []
for chat_id in chat_ids:
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    body = urllib.parse.urlencode(
        {"chat_id": chat_id, "text": text, "disable_web_page_preview": "true"}
    ).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        errors.append(f"{chat_id}: HTTP {exc.code} {detail}")
        continue
    except Exception as exc:
        errors.append(f"{chat_id}: {exc}")
        continue
    if not payload.get("ok"):
        errors.append(f"{chat_id}: {payload}")
        continue
    print(f"Telegram sent to chat {chat_id}")

if errors:
    raise SystemExit("ERROR: Telegram send failed: " + "; ".join(errors))
PY
