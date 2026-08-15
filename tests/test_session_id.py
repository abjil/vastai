#!/usr/bin/env python3
"""Session identity, ACK binding, PID ownership, and startup locks."""

from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[1] / "bin"
sys.path.insert(0, str(BIN))

from session_id import (  # noqa: E402
    ProcessIdentity,
    ack_matches,
    acquire_lock,
    already_acked,
    atomic_write,
    clear_pid_file,
    command_matches_script,
    daemon_status,
    derive_fingerprint,
    ensure_fallback_id,
    ensure_session_file,
    lock_is_stale,
    mark_acked,
    parse_identity_text,
    release_lock,
    resolve_session_id,
    token_from_fingerprint,
    write_ack,
    write_pid_file,
)


def write_fake_proc(root: Path, boot_id: str, namespace: str, starttime: str) -> None:
    boot = root / "sys" / "kernel" / "random" / "boot_id"
    boot.parent.mkdir(parents=True, exist_ok=True)
    boot.write_text(boot_id + "\n", encoding="utf-8")
    ns_path = root / "1" / "ns" / "pid"
    ns_path.parent.mkdir(parents=True, exist_ok=True)
    ns_path.write_text(namespace + "\n", encoding="utf-8")
    after = ["S"] + ["0"] * 18 + [str(starttime)] + ["0"] * 5
    (root / "1" / "stat").write_text(f"1 (init) {' '.join(after)}\n", encoding="utf-8")


class SessionIdTests(unittest.TestCase):
    def test_derived_and_fallback_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            proc_a = tmp_path / "proc-a"
            proc_b = tmp_path / "proc-b"
            write_fake_proc(proc_a, "boot-1", "pid:[111]", "1000")
            write_fake_proc(proc_b, "boot-1", "pid:[111]", "2000")
            token_a1, source_a = resolve_session_id(proc_root=proc_a)
            token_a2, _ = resolve_session_id(proc_root=proc_a)
            token_b, source_b = resolve_session_id(proc_root=proc_b)
            self.assertEqual(source_a, "derived")
            self.assertEqual(source_b, "derived")
            self.assertEqual(token_a1, token_a2)
            self.assertNotEqual(token_a1, token_b)
            self.assertEqual(
                token_a1, token_from_fingerprint(derive_fingerprint(proc_a) or "")
            )

            fallback = tmp_path / "run"
            first, source_f = resolve_session_id(
                proc_root=tmp_path / "missing-proc",
                fallback_dir=fallback,
            )
            second, _ = resolve_session_id(
                proc_root=tmp_path / "missing-proc",
                fallback_dir=fallback,
            )
            self.assertEqual(source_f, "fallback")
            self.assertEqual(first, second)
            self.assertEqual(first, ensure_fallback_id(fallback))
            explicit, source_e = resolve_session_id(explicit="sess-injected")
            self.assertEqual((source_e, explicit), ("explicit", "sess-injected"))

    def test_ack_and_final_marker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            session_file = tmp_path / "session.id"
            ensure_session_file(session_file, "sess-current")
            ack_file = tmp_path / "ACK"
            write_ack(ack_file, "sess-current")
            self.assertTrue(ack_matches(ack_file, "sess-current"))
            self.assertFalse(ack_matches(ack_file, "sess-other"))
            empty = tmp_path / "empty-ACK"
            empty.write_text("", encoding="utf-8")
            self.assertFalse(ack_matches(empty, "sess-current"))
            self.assertTrue(ack_matches(empty, "sess-current", legacy_empty=True))
            acked = tmp_path / "acked.session"
            self.assertFalse(already_acked(acked, "sess-current"))
            mark_acked(acked, "sess-current")
            self.assertTrue(already_acked(acked, "sess-current"))

    def test_pid_ownership_and_lock(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            dest = tmp_path / "atomic.txt"
            atomic_write(dest, "one")
            atomic_write(dest, "two")
            self.assertEqual(dest.read_text(encoding="utf-8"), "two\n")

            ident = parse_identity_text("12345")
            self.assertIsNotNone(ident)
            self.assertEqual(ident.pid, 12345)
            rich = ProcessIdentity(
                pid=9, starttime="44", session="sess", script="/x/wakeup.sh"
            )
            pid_file = tmp_path / "wakeup.pid"
            write_pid_file(pid_file, rich)
            self.assertFalse(clear_pid_file(pid_file, 8))
            self.assertTrue(pid_file.is_file())
            self.assertTrue(clear_pid_file(pid_file, 9, "44"))
            self.assertFalse(pid_file.exists())

            script = tmp_path / "bin" / "wakeup.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            self.assertTrue(command_matches_script(["bash", str(script)], script))
            self.assertFalse(command_matches_script(["sleep", "30"], script))
            win_script = Path("E:/Dev/_code/abjil/vastai/bin/wakeup.sh")
            self.assertTrue(
                command_matches_script(
                    ["bash", "/e/Dev/_code/abjil/vastai/bin/wakeup.sh"],
                    win_script,
                )
            )
            stale = tmp_path / "stale.pid"
            write_pid_file(
                stale,
                ProcessIdentity(
                    pid=os.getpid(),
                    starttime="1",
                    session="old",
                    script="/not/wakeup.sh",
                ),
            )
            self.assertEqual(daemon_status(stale, script, "current"), "stale")

            lock_dir = tmp_path / "wakeup.lock"
            self.assertTrue(
                acquire_lock(lock_dir, pid=os.getpid(), session="sess", timeout=1)
            )
            self.assertFalse(lock_is_stale(lock_dir))
            self.assertFalse(
                acquire_lock(
                    lock_dir, pid=os.getpid() + 1, session="sess", timeout=0.2
                )
            )
            self.assertTrue(release_lock(lock_dir, os.getpid()))
            dead_lock = tmp_path / "dead.lock"
            dead_lock.mkdir()
            (dead_lock / "meta").write_text(
                "pid=999999\nstarttime=1\nsession=x\n", encoding="utf-8"
            )
            time.sleep(0.05)
            self.assertTrue(lock_is_stale(dead_lock))


if __name__ == "__main__":
    unittest.main()
