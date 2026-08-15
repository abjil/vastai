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
from envutil import load_config, sanitize_detail, split_list

env = load_config(Path(sys.argv[2]))
token = env.get("TELEGRAM_BOT_TOKEN", "").strip()
chat_ids = split_list(env.get("TELEGRAM_CHAT_ID", ""))
timeout = int(env["CHANNEL_TIMEOUT_SEC"])
detail_limit = int(env["ERROR_DETAIL_MAX_CHARS"])
text = Path(sys.argv[3]).read_text(encoding="utf-8", errors="replace").strip()
if len(text) > 4000:
    text = text[:3990] + "\n…"

if not token or not chat_ids:
    raise SystemExit("ERROR: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are required.")
if not text:
    raise SystemExit("ERROR: message file is empty.")

errors = []
for chat_id in chat_ids:
    api_base = env.get("TELEGRAM_API_BASE", "https://api.telegram.org").rstrip("/")
    url = f"{api_base}/bot{token}/sendMessage"
    body = urllib.parse.urlencode(
        {"chat_id": chat_id, "text": text, "disable_web_page_preview": "true"}
    ).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read(detail_limit + 1).decode("utf-8", errors="replace")
        detail = sanitize_detail(detail, secrets=[token], limit=detail_limit)
        errors.append(f"{chat_id}: HTTP {exc.code} {detail}")
        continue
    except Exception as exc:
        detail = sanitize_detail(str(exc), secrets=[token], limit=detail_limit)
        errors.append(f"{chat_id}: {detail}")
        continue
    if not payload.get("ok"):
        detail = sanitize_detail(str(payload), secrets=[token], limit=detail_limit)
        errors.append(f"{chat_id}: {detail}")
        continue
    print(f"Telegram sent to chat {chat_id}")

if errors:
    raise SystemExit("ERROR: Telegram send failed: " + "; ".join(errors))
PY
