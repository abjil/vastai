#!/usr/bin/env bash
#
# send_sms.sh — send a plaintext file via Twilio Messages API
#
# Usage:
#   send_sms.sh <ENV_FILE> <MESSAGE_FILE>
#
# Required .env:
#   TWILIO_ACCOUNT_SID
#   TWILIO_AUTH_TOKEN
#   TWILIO_FROM
#   SMS_TO                 # comma-separated E.164 numbers

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
import base64
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from envutil import parse_env, split_list

env = parse_env(Path(sys.argv[2]))
sid = env.get("TWILIO_ACCOUNT_SID", "").strip()
token = env.get("TWILIO_AUTH_TOKEN", "").strip()
from_num = env.get("TWILIO_FROM", "").strip()
to_list = split_list(env.get("SMS_TO", ""))
text = Path(sys.argv[3]).read_text(encoding="utf-8", errors="replace").strip()
if len(text) > 1500:
    text = text[:1490] + "\n…"

missing = [n for n, v in [
    ("TWILIO_ACCOUNT_SID", sid),
    ("TWILIO_AUTH_TOKEN", token),
    ("TWILIO_FROM", from_num),
    ("SMS_TO", ",".join(to_list)),
] if not v]
if missing:
    raise SystemExit("ERROR: Missing required .env variables: " + ", ".join(missing))
if not text:
    raise SystemExit("ERROR: message file is empty.")

auth = base64.b64encode(f"{sid}:{token}".encode("utf-8")).decode("ascii")
url = f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json"
errors = []
for to in to_list:
    body = urllib.parse.urlencode({"From": from_num, "To": to, "Body": text}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Authorization", f"Basic {auth}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        errors.append(f"{to}: HTTP {exc.code} {detail}")
        continue
    except Exception as exc:
        errors.append(f"{to}: {exc}")
        continue
    sid_out = payload.get("sid", "")
    print(f"SMS sent to {to} sid={sid_out}")

if errors:
    raise SystemExit("ERROR: SMS send failed: " + "; ".join(errors))
PY
