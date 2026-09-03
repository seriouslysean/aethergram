#!/bin/sh
# Aethergram repo checks. Two gates, in the order a failure is cheapest to read.
#
#   Scripts/run-checks.sh    offline, no network
#
# The leak scan runs first because it is milliseconds and its failure is about what is committed
# rather than what the code does. `swift test` runs second and is the correctness gate.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
CURRENT=""

it() { CURRENT="$1"; }
# Count first, print second. A printf that fails to write -- a full disk, a closed pipe -- must
# still leave FAIL nonzero, or a real failure becomes exit 0 on the run a release gates on.
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n         %s\n' "$CURRENT" "$1"; }

printf '\nleak scan\n'

it "nothing tracked identifies a consumer, a person, or a machine"
if OUT="$("$ROOT/Scripts/scan-for-leaks.sh" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "Scripts/scan-for-leaks.sh refused the tree"
fi

printf '\nswift test\n'

it "the package suite passes"
if swift test --package-path "$ROOT"; then
    pass
else
    fail "swift test exited non-zero"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
