#!/usr/bin/env python3
"""Print validated, shell-safe wakeup configuration assignments."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from envutil import ConfigError, load_config, shell_exports


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("env_file")
    parser.add_argument("--root", help="Project root for dependent defaults")
    parser.add_argument(
        "--require-channel",
        action="store_true",
        help="require at least one complete channel unless dry-run is enabled",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="allow credential-free dry-run configuration",
    )
    args = parser.parse_args()

    path = Path(args.env_file)
    if not path.is_file():
        print(f"ERROR: ENV_FILE '{path}' not found.", file=sys.stderr)
        return 66
    try:
        config = load_config(
            path,
            root_dir=Path(args.root) if args.root else None,
            require_channel=args.require_channel,
            dry_run=args.dry_run,
        )
    except (ConfigError, OSError) as exc:
        print(f"ERROR: invalid configuration: {exc}", file=sys.stderr)
        return 78
    sys.stdout.write(shell_exports(config))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
