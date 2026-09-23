#!/bin/sh
# Aethergram repo checks. Five gates, in the order a failure is cheapest to read.
#
#   Scripts/run-checks.sh    offline, no network; needs the release tags, so not a shallow clone
#
# The leak scan runs first because it is milliseconds and its failure is about what is committed
# rather than what the code does. The commit-message gate is proved next on known-bad input, since
# a gate that never fires looks exactly like one that passes. The build gates compile what the suite
# cannot reach, the api-break gate holds the public API to what the release being prepared may
# change, and `swift test` is the correctness gate.

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

it "nothing tracked or in history identifies a consumer, a person, or a machine"
if OUT="$("$ROOT/Scripts/scan-for-leaks.sh" --all 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "Scripts/scan-for-leaks.sh --all refused the tree or its history"
fi

# The hook is only worth having once it has been watched refusing input it is meant to refuse.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/aethergram-checks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

it "a leak staged then reverted in the working tree is still refused"
CLONE="$TMP/clone"
mkdir -p "$CLONE/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$CLONE/Scripts/scan-for-leaks.sh"
chmod +x "$CLONE/Scripts/scan-for-leaks.sh"
(
    cd "$CLONE" \
    && git init -q \
    && printf 'see /Users/example\n' > leak.txt \
    && git add leak.txt \
    && printf 'clean\n' > leak.txt
)
# Trust nothing about the fixture: confirm it actually staged a leak the working copy no
# longer carries, or a scanner that always refuses would pass this test for the wrong reason.
(cd "$CLONE" && git diff --quiet); WORKING_RC=$?
(cd "$CLONE" && git diff --cached --quiet); STAGED_RC=$?
OUT="$(cd "$CLONE" && ./Scripts/scan-for-leaks.sh 2>&1)"; SCAN_RC=$?
if [ "$WORKING_RC" -eq 0 ] || [ "$STAGED_RC" -eq 0 ]; then
    fail "the fixture did not leave a staged file whose working copy differs"
elif [ "$SCAN_RC" -eq 0 ]; then
    fail "a leak staged then reverted in the working tree was not caught"
elif ! printf '%s\n' "$OUT" | grep -q "absolute home path" || ! printf '%s\n' "$OUT" | grep -q "leak.txt"; then
    fail "the scanner refused for a reason other than the staged leak"
else
    pass
fi

