#!/usr/bin/env python3
"""Template rendering and unresolved-placeholder detection."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "bin"
ROOT = Path(__file__).resolve().parents[1]
RENDER = BIN / "render_template.py"

sys.path.insert(0, str(BIN))
from render_template import render  # noqa: E402


class RenderTests(unittest.TestCase):
    def test_render_function_leaves_unknown_tokens(self) -> None:
        text = render("Hello {{NAME}} {{MISSING}}", {"NAME": "vast"})
        self.assertEqual(text, "Hello vast {{MISSING}}")

    def test_alert_email_template(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "out.txt"
            subprocess.run(
                [
                    sys.executable,
                    str(RENDER),
                    "--env",
                    str(ROOT / "templates" / "wakeup.env.example"),
                    str(ROOT / "templates" / "alert-email.txt"),
                    str(dest),
                    "HOSTNAME=testhost",
                    "VAST_LABEL=C.test",
                    "PUBLIC_IP=1.2.3.4",
                    "STARTED_AT=2026-01-01 00:00:00 UTC",
                    "NOW=2026-01-01 00:01:00 UTC",
                    "ALERT_NUM=1",
                    "UPTIME=1h 00m 00s",
                    "ACK_FILE=/tmp/ACK",
                    "ACK_HINT=touch /tmp/ACK",
                    "ELAPSED=0h 01m 00s",
                    "KIND=alert",
                ],
                check=True,
            )
            text = dest.read_text(encoding="utf-8")
            self.assertIn("testhost", text)
            self.assertIn("Subject:", text)
            self.assertIn("1.2.3.4", text)

    def test_strict_unresolved_placeholders(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "tpl.txt"
            dest = Path(tmp) / "out.txt"
            src.write_text("Hello {{NAME}} {{MISSING}}\n", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(RENDER),
                    "--strict",
                    str(src),
                    str(dest),
                    "NAME=vast",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 65)
            self.assertIn("MISSING", completed.stderr)
            completed_ok = subprocess.run(
                [
                    sys.executable,
                    str(RENDER),
                    "--strict",
                    str(src),
                    str(dest),
                    "NAME=vast",
                    "MISSING=gone",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed_ok.returncode, 0)
            self.assertEqual(dest.read_text(encoding="utf-8"), "Hello vast gone\n")


if __name__ == "__main__":
    unittest.main()
