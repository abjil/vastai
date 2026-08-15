#!/usr/bin/env python3
"""Configuration parsing, allowlisting, permissions, and sanitization."""

from __future__ import annotations

import base64
import sys
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "bin"
sys.path.insert(0, str(BIN))

from envutil import (  # noqa: E402
    ConfigError,
    load_config,
    parse_env,
    sanitize_detail,
    shell_exports,
)


ROOT = Path(__file__).resolve().parents[1]


class ParseEnvTests(unittest.TestCase):
    def _parse(self, text: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "wakeup.env"
            path.write_text(text, encoding="utf-8")
            return parse_env(path)

    def test_comments_and_export_prefix(self) -> None:
        env = self._parse(
            "# heading\n"
            "export INTERVAL_SEC=9\n"
            "\n"
            "INSTANCE_NAME=quoted\n"
        )
        self.assertEqual(env["INTERVAL_SEC"], "9")
        self.assertEqual(env["INSTANCE_NAME"], "quoted")
        self.assertNotIn("heading", env)

    def test_quoted_and_empty_values(self) -> None:
        env = self._parse(
            "INSTANCE_NAME='vast gpu'\n"
            "SMTP_CC=\n"
            'EMAIL_SUBJECT="hi there"\n'
        )
        self.assertEqual(env["INSTANCE_NAME"], "vast gpu")
        self.assertEqual(env["SMTP_CC"], "")
        self.assertEqual(env["EMAIL_SUBJECT"], "hi there")

    def test_malformed_lines(self) -> None:
        with self.assertRaises(ConfigError):
            self._parse("NOT_A_VALUE\n")
        with self.assertRaises(ConfigError):
            self._parse("1INVALID=1\n")
        with self.assertRaises(ConfigError):
            self._parse("INSTANCE_NAME='unterminated\n")


class LoadConfigTests(unittest.TestCase):
    def test_example_defaults(self) -> None:
        config = load_config(
            ROOT / "templates" / "wakeup.env.example",
            root_dir=ROOT,
            require_channel=True,
        )
        self.assertEqual(config["PUBLIC_IP_LOOKUP"], "0")
        self.assertTrue(config["SESSION_ID_FILE"].endswith("session.id"))

    def test_precedence_and_secret_isolation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            env_file = tmp_path / "wakeup.env"
            env_file.write_text(
                "\n".join(
                    [
                        f"DATA_DIR={tmp_path / 'file-data'}",
                        "INTERVAL_SEC=60",
                        "WAKEUP_DRY_RUN=1",
                        "SMTP_PASSWORD=file-secret",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            override_ack = tmp_path / "override-ACK"
            loaded = load_config(
                env_file,
                root_dir=ROOT,
                environ={
                    "DATA_DIR": str(tmp_path / "override-data"),
                    "ACK_FILE": str(override_ack),
                    "INTERVAL_SEC": "7",
                    "SMTP_PASSWORD": "process-secret",
                },
                dry_run=True,
            )
            self.assertEqual(loaded["DATA_DIR"], str(tmp_path / "override-data"))
            self.assertEqual(loaded["ACK_FILE"], str(override_ack))
            self.assertEqual(loaded["INTERVAL_SEC"], "7")
            self.assertEqual(loaded["SMTP_PASSWORD"], "file-secret")

    def test_invalid_and_partial_channels(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            invalid = tmp_path / "invalid.env"
            invalid.write_text("INTERVAL_SEC=zero\nWAKEUP_DRY_RUN=1\n", encoding="utf-8")
            with self.assertRaises(ConfigError) as exc:
                load_config(invalid, root_dir=ROOT, dry_run=True)
            self.assertIn("INTERVAL_SEC", str(exc.exception))

            partial = tmp_path / "partial.env"
            partial.write_text("TELEGRAM_BOT_TOKEN=token-only\n", encoding="utf-8")
            with self.assertRaises(ConfigError) as exc:
                load_config(partial, root_dir=ROOT, require_channel=True)
            self.assertIn("TELEGRAM_CHAT_ID", str(exc.exception))

            empty = tmp_path / "empty.env"
            empty.write_text("", encoding="utf-8")
            with self.assertRaises(ConfigError) as exc:
                load_config(empty, root_dir=ROOT, require_channel=True)
            self.assertIn("notification channel", str(exc.exception))
            load_config(empty, root_dir=ROOT, require_channel=True, dry_run=True)

    def test_allowlist_and_reserved_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            reserved = tmp_path / "reserved.env"
            reserved.write_text(
                "PATH=/tmp/evil\nHOME=/tmp/evil-home\nWAKEUP_DRY_RUN=1\n",
                encoding="utf-8",
            )
            with self.assertRaises(ConfigError) as exc:
                load_config(reserved, root_dir=ROOT, dry_run=True)
            self.assertIn("PATH", str(exc.exception))

            unknown = tmp_path / "unknown.env"
            unknown.write_text(
                "WAKEUP_DRY_RUN=1\nFOO_ARBITRARY=hacked\n",
                encoding="utf-8",
            )
            warnings: list[str] = []
            loaded = load_config(
                unknown, root_dir=ROOT, dry_run=True, warnings=warnings
            )
            self.assertNotIn("FOO_ARBITRARY", loaded)
            self.assertTrue(any("FOO_ARBITRARY" in item for item in warnings))
            exported = shell_exports(loaded)
            self.assertNotIn("FOO_ARBITRARY=", exported)
            self.assertNotIn("PATH=", exported)

    def test_secret_file_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            secret = Path(tmp) / "secret.env"
            secret.write_text(
                "WAKEUP_DRY_RUN=1\nSMTP_PASSWORD=file-secret\n",
                encoding="utf-8",
            )
            secret.chmod(0o644)
            with self.assertRaises(ConfigError) as exc:
                load_config(
                    secret, root_dir=ROOT, dry_run=True, enforce_permissions=True
                )
            self.assertIn("chmod 600", str(exc.exception))
            secret.chmod(0o600)
            if secret.stat().st_mode & 0o077 == 0:
                load_config(
                    secret, root_dir=ROOT, dry_run=True, enforce_permissions=True
                )


class SanitizeTests(unittest.TestCase):
    def test_redact_and_truncate(self) -> None:
        detail = "prefix secret-token " + ("x" * 3000)
        clean = sanitize_detail(detail, secrets=["secret-token"], limit=2048)
        self.assertNotIn("secret-token", clean)
        self.assertIn("[REDACTED]", clean)
        self.assertLessEqual(len(clean), 2048)

    def test_twilio_basic_auth(self) -> None:
        sid = "ACexample"
        token = "twilio-secret"
        basic = base64.b64encode(f"{sid}:{token}".encode("utf-8")).decode("ascii")
        clean = sanitize_detail(
            f"Authorization Basic {basic} token={token}",
            config={"TWILIO_ACCOUNT_SID": sid, "TWILIO_AUTH_TOKEN": token},
            limit=2048,
        )
        self.assertNotIn(token, clean)
        self.assertNotIn(basic, clean)
        self.assertIn("[REDACTED]", clean)


if __name__ == "__main__":
    unittest.main()