it "a scan with no work tree to read fails rather than reporting clean"
NOTREE="$TMP/no-tree"
mkdir -p "$NOTREE/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$NOTREE/Scripts/scan-for-leaks.sh"
chmod +x "$NOTREE/Scripts/scan-for-leaks.sh"
# The ceiling keeps git from finding a repository above the fixture, wherever TMPDIR points.
if (cd "$NOTREE" && GIT_CEILING_DIRECTORIES="$TMP" git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    fail "the fixture is inside a work tree"
else
    OUT="$(cd "$NOTREE" && GIT_CEILING_DIRECTORIES="$TMP" ./Scripts/scan-for-leaks.sh 2>&1)"; SCAN_RC=$?
    if [ "$SCAN_RC" -ne 2 ] || printf '%s\n' "$OUT" | grep -q '^clean$'; then
        printf '%s\n' "$OUT"
        fail "a scan outside a work tree exited $SCAN_RC rather than 2"
    else
        pass
    fi
fi

it "a leak staged into the runner, outside its fixtures, is refused"
RUNNER="$TMP/runner"
mkdir -p "$RUNNER/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$ROOT/Scripts/run-checks.sh" "$RUNNER/Scripts/"
chmod +x "$RUNNER/Scripts/scan-for-leaks.sh"
(cd "$RUNNER" && git init -q && git add Scripts)
# The unmodified runner must scan clean first, or a scanner that refuses the runner wholesale
# would pass this test for the wrong reason.
if ! OUT="$(cd "$RUNNER" && ./Scripts/scan-for-leaks.sh 2>&1)"; then
    printf '%s\n' "$OUT"
    fail "the unmodified runner was refused, so its fixtures are not all allowed"
else
    printf '# see /Users/somebody\n' >> "$RUNNER/Scripts/run-checks.sh"
    (cd "$RUNNER" && git add Scripts/run-checks.sh)
    OUT="$(cd "$RUNNER" && ./Scripts/scan-for-leaks.sh 2>&1)"; SCAN_RC=$?
    if [ "$SCAN_RC" -eq 0 ]; then
        fail "a leak staged into the runner was accepted"
    elif ! printf '%s\n' "$OUT" | grep -q 'Scripts/run-checks.sh:.*/Users/somebody'; then
        printf '%s\n' "$OUT"
        fail "the scanner refused for a reason other than the staged line"
    else
        pass
    fi
fi

printf '\ncommit message gate\n'

it "a session trailer in a message is refused"
printf 'fix: a thing\n\nAgent-Session: 0f21\n' > "$TMP/trailer"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/trailer" >/dev/null 2>&1; then
    fail "a message carrying a session trailer was accepted"
else
    pass
fi

it "an issue or pull request URL in a message is refused"
printf 'fix: a thing\n\nSee github.com/foo/bar/issues/42\n' > "$TMP/issueurl"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/issueurl" >/dev/null 2>&1; then
    fail "a message carrying an issue or pull request URL was accepted"
else
    pass
fi

it "a hash-prefixed leak line in a message is refused"
printf 'fix: a thing\n\n# see github.com/foo/bar/issues/42\n' > "$TMP/hashline"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/hashline" >/dev/null 2>&1; then
    fail "a message carrying a #-prefixed leak line was accepted"
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

it "a merge subject typed into a message is refused"
printf 'Merge pull request #4812 from seriouslysean/x\n' > "$TMP/mergesubject"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/mergesubject" >/dev/null 2>&1; then
    fail "a message carrying GitHub's merge subject was accepted, though no hook ever sees one GitHub wrote"
else
    pass
fi

it "a pull request number ending a subject is refused"
printf 'fix: crash when the widget reloads (#4812)\n' > "$TMP/squashsubject"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/squashsubject" >/dev/null 2>&1; then
    fail "a subject ending in a pull request number was accepted"
else
    pass
fi

it "an issue number in a body is still refused"
printf 'fix: a thing\n\nSee #100 for why.\n' > "$TMP/bodynumber"
if "$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/bodynumber" >/dev/null 2>&1; then
    fail "a message carrying an issue number in its body was accepted"
else
    pass
fi

# The history tier reads `%H %s` lines rather than a message file, so it is proved on real commits.
# These are throwaway repos: the hooks are switched off so a fixture meant to be refused can exist.
fixture_git() {
    git -c user.name=fixture -c user.email=fixture -c commit.gpgsign=false \
        -c core.hooksPath=/dev/null "$@"
}

it "a merge commit carrying GitHub's merge subject is accepted in history"
HIST="$TMP/history-ok"
mkdir -p "$HIST/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$HIST/Scripts/scan-for-leaks.sh"
chmod +x "$HIST/Scripts/scan-for-leaks.sh"
(
    cd "$HIST" \
    && fixture_git init -q \
    && fixture_git commit -q --allow-empty -m 'fix: a thing' \
    && fixture_git checkout -q -b side \
    && fixture_git commit -q --allow-empty -m 'fix: another thing' \
    && fixture_git checkout -q - \
    && fixture_git merge -q --no-ff -m 'Merge pull request #101 from seriouslysean/101-a-branch' side
) || fail "the fixture history could not be built"
if OUT="$(cd "$HIST" && ./Scripts/scan-for-leaks.sh --all 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the subject GitHub writes on a merge commit was refused in history"
fi

it "a pull request number ending a subject is refused in history"
HIST="$TMP/history-squash"
mkdir -p "$HIST/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$HIST/Scripts/scan-for-leaks.sh"
chmod +x "$HIST/Scripts/scan-for-leaks.sh"
(
    cd "$HIST" \
    && fixture_git init -q \
    && fixture_git commit -q --allow-empty -m 'fix: crash when the widget reloads (#4812)'
) || fail "the fixture history could not be built"
OUT="$(cd "$HIST" && ./Scripts/scan-for-leaks.sh --all 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 0 ]; then
    fail "a subject ending in a pull request number was accepted in history"
elif ! printf '%s\n' "$OUT" | grep -q '#4812'; then
    printf '%s\n' "$OUT"
    fail "the scanner refused for a reason other than the subject"
else
    pass
fi

it "a merge subject on a commit that is not a merge is refused in history"
HIST="$TMP/history-typed-merge"
mkdir -p "$HIST/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$HIST/Scripts/scan-for-leaks.sh"
chmod +x "$HIST/Scripts/scan-for-leaks.sh"
(
    cd "$HIST" \
    && fixture_git init -q \
    && fixture_git commit -q --allow-empty -m 'Merge pull request #4812 from seriouslysean/x'
) || fail "the fixture history could not be built"
OUT="$(cd "$HIST" && ./Scripts/scan-for-leaks.sh --all 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 0 ]; then
    fail "a merge subject typed onto a single-parent commit was accepted in history"
elif ! printf '%s\n' "$OUT" | grep -q '#4812'; then
    printf '%s\n' "$OUT"
    fail "the scanner refused for a reason other than the subject"
else
    pass
fi

it "a merge subject's shape in a body is still refused in history"
HIST="$TMP/history-body"
mkdir -p "$HIST/Scripts"
cp "$ROOT/Scripts/scan-for-leaks.sh" "$HIST/Scripts/scan-for-leaks.sh"
chmod +x "$HIST/Scripts/scan-for-leaks.sh"
(
    cd "$HIST" \
    && fixture_git init -q \
    && fixture_git commit -q --allow-empty -m 'fix: a thing' -m 'Merge pull request #102 from seriouslysean/102-a-branch'
) || fail "the fixture history could not be built"
OUT="$(cd "$HIST" && ./Scripts/scan-for-leaks.sh --all 2>&1)"; SCAN_RC=$?
if [ "$SCAN_RC" -eq 0 ]; then
    fail "a merge subject's shape in a body was accepted in history"
elif ! printf '%s\n' "$OUT" | grep -q '#102'; then
    printf '%s\n' "$OUT"
    fail "the scanner refused for a reason other than the body line"
else
    pass
fi

it "what a verbose commit appends below the scissors line is not scanned"
printf 'fix: a thing\n\n# ------------------------ >8 ------------------------\ndiff --git a/x b/x\n+see #404\n' > "$TMP/verbose"
if OUT="$("$ROOT/Scripts/scan-for-leaks.sh" --message "$TMP/verbose" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the diff a verbose commit appends was scanned"
fi

printf '\nbuild gates\n'

# `swift test` compiles the host in debug, so the iOS arms, the release arm of `#if DEBUG`, and
# extension safety are proved here instead: an iOS release build with -application-extension, which
# a host's widget or share extension links under. Warnings stay non-fatal until the known iOS 18
# deprecation in EnvironmentSnapshot.swift is gone; -warnings-as-errors waits on that.
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)" || IOS_SDK=""
ios_build() {
    _pkg="$1"; _scratch="$2"; shift 2
    [ -n "$IOS_SDK" ] || { printf 'xcrun found no iphoneos SDK\n'; return 1; }
    swift build --package-path "$_pkg" --scratch-path "$_scratch" \
        -c release --triple arm64-apple-ios18.0 --sdk "$IOS_SDK" -Xswiftc -application-extension \
        --explicit-target-dependency-import-check error "$@"
}
# The core alone, into a scratch path that has never held the adapter's module, so the build proves
# the core compiles with no adapter in reach rather than finding one left over from a full build.
core_gate() { ios_build "$1" "$2" --target AethergramCore; }
package_gate() { ios_build "$1" "$2" --target Aethergram; }

