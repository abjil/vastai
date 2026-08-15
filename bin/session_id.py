#!/usr/bin/env python3
"""Container-session identity, process identity, and atomic lifecycle files.

Session tokens are derived from host boot ID, PID-namespace identity, and
PID 1 start time. When those inputs are missing, an atomically created
random token is stored in an ephemeral directory such as /run.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


_PID_LINE_RE = re.compile(r"^[0-9]+$")
_DEFAULT_PROC_ROOT = Path("/proc")
_FALLBACK_CANDIDATES = (
    Path("/run/vastai-wakeup"),
    Path("/tmp/vastai-wakeup"),
)


class LifecycleError(ValueError):
    """Raised when a lifecycle file or process identity is unusable."""


def atomic_write(path: Path, content: str) -> None:
    """Replace *path* with *content* using a same-directory rename."""

    dest = Path(path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    text = content if content.endswith("\n") else content + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=f".{dest.name}.", dir=str(dest.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, dest)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def read_stripped(path: Path) -> str:
    return Path(path).read_text(encoding="utf-8").strip()


def _read_optional(path: Path) -> Optional[str]:
    try:
        return read_stripped(path)
    except OSError:
        return None


def parse_starttime(stat_path: Path) -> Optional[str]:
    try:
        text = Path(stat_path).read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        after = text.rsplit(")", 1)[1].split()
        return after[19]
    except (IndexError, ValueError):
        return None


def pid_namespace_id(proc_root: Path) -> Optional[str]:
    ns_path = Path(proc_root) / "1" / "ns" / "pid"
    try:
        return os.readlink(ns_path)
    except OSError:
        return _read_optional(ns_path)


def derive_fingerprint(proc_root: Path) -> Optional[str]:
    boot_id = _read_optional(Path(proc_root) / "sys" / "kernel" / "random" / "boot_id")
    namespace = pid_namespace_id(Path(proc_root))
    starttime = parse_starttime(Path(proc_root) / "1" / "stat")
    if boot_id and namespace and starttime:
        return f"{boot_id}|{namespace}|{starttime}"
    return None


def token_from_fingerprint(fingerprint: str) -> str:
    return hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()[:32]


def default_fallback_dir() -> Path:
    for candidate in _FALLBACK_CANDIDATES:
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            probe = candidate / f".wakeup-write-test.{os.getpid()}"
            probe.write_text("1", encoding="utf-8")
            probe.unlink()
            return candidate
        except OSError:
            continue
    return Path(tempfile.gettempdir()) / "vastai-wakeup"


def ensure_fallback_id(fallback_dir: Path) -> str:
    dest = Path(fallback_dir) / "session.id"
    dest.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(20):
        existing = _read_optional(dest)
        if existing:
            return existing
        token = secrets.token_hex(16)
        try:
            fd = os.open(str(dest), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            continue
        try:
            os.write(fd, (token + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        return token
    existing = _read_optional(dest)
    if existing:
        return existing
    raise LifecycleError(f"could not create fallback session id in {fallback_dir}")


def resolve_session_id(
    *,
    explicit: Optional[str] = None,
    proc_root: Optional[Path] = None,
    fallback_dir: Optional[Path] = None,
) -> tuple[str, str]:
    """Return ``(token, source)`` with source explicit, derived, or fallback."""

    if explicit and explicit.strip():
        return explicit.strip(), "explicit"
    fingerprint = derive_fingerprint(Path(proc_root or _DEFAULT_PROC_ROOT))
    if fingerprint:
        return token_from_fingerprint(fingerprint), "derived"
    return ensure_fallback_id(Path(fallback_dir or default_fallback_dir())), "fallback"


def ensure_session_file(path: Path, token: str) -> str:
    dest = Path(path)
    current = _read_optional(dest)
    if current == token:
        return token
    atomic_write(dest, token)
    return token


def ack_matches(ack_path: Path, token: str, *, legacy_empty: bool = False) -> bool:
    if not Path(ack_path).is_file():
        return False
    try:
        content = read_stripped(ack_path)
    except OSError:
        return False
    if not content:
        return legacy_empty
    return content == token.strip()


def write_ack(ack_path: Path, token: str) -> None:
    if not token.strip():
        raise LifecycleError("refusing to write an empty ACK token")
    atomic_write(Path(ack_path), token.strip())


def already_acked(acked_path: Path, token: str) -> bool:
    current = _read_optional(Path(acked_path))
    return bool(current) and current == token.strip()


def mark_acked(acked_path: Path, token: str) -> None:
    atomic_write(Path(acked_path), token.strip())


def _norm_path(value: str) -> str:
    text = value.replace("\\", "/").rstrip("/").lower()
    # Git Bash / MSYS: /e/foo and e:/foo are the same path.
    if len(text) >= 3 and text[0] == "/" and text[1].isalpha() and text[2] == "/":
        text = f"{text[1]}:{text[2:]}"
    return text


@dataclass
class ProcessIdentity:
    pid: int
    starttime: str = ""
    session: str = ""
    script: str = ""

    def to_text(self) -> str:
        return (
            f"pid={self.pid}\n"
            f"starttime={self.starttime}\n"
            f"session={self.session}\n"
            f"script={self.script}\n"
        )


def parse_identity_text(text: str) -> Optional[ProcessIdentity]:
    stripped = text.strip()
    if not stripped:
        return None
    if _PID_LINE_RE.fullmatch(stripped):
        return ProcessIdentity(pid=int(stripped))
    data: dict[str, str] = {}
    for line in stripped.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    pid_text = data.get("pid", "")
    if not _PID_LINE_RE.fullmatch(pid_text):
        return None
    return ProcessIdentity(
        pid=int(pid_text),
        starttime=data.get("starttime", ""),
        session=data.get("session", ""),
        script=data.get("script", ""),
    )


def read_pid_file(path: Path) -> Optional[ProcessIdentity]:
    try:
        return parse_identity_text(Path(path).read_text(encoding="utf-8"))
    except OSError:
        return None


def _posix_kill(pid: int, spec: str) -> bool:
    try:
        completed = subprocess.run(
            ["kill", spec, str(pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return False
    return completed.returncode == 0


def pid_exists(pid: int, proc_root: Optional[Path] = None) -> bool:
    if pid <= 0:
        return False
    root = Path(proc_root or _DEFAULT_PROC_ROOT)
    if (root / str(pid)).is_dir():
        return True
    # Native Windows Python cannot see MSYS PIDs through os.kill or /proc.
    if not root.exists() and _posix_kill(pid, "-0"):
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return _posix_kill(pid, "-0")
    return True


def signal_process(pid: int, sig: int, proc_root: Optional[Path] = None) -> bool:
    root = Path(proc_root or _DEFAULT_PROC_ROOT)
    spec = {signal.SIGTERM: "-TERM", signal.SIGKILL: "-KILL"}.get(sig, f"-{int(sig)}")
    if not root.exists():
        return _posix_kill(pid, spec)
    try:
        os.kill(pid, sig)
        return True
    except OSError:
        return _posix_kill(pid, spec)


def read_starttime(pid: int, proc_root: Path) -> str:
    return parse_starttime(Path(proc_root) / str(pid) / "stat") or ""


def read_cmdline(pid: int, proc_root: Path) -> list[str]:
    cmdline_path = Path(proc_root) / str(pid) / "cmdline"
    try:
        raw = cmdline_path.read_bytes()
    except OSError:
        raw = b""
    if raw:
        parts = [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
        if parts:
            return parts
    try:
        output = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "args="],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return []
    if not output:
        return []
    try:
        return shlex.split(output)
    except ValueError:
        return output.split()


def command_matches_script(command: list[str], script_path: Path) -> bool:
    if not command:
        return False
    try:
        wanted = _norm_path(str(Path(script_path).resolve()))
    except OSError:
        wanted = _norm_path(str(script_path))
    for part in command:
        if not part:
            continue
        candidate = _norm_path(part)
        try:
            resolved = _norm_path(str(Path(part).resolve()))
        except OSError:
            resolved = candidate
        if resolved == wanted or candidate == wanted:
            return True
        if candidate.endswith(wanted) or resolved.endswith(wanted):
            return True
    return False


def current_identity(
    pid: int,
    *,
    session: str,
    script: Path,
    proc_root: Optional[Path] = None,
) -> ProcessIdentity:
    root = Path(proc_root or _DEFAULT_PROC_ROOT)
    return ProcessIdentity(
        pid=pid,
        starttime=read_starttime(pid, root),
        session=session,
        script=str(Path(script)),
    )


def write_pid_file(path: Path, identity: ProcessIdentity) -> None:
    atomic_write(Path(path), identity.to_text())


def is_our_daemon(
    identity: ProcessIdentity,
    script_path: Path,
    proc_root: Optional[Path] = None,
) -> bool:
    root = Path(proc_root or _DEFAULT_PROC_ROOT)
    if not pid_exists(identity.pid, root):
        return False
    live_start = read_starttime(identity.pid, root)
    if identity.starttime and live_start and identity.starttime != live_start:
        return False
    command = read_cmdline(identity.pid, root)
    if command_matches_script(command, Path(script_path)):
        return True
    if command:
        return False
    if not identity.script:
        return False
    try:
        return _norm_path(str(Path(identity.script).resolve())) == _norm_path(
            str(Path(script_path).resolve())
        )
    except OSError:
        return _norm_path(identity.script) == _norm_path(str(script_path))


def daemon_status(
    pid_path: Path,
    script_path: Path,
    session: str,
    proc_root: Optional[Path] = None,
) -> str:
    """Return missing, stale, running, or running-other-session."""

    identity = read_pid_file(Path(pid_path))
    if identity is None:
        return "missing"
    if not is_our_daemon(identity, Path(script_path), proc_root):
        return "stale"
    if identity.session and session and identity.session != session:
        return "running-other-session"
    return "running"


def clear_pid_file(
    path: Path,
    pid: int,
    starttime: str = "",
) -> bool:
    identity = read_pid_file(Path(path))
    if identity is None:
        return False
    if identity.pid != pid:
        return False
    if starttime and identity.starttime and identity.starttime != starttime:
        return False
    try:
        Path(path).unlink()
    except OSError:
        return False
    return True


def _read_kv(path: Path) -> dict[str, str]:
    text = _read_optional(path)
    if not text:
        return {}
    data: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def lock_is_stale(lock_dir: Path, proc_root: Optional[Path] = None) -> bool:
    root = Path(proc_root or _DEFAULT_PROC_ROOT)
    meta = _read_kv(Path(lock_dir) / "meta")
    if not meta:
        try:
            return time.time() - Path(lock_dir).stat().st_mtime > 5
        except OSError:
            return True
    try:
        pid = int(meta.get("pid", "0"))
    except ValueError:
        return True
    if not pid_exists(pid, root):
        return True
    stored_start = meta.get("starttime", "")
    live_start = read_starttime(pid, root)
    if stored_start and live_start and stored_start != live_start:
        return True
    return False


def acquire_lock(
    lock_dir: Path,
    *,
    pid: int,
    session: str,
    timeout: float = 30.0,
    proc_root: Optional[Path] = None,
) -> bool:
    dest = Path(lock_dir)
    dest.parent.mkdir(parents=True, exist_ok=True)
    root = Path(proc_root or _DEFAULT_PROC_ROOT)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            dest.mkdir()
        except FileExistsError:
            if lock_is_stale(dest, root):
                shutil.rmtree(dest, ignore_errors=True)
                continue
            time.sleep(0.05)
            continue
        starttime = read_starttime(pid, root) or str(int(time.time()))
        atomic_write(
            dest / "meta",
            (
                f"pid={pid}\n"
                f"starttime={starttime}\n"
                f"session={session}\n"
                f"created={int(time.time())}\n"
            ),
        )
        return True
    return False


def release_lock(lock_dir: Path, pid: int) -> bool:
    dest = Path(lock_dir)
    if not dest.is_dir():
        return False
    meta = _read_kv(dest / "meta")
    try:
        owner = int(meta.get("pid", "0"))
    except ValueError:
        owner = 0
    if owner and owner != pid:
        return False
    shutil.rmtree(dest, ignore_errors=True)
    return True


def stop_daemon(
    pid_path: Path,
    script_path: Path,
    *,
    timeout: float = 5.0,
    proc_root: Optional[Path] = None,
) -> str:
    """TERM a verified daemon, wait, then KILL only that process."""

    identity = read_pid_file(Path(pid_path))
    if identity is None or not is_our_daemon(identity, Path(script_path), proc_root):
        return "not-ours-or-dead"
    if not signal_process(identity.pid, signal.SIGTERM, proc_root):
        return "not-ours-or-dead"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not is_our_daemon(identity, Path(script_path), proc_root):
            return "stopped"
        time.sleep(0.1)
    if is_our_daemon(identity, Path(script_path), proc_root):
        signal_process(identity.pid, signal.SIGKILL, proc_root)
        time.sleep(0.1)
        return "killed"
    return "stopped"


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--proc-root", default=str(_DEFAULT_PROC_ROOT))
    parser.add_argument("--fallback-dir")
    parser.add_argument("--session", default="")


def _resolve_from_args(args: argparse.Namespace) -> tuple[str, str]:
    return resolve_session_id(
        explicit=args.session or None,
        proc_root=Path(args.proc_root),
        fallback_dir=Path(args.fallback_dir) if args.fallback_dir else None,
    )


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    derive = sub.add_parser("derive", help="print the current session token")
    _add_common(derive)

    ensure = sub.add_parser("ensure", help="write session.id and print the token")
    ensure.add_argument("path")
    _add_common(ensure)

    read_cmd = sub.add_parser("read", help="print a stored token")
    read_cmd.add_argument("path")

    write_cmd = sub.add_parser("write", help="atomically write text to a file")
    write_cmd.add_argument("path")
    write_cmd.add_argument("content")

    ack_write = sub.add_parser("ack-write", help="copy a session token into ACK")
    ack_write.add_argument("ack_path")
    ack_write.add_argument("session_path")
    _add_common(ack_write)

    ack_match = sub.add_parser("ack-matches", help="exit 0 when ACK matches")
    ack_match.add_argument("ack_path")
    ack_match.add_argument("token")
    ack_match.add_argument("--legacy-empty", action="store_true")

    already = sub.add_parser("already-acked", help="exit 0 when final ack was sent")
    already.add_argument("path")
    already.add_argument("token")

    mark = sub.add_parser("mark-acked", help="record a sent final acknowledgment")
    mark.add_argument("path")
    mark.add_argument("token")

    write_pid = sub.add_parser("write-pid", help="atomically publish process identity")
    write_pid.add_argument("path")
    write_pid.add_argument("--pid", type=int, required=True)
    write_pid.add_argument("--script", required=True)
    _add_common(write_pid)

    read_pid = sub.add_parser("read-pid", help="print a PID-file field")
    read_pid.add_argument("path")
    read_pid.add_argument("--field", default="pid")

    status = sub.add_parser("daemon-status", help="print daemon status")
    status.add_argument("path")
    status.add_argument("--script", required=True)
    _add_common(status)

    verify = sub.add_parser("verify-daemon", help="exit 0 when our daemon is live")
    verify.add_argument("path")
    verify.add_argument("--script", required=True)
    _add_common(verify)

    stop = sub.add_parser("stop-daemon", help="stop a verified wakeup daemon")
    stop.add_argument("path")
    stop.add_argument("--script", required=True)
    stop.add_argument("--timeout", type=float, default=5.0)
    _add_common(stop)

    clear = sub.add_parser("clear-pid", help="remove PID file if it still describes pid")
    clear.add_argument("path")
    clear.add_argument("--pid", type=int, required=True)
    clear.add_argument("--starttime", default="")

    acquire = sub.add_parser("acquire-lock", help="create an exclusive startup lock")
    acquire.add_argument("path")
    acquire.add_argument("--pid", type=int, required=True)
    acquire.add_argument("--timeout", type=float, default=30.0)
    _add_common(acquire)

    release = sub.add_parser("release-lock", help="remove a lock owned by pid")
    release.add_argument("path")
    release.add_argument("--pid", type=int, required=True)

    args = parser.parse_args(argv)
    proc_root = Path(getattr(args, "proc_root", _DEFAULT_PROC_ROOT))

    try:
        if args.command == "derive":
            token, _source = _resolve_from_args(args)
            print(token)
            return 0
        if args.command == "ensure":
            token, _source = _resolve_from_args(args)
            print(ensure_session_file(Path(args.path), token))
            return 0
        if args.command == "read":
            print(read_stripped(Path(args.path)))
            return 0
        if args.command == "write":
            atomic_write(Path(args.path), args.content)
            return 0
        if args.command == "ack-write":
            token, _source = _resolve_from_args(args)
            ensure_session_file(Path(args.session_path), token)
            write_ack(Path(args.ack_path), token)
            print(token)
            return 0
        if args.command == "ack-matches":
            return 0 if ack_matches(
                Path(args.ack_path), args.token, legacy_empty=args.legacy_empty
            ) else 1
        if args.command == "already-acked":
            return 0 if already_acked(Path(args.path), args.token) else 1
        if args.command == "mark-acked":
            mark_acked(Path(args.path), args.token)
            return 0
        if args.command == "write-pid":
            token, _source = _resolve_from_args(args)
            identity = current_identity(
                args.pid,
                session=token,
                script=Path(args.script),
                proc_root=proc_root,
            )
            write_pid_file(Path(args.path), identity)
            return 0
        if args.command == "read-pid":
            identity = read_pid_file(Path(args.path))
            if identity is None:
                return 1
            value = getattr(identity, args.field, "")
            print(value)
            return 0
        if args.command == "daemon-status":
            token, _source = _resolve_from_args(args)
            print(daemon_status(Path(args.path), Path(args.script), token, proc_root))
            return 0
        if args.command == "verify-daemon":
            token, _source = _resolve_from_args(args)
            return 0 if daemon_status(
                Path(args.path), Path(args.script), token, proc_root
            ) == "running" else 1
        if args.command == "stop-daemon":
            print(
                stop_daemon(
                    Path(args.path),
                    Path(args.script),
                    timeout=args.timeout,
                    proc_root=proc_root,
                )
            )
            return 0
        if args.command == "clear-pid":
            return 0 if clear_pid_file(
                Path(args.path), args.pid, args.starttime
            ) else 1
        if args.command == "acquire-lock":
            token, _source = _resolve_from_args(args)
            return 0 if acquire_lock(
                Path(args.path),
                pid=args.pid,
                session=token,
                timeout=args.timeout,
                proc_root=proc_root,
            ) else 1
        if args.command == "release-lock":
            return 0 if release_lock(Path(args.path), args.pid) else 1
    except (LifecycleError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    parser.error(f"unknown command {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
