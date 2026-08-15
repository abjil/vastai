#!/usr/bin/env python3
"""Substitute {{PLACEHOLDER}} tokens in a text template."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from envutil import parse_env

_TOKEN = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")


def render(text: str, mapping: dict[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        key = match.group(1)
        return mapping.get(key, match.group(0))

    return _TOKEN.sub(repl, text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template")
    parser.add_argument("output")
    parser.add_argument("--env", action="append", default=[], help="KEY=VALUE env file (repeatable)")
    parser.add_argument("assignments", nargs="*", help="KEY=VALUE overrides")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail when the rendered text still contains {{PLACEHOLDER}} tokens",
    )
    args = parser.parse_args()

    mapping: dict[str, str] = {}
    for env_path in args.env:
        mapping.update(parse_env(Path(env_path)))
    for item in args.assignments:
        if "=" not in item:
            print(f"ERROR: not KEY=VALUE: {item}", file=sys.stderr)
            return 64
        key, val = item.split("=", 1)
        mapping[key] = val

    src = Path(args.template)
    dest = Path(args.output)
    text = src.read_text(encoding="utf-8")
    dest.parent.mkdir(parents=True, exist_ok=True)
    rendered = render(text, mapping)
    dest.write_text(rendered, encoding="utf-8")
    if args.strict:
        leftover = sorted(set(_TOKEN.findall(rendered)))
        if leftover:
            print(
                "ERROR: unresolved placeholders: " + ", ".join(leftover),
                file=sys.stderr,
            )
            return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