it "the core builds for iOS release with no adapter in reach"
if OUT="$(core_gate "$ROOT" "$TMP/ios" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the core did not build alone for iOS release"
fi

it "the package builds for iOS release as extension-safe"
if OUT="$(package_gate "$ROOT" "$TMP/ios" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the package did not build for iOS release with -application-extension"
fi

# Apple reads the manifest out of the SDK's bundle, so it is checked where the build put it rather
# than only where it is committed. `plutil -lint` is first watched refusing a malformed one.
MANIFEST="Sources/AethergramCore/PrivacyInfo.xcprivacy"

it "a malformed privacy manifest is refused"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>NSPrivacyTracking</key></dict>\n' > "$TMP/bad.xcprivacy"
if plutil -lint "$TMP/bad.xcprivacy" >/dev/null 2>&1; then
    fail "plutil accepted a manifest with no closing plist element and a key with no value"
else
    pass
fi

it "the privacy manifest is a valid property list and ships in the core's iOS bundle"
BUNDLED="$(find "$TMP/ios" -path '*AethergramCore.bundle/PrivacyInfo.xcprivacy' 2>/dev/null | head -n 1)"
if ! OUT="$(plutil -lint "$ROOT/$MANIFEST" 2>&1)"; then
    printf '%s\n' "$OUT"
    fail "$MANIFEST is not a valid property list"
