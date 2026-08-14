#!/usr/bin/env python3
"""Print shell-safe KEY=VALUE assignments from an env file (stdout)."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from envutil import parse_env, shell_exports


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: dump_env_shell.py <ENV_FILE>", file=sys.stderr)
        return 64
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"ERROR: ENV_FILE '{path}' not found.", file=sys.stderr)
        return 66
    sys.stdout.write(shell_exports(parse_env(path)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
