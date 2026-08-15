#!/usr/bin/env bash
# Focused offline test runner. Invoked by bin/selftest.sh.
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TESTS_DIR/.." && pwd)
# shellcheck source=helpers.sh
. "$TESTS_DIR/helpers.sh"

echo "== Python unit tests =="
"$PYTHON" -m unittest discover -s "$TESTS_DIR" -p 'test_*.py' -v
pass "python unit tests"

echo
echo "== Behavioral tests =="
for test in "$TESTS_DIR"/test_*.sh; do
  echo "-- $(basename "$test") --"
  bash "$test"
done

echo
echo "selftest passed"