elif [ -z "$BUNDLED" ]; then
    fail "the iOS build produced no AethergramCore bundle carrying PrivacyInfo.xcprivacy"
elif ! cmp -s "$ROOT/$MANIFEST" "$BUNDLED"; then
    fail "the bundled manifest differs from $MANIFEST"
else
    pass
fi

# A copy of the package to break on purpose, so a gate is watched refusing before it is trusted.
copy_package() { mkdir -p "$1" && cp -R "$ROOT/Package.swift" "$ROOT/Sources" "$ROOT/Tests" "$1/"; }

it "a core that imports the adapter is refused"
BAD="$TMP/core-imports-adapter"
copy_package "$BAD"
printf 'import AethergramTelemetryDeck\n' > "$BAD/Sources/AethergramCore/ImportsAdapter.swift"
OUT="$(core_gate "$BAD" "$BAD.build" 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then
    fail "a core importing the adapter built"
elif ! printf '%s\n' "$OUT" | grep -q 'AethergramTelemetryDeck'; then
    printf '%s\n' "$OUT"
    fail "the core build failed for a reason other than the import"
else
    pass
fi

it "the iOS arm, the release arm, and extension-unsafe API are each compiled"
BAD="$TMP/unbuilt-arms"
copy_package "$BAD"
printf '#if os(iOS)\nlet iosArmProbe: Int = iosArmMarker\n#endif\n' > "$BAD/Sources/AethergramCore/IOSArm.swift"
printf '#if !DEBUG\nlet releaseArmProbe: Int = releaseArmMarker\n#endif\n' > "$BAD/Sources/AethergramCore/ReleaseArm.swift"
printf '#if os(iOS)\nimport UIKit\n@MainActor func extensionProbe() -> Any { UIApplication.shared }\n#endif\n' \
    > "$BAD/Sources/AethergramCore/ExtensionUnsafe.swift"
OUT="$(package_gate "$BAD" "$BAD.build" 2>&1)"; GATE_RC=$?
# Whole-module release reports every file's error in one pass, so one build proves all three; a
# missing marker names the arm the gate does not reach.
MISSING=""
for MARKER in iosArmMarker releaseArmMarker 'unavailable in application extensions'; do
    printf '%s\n' "$OUT" | grep -q "$MARKER" || MISSING="$MISSING [$MARKER]"
