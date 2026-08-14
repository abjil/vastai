"""Shared KEY=VALUE .env parser for Vast.ai wakeup scripts."""

from __future__ import annotations

import re
import shlex
from pathlib import Path


_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    text = path.read_text(encoding="utf-8")
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if not _KEY_RE.match(key):
            continue
        try:
            parts = shlex.split(val, posix=True)
            val = parts[0] if parts else ""
        except ValueError:
            val = val.strip('"').strip("'")
        env[key] = val
    return env


def bool_env(env: dict[str, str], key: str, default: bool = False) -> bool:
    value = str(env.get(key, ""))
    if value == "":
        return default
    return value.strip().lower() in {"1", "yes", "true", "on"}


def split_list(value: str) -> list[str]:
    if not value:
        return []
    return [x.strip() for x in value.replace(";", ",").split(",") if x.strip()]


def shell_exports(env: dict[str, str]) -> str:
    lines = []
    for key, val in env.items():
        if not _KEY_RE.match(key):
            continue
        lines.append(f"{key}={shlex.quote(val)}")
    return "\n".join(lines) + ("\n" if lines else "")
