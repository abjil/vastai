#!/usr/bin/env bash
# Public-IP lookup: disabled, enabled, cache, primary failure, fallback.
set -euo pipefail
# shellcheck source=helpers.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

TMP=$(mktemp -d)
MOCK_PIDS=()
cleanup() {
  local pid
  for pid in "${MOCK_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP" || true
}
trap cleanup EXIT

IP_MARKER="$TMP/ip-lookup-called"
cat > "$TMP/fake-ip.sh" <<EOF
#!/usr/bin/env bash
printf 'called\\n' >> "$IP_MARKER"
printf '9.9.9.9\\n'
EOF
chmod +x "$TMP/fake-ip.sh"

IP_OFF_DIR="$TMP/ip-off"
IP_OFF_ENV="$TMP/ip-off.env"
mkdir -p "$IP_OFF_DIR"
write_lifecycle_env "$IP_OFF_ENV" "$IP_OFF_DIR"
cat >> "$IP_OFF_ENV" <<EOF
PUBLIC_IP_LOOKUP=0
EOF
DATA_DIR="$IP_OFF_DIR" \
WAKEUP_ENV="$IP_OFF_ENV" \
WAKEUP_LOG="$IP_OFF_DIR/wakeup.log" \
WAKEUP_PID="$IP_OFF_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$IP_OFF_DIR/runtime" \
WAKEUP_PUBLIC_IP_CMD="$TMP/fake-ip.sh" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
[[ ! -e "$IP_MARKER" ]] || fail "public-IP command ran while lookup was disabled"
grep -q "Public IP:  unknown" "$IP_OFF_DIR/runtime/alert-email.txt" \
  || fail "disabled lookup did not keep public IP unknown"
pass "public-IP lookup stays off when disabled"

IP_ON_DIR="$TMP/ip-on"
IP_ON_ENV="$TMP/ip-on.env"
mkdir -p "$IP_ON_DIR"
write_lifecycle_env "$IP_ON_ENV" "$IP_ON_DIR"
cat >> "$IP_ON_ENV" <<EOF
PUBLIC_IP_LOOKUP=1
EOF
DATA_DIR="$IP_ON_DIR" \
WAKEUP_ENV="$IP_ON_ENV" \
WAKEUP_LOG="$IP_ON_DIR/wakeup.log" \
WAKEUP_PID="$IP_ON_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$IP_ON_DIR/runtime" \
PUBLIC_IP_CACHE_FILE="$IP_ON_DIR/runtime/public_ip" \
WAKEUP_PUBLIC_IP_CMD="$TMP/fake-ip.sh" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
grep -q "Public IP:  9.9.9.9" "$IP_ON_DIR/runtime/alert-email.txt" \
  || fail "enabled lookup did not use the mocked public IP"
DATA_DIR="$IP_ON_DIR" \
WAKEUP_ENV="$IP_ON_ENV" \
WAKEUP_LOG="$IP_ON_DIR/wakeup-2.log" \
WAKEUP_PID="$IP_ON_DIR/wakeup-2.pid" \
WAKEUP_RUNTIME="$IP_ON_DIR/runtime" \
PUBLIC_IP_CACHE_FILE="$IP_ON_DIR/runtime/public_ip" \
WAKEUP_PUBLIC_IP_CMD="$TMP/fake-ip.sh" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
[[ "$(grep -c 'called' "$IP_MARKER")" -eq 1 ]] \
  || fail "public-IP lookup was not cached for the session"
pass "public-IP lookup is mocked, optional, and cached"

ip_fail=$(start_mock http ip-fail "$TMP/ip-fail.meta") || fail "ip-fail mock failed"
MOCK_PIDS+=("$ip_fail")
IP_FAIL_DIR="$TMP/ip-fail"
IP_FAIL_ENV="$TMP/ip-fail.env"
mkdir -p "$IP_FAIL_DIR"
write_lifecycle_env "$IP_FAIL_ENV" "$IP_FAIL_DIR"
cat >> "$IP_FAIL_ENV" <<EOF
PUBLIC_IP_LOOKUP=1
EOF
DATA_DIR="$IP_FAIL_DIR" \
WAKEUP_ENV="$IP_FAIL_ENV" \
WAKEUP_LOG="$IP_FAIL_DIR/wakeup.log" \
WAKEUP_PID="$IP_FAIL_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$IP_FAIL_DIR/runtime" \
PUBLIC_IP_CACHE_FILE="$IP_FAIL_DIR/runtime/public_ip" \
WAKEUP_PUBLIC_IP_URLS="http://127.0.0.1:$(mock_port "$TMP/ip-fail.meta")/" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
grep -q "Public IP:  unknown" "$IP_FAIL_DIR/runtime/alert-email.txt" \
  || fail "failed public-IP lookup did not fall back to unknown"
pass "public-IP primary failure yields unknown"

ip_ok=$(start_mock http ip-ok "$TMP/ip-ok.meta") || fail "ip-ok mock failed"
MOCK_PIDS+=("$ip_ok")
IP_FB_DIR="$TMP/ip-fallback"
IP_FB_ENV="$TMP/ip-fallback.env"
mkdir -p "$IP_FB_DIR"
write_lifecycle_env "$IP_FB_ENV" "$IP_FB_DIR"
cat >> "$IP_FB_ENV" <<EOF
PUBLIC_IP_LOOKUP=1
EOF
DATA_DIR="$IP_FB_DIR" \
WAKEUP_ENV="$IP_FB_ENV" \
WAKEUP_LOG="$IP_FB_DIR/wakeup.log" \
WAKEUP_PID="$IP_FB_DIR/wakeup.pid" \
WAKEUP_RUNTIME="$IP_FB_DIR/runtime" \
PUBLIC_IP_CACHE_FILE="$IP_FB_DIR/runtime/public_ip" \
WAKEUP_PUBLIC_IP_URLS="http://127.0.0.1:$(mock_port "$TMP/ip-fail.meta")/ http://127.0.0.1:$(mock_port "$TMP/ip-ok.meta")/" \
  "$BIN_DIR/wakeup.sh" --dry-run --once
grep -q "Public IP:  203.0.113.10" "$IP_FB_DIR/runtime/alert-email.txt" \
  || fail "public-IP fallback URL was not used"
pass "public-IP lookup falls back to the second URL"