done
if [ "$GATE_RC" -eq 0 ] || [ -n "$MISSING" ]; then
    fail "the build gate exited $GATE_RC and never reached:$MISSING"
else
    pass
fi

# watchOS is declared but nothing else compiles it. arm64_32 is the arm every supported watch runs,
# and the triple's version is the manifest's floor, so an API newer than the floor fails here.
WATCH_SDK="$(xcrun --sdk watchos --show-sdk-path)" || WATCH_SDK=""
watch_gate() {
    [ -n "$WATCH_SDK" ] || { printf 'xcrun found no watchos SDK\n'; return 1; }
    swift build --package-path "$1" --scratch-path "$2" \
        -c release --triple arm64_32-apple-watchos11.0 --sdk "$WATCH_SDK" -Xswiftc -application-extension \
        --explicit-target-dependency-import-check error --target Aethergram
}

it "the package builds for watchOS release at its floor"
if OUT="$(watch_gate "$ROOT" "$TMP/watchos" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the package did not build for watchOS 11 release"
fi

it "the watchOS arm is compiled"
BAD="$TMP/unbuilt-watch-arm"
copy_package "$BAD"
printf '#if os(watchOS)\nlet watchArmProbe: Int = watchArmMarker\n#endif\n' > "$BAD/Sources/AethergramCore/WatchArm.swift"
OUT="$(watch_gate "$BAD" "$BAD.build" 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -eq 0 ] || ! printf '%s\n' "$OUT" | grep -q 'watchArmMarker'; then
    fail "the watchOS gate exited $GATE_RC and never reached the watchOS arm"
else
    pass
fi

printf '\napi-break gate\n'

# Proved on the package's own history before it is trusted: 0.3.0 removed `SignalBatch.sessionID`
# and changed `Signal.init`, and 0.3.2 moved nothing. One scratch directory, so each tag builds once.
API="$TMP/api"
api_gate() { "$ROOT/Scripts/check-api-breaks.sh" --scratch "$API" "$@"; }

it "the break 0.3.0 made is refused when declared a patch"
OUT="$(api_gate --base v0.2.1 --head v0.3.0 --release 0.2.2 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 1 ]; then
    printf '%s\n' "$OUT"
    fail "the gate exited $GATE_RC rather than 1 on a break declared a patch"
elif ! printf '%s\n' "$OUT" | grep -q 'SignalBatch.sessionID has been removed' \
    || ! printf '%s\n' "$OUT" | grep -q 'Signal.init(name:parameters:floatValue:recordedAt:) has been removed'; then
    printf '%s\n' "$OUT"
    fail "the gate refused without naming the removed property and initializer"
else
    pass
fi

it "the same break passes, and is still listed, when declared a 0.x minor"
OUT="$(api_gate --base v0.2.1 --head v0.3.0 --release 0.3.0 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 0 ] || ! printf '%s\n' "$OUT" | grep -q 'SignalBatch.sessionID has been removed'; then
    printf '%s\n' "$OUT"
    fail "the gate exited $GATE_RC or did not list the break a minor may make"
else
    pass
fi

it "a patch that moved nothing reports no break"
OUT="$(api_gate --base v0.3.1 --head v0.3.2 --release 0.3.2 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 0 ] || [ "$(printf '%s\n' "$OUT" | grep -c ': no breaks$')" -ne 2 ]; then
    printf '%s\n' "$OUT"
    fail "the gate exited $GATE_RC or found a break between 0.3.1 and 0.3.2"
else
    pass
fi

it "the working tree breaks nothing its CHANGELOG entry does not allow"
if OUT="$(api_gate 2>&1)"; then
    printf '%s\n' "$OUT" | sed 's/^/        /'
    pass
else
    printf '%s\n' "$OUT"
    fail "Scripts/check-api-breaks.sh refused the working tree against the last release"
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
