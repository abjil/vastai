#!/usr/bin/env bash
#
# pin_revision.sh — fetch and detach a reviewed git revision.
#
# Usage:
#   pin_revision.sh [--repo DIR] [--verify-only] REVISION
#   WAKEUP_REVISION=<tag-or-commit> pin_revision.sh [--repo DIR]
#
# Fails if the revision cannot be obtained. Does not continue on a stale
# checkout after a failed fetch.

set -euo pipefail

REPO="."
VERIFY_ONLY=0
REVISION=""

usage() {
  cat <<'EOF'
Usage: pin_revision.sh [--repo DIR] [--verify-only] REVISION

  --repo DIR       Git checkout to pin (default: current directory)
  --verify-only    Require HEAD to already match REVISION; do not fetch
  REVISION         Reviewed tag, commit, or other git object name

WAKEUP_REVISION is used when REVISION is omitted.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO=$2
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      REVISION=$1
      shift
      ;;
  esac
done

REVISION="${REVISION:-${WAKEUP_REVISION:-}}"
if [[ -z "$REVISION" ]]; then
  echo "ERROR: WAKEUP_REVISION is required (reviewed tag, commit, or ref)." >&2
  echo "Refusing to start from an unpinned moving branch." >&2
  exit 64
fi

if [[ ! -d "$REPO/.git" && ! -f "$REPO/.git" ]]; then
  echo "ERROR: $REPO is not a git checkout. Install a reviewed clone first." >&2
  exit 66
fi

git_in() {
  git -C "$REPO" "$@"
}

resolve_oid() {
  git_in rev-parse --verify "${1}^{commit}" 2>/dev/null
}

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  want=$(resolve_oid "$REVISION") || {
    echo "ERROR: cannot resolve reviewed revision $REVISION in $REPO" >&2
    exit 1
  }
  have=$(git_in rev-parse HEAD)
  if [[ "$want" != "$have" ]]; then
    echo "ERROR: $REPO HEAD is $have, not $REVISION ($want)" >&2
    exit 1
  fi
  printf 'verified %s\n' "$want"
  exit 0
fi

oid=$(resolve_oid "$REVISION" || true)
if [[ -z "$oid" ]]; then
  fetched=0
  if git_in fetch --tags origin "$REVISION"; then
    fetched=1
  elif git_in fetch origin "$REVISION"; then
    fetched=1
  elif git_in fetch origin; then
    fetched=1
  fi
  oid=$(resolve_oid "$REVISION" || true)
  if [[ -z "$oid" ]]; then
    if [[ "$fetched" -eq 0 ]]; then
      echo "ERROR: could not fetch reviewed revision $REVISION" >&2
    else
      echo "ERROR: fetched origin but could not resolve $REVISION" >&2
    fi
    echo "Refusing to continue with an unpinned or stale checkout." >&2
    exit 1
  fi
fi

git_in checkout --detach "$oid"
printf 'detached at %s (%s)\n' "$oid" "$REVISION"
