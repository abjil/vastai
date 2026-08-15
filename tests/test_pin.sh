#!/usr/bin/env bash
# Pinned WAKEUP_REVISION fetch/detach and fail-closed behavior.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PIN_ORIGIN="$TMP/pin-origin"
PIN_DEST="$TMP/pin-dest"
mkdir -p "$PIN_ORIGIN"
git -C "$PIN_ORIGIN" init -q
git -C "$PIN_ORIGIN" config user.email "selftest@example.com"
git -C "$PIN_ORIGIN" config user.name "selftest"
printf 'one\n' > "$PIN_ORIGIN/readme"
git -C "$PIN_ORIGIN" add readme
git -C "$PIN_ORIGIN" commit -q -m "first"
PIN_A=$(git -C "$PIN_ORIGIN" rev-parse HEAD)
printf 'two\n' > "$PIN_ORIGIN/readme"
git -C "$PIN_ORIGIN" add readme
git -C "$PIN_ORIGIN" commit -q -m "second"
PIN_B=$(git -C "$PIN_ORIGIN" rev-parse HEAD)
git clone -q "$PIN_ORIGIN" "$PIN_DEST"
git -C "$PIN_DEST" checkout -q --detach "$PIN_A"
if INSTALL_DIR="$PIN_DEST" WAKEUP_REVISION="" \
     bash "$ROOT_DIR/templates/onstart.vastai.sh" \
     >"$TMP/pin-missing.out" 2>&1; then
  fail "onstart template accepted a missing WAKEUP_REVISION"
fi
grep -q "WAKEUP_REVISION is required" "$TMP/pin-missing.out" \
  || fail "missing revision did not fail closed"
if bash "$BIN_DIR/pin_revision.sh" --repo "$PIN_DEST" "missing-revision-zzz" \
     >"$TMP/pin-bad.out" 2>&1; then
  fail "pin_revision accepted an unknown revision"
fi
grep -q "Refusing to continue" "$TMP/pin-bad.out" \
  || fail "failed pin did not refuse to continue"
[[ "$(git -C "$PIN_DEST" rev-parse HEAD)" == "$PIN_A" ]] \
  || fail "failed pin changed HEAD"
bash "$BIN_DIR/pin_revision.sh" --repo "$PIN_DEST" "$PIN_B" >/dev/null
[[ "$(git -C "$PIN_DEST" rev-parse HEAD)" == "$PIN_B" ]] \
  || fail "pin_revision did not detach at the requested revision"
bash "$BIN_DIR/pin_revision.sh" --repo "$PIN_DEST" --verify-only "$PIN_B" >/dev/null \
  || fail "verify-only rejected a matching revision"
if bash "$BIN_DIR/pin_revision.sh" --repo "$PIN_DEST" --verify-only "$PIN_A" \
     >/dev/null 2>&1; then
  fail "verify-only accepted the wrong revision"
fi
pass "pinned revision is required and fail-closed"
