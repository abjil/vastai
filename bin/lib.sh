# Shared helpers. Source from other scripts in this directory.
# shellcheck shell=bash

resolve_python() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  echo "ERROR: python3 (or python) is required." >&2
  return 1
}
