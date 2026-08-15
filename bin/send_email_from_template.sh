#!/usr/bin/env bash
#
# send_email_from_template.sh — generic SMTP email sender from a template/body file
#
# Generic public SMTP sender; not tied to a LAN mail host.
#
# Usage:
#   send_email_from_template.sh <ENV_FILE> <TEMPLATE_FILE>
#
# Required .env variables:
#   SMTP_HOST=smtp.example.com
#   SMTP_FROM=backup@example.com
#   SMTP_TO=admin@example.com
#
# Common optional .env variables:
#   SMTP_PORT=587
#   SMTP_USER=backup@example.com
#   SMTP_PASSWORD='secret'
#   SMTP_TLS=1          # STARTTLS; default 1 unless SMTP_SSL=1
#   SMTP_SSL=0          # implicit TLS, usually port 465
#   SMTP_FROM_NAME='Backup Bot'
#   SMTP_CC=person@example.com,other@example.com
#   SMTP_BCC=hidden@example.com
#   EMAIL_SUBJECT='fallback subject if template has no Subject header'
#   EMAIL_CONTENT_TYPE='text/plain; charset=utf-8'
#   SMTP_TIMEOUT=30
#
# Template file format:
#   Either a plain body file, or an RFC-style header block followed by a blank line:
#     Subject: Example subject
#     Content-Type: text/plain; charset=utf-8
#
#     Body text here.

set -euo pipefail

usage() {
  echo "Usage: $0 <ENV_FILE> <TEMPLATE_FILE>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
PYTHON=$(resolve_python) || exit 1
ENV_FILE=$1
TEMPLATE_FILE=$2

[[ -f "$ENV_FILE" ]] || { echo "ERROR: ENV_FILE '$ENV_FILE' not found." >&2; exit 66; }
[[ -f "$TEMPLATE_FILE" ]] || { echo "ERROR: TEMPLATE_FILE '$TEMPLATE_FILE' not found." >&2; exit 66; }

"$PYTHON" - "$SCRIPT_DIR" "$ENV_FILE" "$TEMPLATE_FILE" <<'PY'
import smtplib
import ssl
import sys
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from envutil import bool_env, load_config, split_list

ENV_FILE = Path(sys.argv[2])
TEMPLATE_FILE = Path(sys.argv[3])


def parse_template(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    # Header mode only if the first nonempty line looks like Header: value and
    # there is a blank line separating headers and body.
    if "\n\n" in text:
        head, body = text.split("\n\n", 1)
        header_lines = head.splitlines()
        if header_lines and all((not h.strip()) or (":" in h and not h.startswith((" ", "\t"))) for h in header_lines):
            headers = {}
            for h in header_lines:
                if not h.strip():
                    continue
                k, v = h.split(":", 1)
                headers[k.strip().lower()] = v.strip()
            return headers, body
    return {}, text


env = load_config(ENV_FILE)

required = ["SMTP_HOST", "SMTP_FROM", "SMTP_TO"]
missing = [k for k in required if not env.get(k)]
if missing:
    raise SystemExit("ERROR: Missing required .env variables: " + ", ".join(missing))
if bool(env.get("SMTP_USER", "")) != bool(env.get("SMTP_PASSWORD", "")):
    raise SystemExit("ERROR: SMTP_USER and SMTP_PASSWORD must be set together.")

headers, body = parse_template(TEMPLATE_FILE)
subject = headers.get("subject") or env.get("EMAIL_SUBJECT")
if not subject:
    raise SystemExit("ERROR: No subject found. Set EMAIL_SUBJECT or add 'Subject:' to the template.")

content_type = headers.get("content-type") or env.get("EMAIL_CONTENT_TYPE", "text/plain; charset=utf-8")
maintype, _, subtype_full = content_type.partition("/")
subtype = subtype_full.split(";", 1)[0].strip() if subtype_full else "plain"
if not maintype:
    maintype = "text"

from_addr = env["SMTP_FROM"]
from_name = env.get("SMTP_FROM_NAME", "")
to_addrs = split_list(env.get("SMTP_TO", ""))
cc_addrs = split_list(env.get("SMTP_CC", ""))
bcc_addrs = split_list(env.get("SMTP_BCC", ""))
all_rcpts = to_addrs + cc_addrs + bcc_addrs

msg = EmailMessage()
msg["Date"] = formatdate(localtime=True)
msg["Message-ID"] = make_msgid()
msg["Subject"] = subject
msg["From"] = formataddr((from_name, from_addr)) if from_name else from_addr
msg["To"] = ", ".join(to_addrs)
if cc_addrs:
    msg["Cc"] = ", ".join(cc_addrs)

if maintype.lower() == "text":
    msg.set_content(body, subtype=subtype or "plain", charset="utf-8")
else:
    msg.set_content(body)

host = env["SMTP_HOST"]
port = int(env.get("SMTP_PORT") or (465 if bool_env(env, "SMTP_SSL", False) else 587))
timeout = int(env.get("SMTP_TIMEOUT", "30"))
use_ssl = bool_env(env, "SMTP_SSL", False)
use_tls = bool_env(env, "SMTP_TLS", not use_ssl)
user = env.get("SMTP_USER", "")
password = env.get("SMTP_PASSWORD", "")

context = ssl.create_default_context()
if use_ssl:
    smtp = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
else:
    smtp = smtplib.SMTP(host, port, timeout=timeout)

try:
    smtp.ehlo()
    if use_tls and not use_ssl:
        smtp.starttls(context=context)
        smtp.ehlo()
    if user:
        smtp.login(user, password)
    smtp.send_message(msg, from_addr=from_addr, to_addrs=all_rcpts)
finally:
    try:
        smtp.quit()
    except Exception:
        pass

print(f"Email sent to {', '.join(to_addrs)}")
PY
