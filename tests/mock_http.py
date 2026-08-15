#!/usr/bin/env python3
"""Local HTTP mock for Telegram, Twilio, and public-IP tests."""

from __future__ import annotations

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PRESETS = {
    "telegram-ok": {
        "status": 200,
        "body": json.dumps({"ok": True, "result": {"message_id": 1}}),
        "content_type": "application/json",
    },
    "telegram-http": {
        "status": 403,
        "body": "forbidden token=telegram-bot-token",
        "content_type": "text/plain",
    },
    "telegram-timeout": {"sleep": 8, "status": 200, "body": "{}"},
    "twilio-ok": {
        "status": 201,
        "body": json.dumps({"sid": "SMtest", "status": "queued"}),
        "content_type": "application/json",
    },
    "twilio-http": {
        "status": 500,
        "body": "twilio exploded twilio-secret Authorization Basic QUNleGFtcGxlOnR3aWxpby1zZWNyZXQ=",
        "content_type": "text/plain",
    },
    "twilio-timeout": {"sleep": 8, "status": 201, "body": "{}"},
    "ip-ok": {"status": 200, "body": "203.0.113.10\n", "content_type": "text/plain"},
    "ip-fail": {"status": 503, "body": "", "content_type": "text/plain"},
}


class Handler(BaseHTTPRequestHandler):
    preset: dict
    request_log: Path

    def log_message(self, _format: str, *_args) -> None:
        return

    def _record(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        line = (
            f"{self.command} {self.path} "
            f"auth={self.headers.get('Authorization', '')} "
            f"body={body.decode('utf-8', 'replace')}\n"
        )
        self.request_log.parent.mkdir(parents=True, exist_ok=True)
        with self.request_log.open("a", encoding="utf-8") as handle:
            handle.write(line)

    def _reply(self) -> None:
        delay = float(self.preset.get("sleep", 0) or 0)
        if delay:
            time.sleep(delay)
        status = int(self.preset.get("status", 200))
        body = str(self.preset.get("body", "")).encode("utf-8")
        self.send_response(status)
        self.send_header(
            "Content-Type", self.preset.get("content_type", "text/plain")
        )
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:
        self._record()
        self._reply()

    def do_POST(self) -> None:
        self._record()
        self._reply()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preset", required=True, choices=sorted(PRESETS))
    parser.add_argument("--output", required=True, help="Write PORT= and request log path")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    output = Path(args.output)
    request_log = output.with_suffix(output.suffix + ".requests")
    Handler.preset = PRESETS[args.preset]
    Handler.request_log = request_log
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = server.server_address[1]
    output.write_bytes(
        f"PORT={port}\nREQUESTS={request_log}\nPRESET={args.preset}\n".encode("utf-8")
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
