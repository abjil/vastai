#!/usr/bin/env python3
"""Redact credentials and bound provider-controlled diagnostic output."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from envutil import ConfigError, parse_env, sanitize_detail


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", required=True, help="wakeup.env path")
    parser.add_argument("--limit", required=True, type=int)
    args = parser.parse_args()

    if args.limit <= 0:
        print("ERROR: --limit must be greater than zero", file=sys.stderr)
        return 64

    try:
        config = parse_env(Path(args.env))
    except (ConfigError, OSError) as exc:
        print(f"ERROR: cannot sanitize output: {exc}", file=sys.stderr)
        return 78

    text = sys.stdin.read()
    sys.stdout.write(sanitize_detail(text, config=config, limit=args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
