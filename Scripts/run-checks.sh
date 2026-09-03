#!/bin/sh
# Aethergram repo checks. Three gates, in the order a failure is cheapest to read.
#
#   Scripts/run-checks.sh    offline, no network
#
# The leak scan runs first because it is milliseconds and its failure is about what is committed
# rather than what the code does. The commit-message gate is proved next on known-bad input, since
# a gate that never fires looks exactly like one that passes. `swift test` is the correctness gate.

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

printf '\ncommit message gate\n'

# The hook is only worth having once it has been watched refusing input it is meant to refuse.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/aethergram-checks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

it "a session trailer in a message is refused"
printf 'fix: a thing\n\nAgent-Session: 0f21\n' > "$TMP/trailer"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/trailer" >/dev/null 2>&1; then
    fail "a message carrying a session trailer was accepted"
else
    pass
fi

it "an ordinary message is accepted"
printf 'fix: a thing\n\nOne sentence saying why.\n' > "$TMP/clean"
if OUT="$("$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/clean" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "a clean message was refused"
fi

it "what a verbose commit appends below the scissors line is not scanned"
printf 'fix: a thing\n\n# ------------------------ >8 ------------------------\ndiff --git a/x b/x\n+see #404\n' > "$TMP/verbose"
if OUT="$("$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/verbose" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the diff a verbose commit appends was scanned"
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
