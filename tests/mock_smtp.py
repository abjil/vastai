#!/usr/bin/env python3
"""Minimal local SMTP mock for adapter tests. No TLS."""

from __future__ import annotations

import argparse
import socket
import threading
import time
from pathlib import Path


class SMTPHandler(threading.Thread):
    def __init__(self, conn: socket.socket, preset: str, message_log: Path) -> None:
        super().__init__(daemon=True)
        self.conn = conn
        self.preset = preset
        self.message_log = message_log

    def send(self, line: str) -> None:
        self.conn.sendall((line + "\r\n").encode("ascii"))

    def run(self) -> None:
        try:
            if self.preset == "timeout":
                time.sleep(8)
                return
            self.send("220 mock.local SMTP")
            data_mode = False
            collected: list[str] = []
            while True:
                chunk = self.conn.recv(4096)
                if not chunk:
                    break
                text = chunk.decode("utf-8", "replace")
                if data_mode:
                    collected.append(text)
                    if "\r\n.\r\n" in "".join(collected) or "\n.\n" in "".join(collected):
                        self.message_log.parent.mkdir(parents=True, exist_ok=True)
                        self.message_log.write_text("".join(collected), encoding="utf-8")
                        if self.preset == "fail":
                            self.send("550 mocked delivery failure")
                        else:
                            self.send("250 OK")
                        data_mode = False
                        collected = []
                    continue
                for raw in text.splitlines():
                    command = raw.strip()
                    upper = command.upper()
                    if upper.startswith("EHLO") or upper.startswith("HELO"):
                        self.send("250-mock.local")
                        self.send("250 OK")
                    elif upper.startswith("MAIL") or upper.startswith("RCPT"):
                        self.send("250 OK")
                    elif upper == "DATA":
                        self.send("354 End data with <CR><LF>.<CR><LF>")
                        data_mode = True
                    elif upper == "QUIT":
                        self.send("221 Bye")
                        return
                    elif upper == "RSET":
                        self.send("250 OK")
                    else:
                        self.send("250 OK")
        except OSError:
            return
        finally:
            try:
                self.conn.close()
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preset", required=True, choices=("success", "fail", "timeout"))
    parser.add_argument("--output", required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    output = Path(args.output)
    message_log = output.with_suffix(output.suffix + ".message")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", args.port))
    sock.listen(5)
    port = sock.getsockname()[1]
    output.write_bytes(
        f"PORT={port}\nMESSAGE={message_log}\nPRESET={args.preset}\n".encode("utf-8")
    )

    try:
        while True:
            conn, _addr = sock.accept()
            SMTPHandler(conn, args.preset, message_log).start()
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
