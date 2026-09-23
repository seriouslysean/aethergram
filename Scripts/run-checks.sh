#!/bin/sh
# Aethergram repo checks. The gates run in the order a failure is cheapest to read.
#
#   Scripts/run-checks.sh    offline, no network; needs the release tags, so not a shallow clone
#
#   AETHERGRAM_RELEASE=X.Y.Z Scripts/run-checks.sh
#       the release the working tree's api gate holds it to, in place of CHANGELOG.md's top
#       heading, for a branch whose entry is not written yet. A value that is not X.Y.Z stops the
#       run before any gate, since an override nothing read would pass as though it had been.
#   Scripts/run-checks.sh --validate-only
#       checks the environment and exits, so that refusal can itself be proved below.
#
# The leak scan runs first because it is milliseconds and its failure is about what is committed
# rather than what the code does. The commit-message gate is proved next on known-bad input, since
# a gate that never fires looks exactly like one that passes. The build gates compile what the suite
# cannot reach, the consumer fixture compiles and tests what a host writes, the api-break gate holds
# the public API to what the release being prepared may change, the release heading gate is proved
# on the refusals a tag push would make, the documentation gate builds what Swift Package Index
# publishes, and `swift test` is the correctness gate.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RELEASE_OVERRIDE="${AETHERGRAM_RELEASE:-}"
if [ -n "$RELEASE_OVERRIDE" ] && ! printf '%s\n' "$RELEASE_OVERRIDE" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf 'run-checks: AETHERGRAM_RELEASE=%s is not X.Y.Z\n' "$RELEASE_OVERRIDE" >&2
    exit 2
fi
case "${1:-}" in
    "") ;;
    --validate-only) exit 0 ;;
    *) printf 'run-checks: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

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
# The consumer fixture is left out: it is no part of the package, and a local run may have left
# its build directory in it.
copy_package() {
    mkdir -p "$1/Tests" && cp -R "$ROOT/Package.swift" "$ROOT/Sources" "$1/" || return 1
    for _dir in "$ROOT"/Tests/*; do
        [ "$_dir" = "$ROOT/Tests/Fixtures" ] || cp -R "$_dir" "$1/Tests/" || return 1
    done
}

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

# watchOS is declared but nothing else compiles it. The triple's version is the manifest's floor,
# so an API newer than the floor fails here.
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

printf '\nconsumer fixture\n'

# A package of its own that depends on this one by path and imports the umbrella alone, in a module
# with no upcoming-feature flag: it compiles what a host writes, and tests the patterns a host
# flushes under in an extension and in an app. Both builds go to scratch paths, never into the tree.
FIXTURE="$ROOT/Tests/Fixtures/ConsumerHost"
FIXTURE_TESTS=9

it "the fixture's extension target builds for iOS release as extension-safe, alone"
OUT="$(ios_build "$FIXTURE" "$TMP/fixture-ios" --target ConsumerHostExtension 2>&1)"; GATE_RC=$?
# The warning is how the build shows it compiled the fixture's host code rather than a cached copy.
if [ "$GATE_RC" -ne 0 ]; then
    printf '%s\n' "$OUT"
    fail "the fixture's extension target did not build for iOS release with -application-extension"
elif ! printf '%s\n' "$OUT" | grep -q "'testPartition(for:)' is deprecated"; then
    printf '%s\n' "$OUT"
    fail "the build did not report the deprecated call, so it did not compile the host's code"
elif [ -z "$(find "$TMP/fixture-ios" -name 'ConsumerHostExtension.swiftmodule' 2>/dev/null | head -n 1)" ] \
    || [ -n "$(find "$TMP/fixture-ios" -name 'ConsumerHostApp.swiftmodule' 2>/dev/null | head -n 1)" ]; then
    fail "the build did not produce the extension module alone: the app target calls UIApplication.shared"
else
    pass
fi

# The app target's UIKit binding is behind `#if canImport(UIKit)`, which the macOS test run never
# compiles, and it may not go into the extension-safe build, so it gets an iOS build of its own.
app_gate() {
    [ -n "$IOS_SDK" ] || { printf 'xcrun found no iphoneos SDK\n'; return 1; }
    swift build --package-path "$1" --scratch-path "$2" --triple arm64-apple-ios18.0 --sdk "$IOS_SDK" \
        --explicit-target-dependency-import-check error --target ConsumerHostApp
}

it "the fixture's app target builds for iOS with its UIKit binding"
if OUT="$(app_gate "$FIXTURE" "$TMP/fixture-ios-app" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the fixture's app target did not build for iOS"
fi

it "the fixture's app build reaches the UIKit arm"
BAD="$TMP/unbuilt-uikit-arm"
copy_package "$BAD"
mkdir -p "$BAD/Tests/Fixtures" && cp -R "$FIXTURE" "$BAD/Tests/Fixtures/"
rm -rf "$BAD/Tests/Fixtures/ConsumerHost/.build"
printf '#if canImport(UIKit)\nlet uikitArmProbe: Int = uikitArmMarker\n#endif\n' \
    > "$BAD/Tests/Fixtures/ConsumerHost/Sources/ConsumerHostApp/UIKitArm.swift"
OUT="$(app_gate "$BAD/Tests/Fixtures/ConsumerHost" "$BAD.build" 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -eq 0 ] || ! printf '%s\n' "$OUT" | grep -q 'uikitArmMarker'; then
    fail "the app build exited $GATE_RC and never reached the UIKit arm"
else
    pass
fi

# Swift Testing's summary line; a run that matched nothing says 0, or prints no line at all.
tests_run() { printf '%s\n' "$1" | sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} .*/\1/p' | tail -n 1; }
fixture_ran_all() {
    [ "$1" -eq 0 ] && [ "$(tests_run "$2")" = "$FIXTURE_TESTS" ]
}

# No debug info, so no dsymutil: it was seen listing TMPDIR itself, which on a machine with a large
# one held the run for over ten minutes.
fixture_test() {
    swift test --package-path "$FIXTURE" --scratch-path "$TMP/fixture-test" -debug-info-format none "$@"
}

# The filtered run exits 0 having run nothing, which is the case the count exists to refuse.
it "a fixture run that executes no test is refused"
OUT="$(fixture_test --filter NoSuchTestProbe 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 0 ] || [ "$(tests_run "$OUT")" != 0 ]; then
    printf '%s\n' "$OUT"
    fail "the filtered run exited $GATE_RC or did not report 0 tests, so it proves nothing about the count"
elif fixture_ran_all "$GATE_RC" "$OUT"; then
    fail "a run of 0 tests passed as the full suite"
else
    pass
fi

it "the fixture's $FIXTURE_TESTS tests run on macOS and pass"
OUT="$(fixture_test 2>&1)"; GATE_RC=$?
if fixture_ran_all "$GATE_RC" "$OUT"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "swift test exited $GATE_RC having run $(tests_run "$OUT") of $FIXTURE_TESTS tests"
fi

# `swift test` at the root must not run the fixture's suite as its own, or compile its sources.
root_takes_fixture() { swift package --package-path "$1" describe 2>&1 | grep -q 'Tests/Fixtures\|ConsumerHost'; }

it "the root package takes no target or source from the fixture"
BAD="$TMP/root-takes-fixture"
copy_package "$BAD"
mkdir -p "$BAD/Tests/Fixtures" && cp -R "$FIXTURE" "$BAD/Tests/Fixtures/"
rm -rf "$BAD/Tests/Fixtures/ConsumerHost/.build"
printf 'package.targets.append(.testTarget(name: "FixtureProbe", path: "Tests/Fixtures/ConsumerHost/Tests/ConsumerHostTests"))\n' \
    >> "$BAD/Package.swift"
if ! root_takes_fixture "$BAD"; then
    fail "a manifest with a target inside the fixture was not caught"
elif root_takes_fixture "$ROOT"; then
    swift package --package-path "$ROOT" describe | grep 'Tests/Fixtures\|ConsumerHost'
    fail "the root package describes something under Tests/Fixtures"
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

# The digester reports no addition, so the listing is proved on the same history: 0.3.0 moved
# `sessionID` from the batch to each signal, and 0.3.2 moved nothing.
it "the declarations a release added and dropped are listed"
OUT="$(api_gate --base v0.2.1 --head v0.3.0 --release 0.3.0 --print-additions 2>&1)"; GATE_RC=$?
MISSING=""
for LINE in '    + Var Signal.sessionID: Swift.String' '    - Var SignalBatch.sessionID: Swift.String' \
    '  AethergramTelemetryDeck: nothing added or dropped'; do
    printf '%s\n' "$OUT" | grep -qF -- "$LINE" || MISSING="$MISSING [$LINE]"
done
if [ "$GATE_RC" -ne 0 ] || [ -n "$MISSING" ]; then
    printf '%s\n' "$OUT"
    fail "the listing exited $GATE_RC or lacked:$MISSING"
else
    pass
fi

it "a patch that moved nothing lists no declaration"
OUT="$(api_gate --base v0.3.1 --head v0.3.2 --print-additions 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 0 ] || [ "$(printf '%s\n' "$OUT" | grep -c ': nothing added or dropped$')" -ne 2 ] \
    || printf '%s\n' "$OUT" | grep -q '^    [+-] '; then
    printf '%s\n' "$OUT"
    fail "the listing exited $GATE_RC or listed a declaration between 0.3.1 and 0.3.2"
else
    pass
fi

# The working tree's gate, with the override forwarded when $1 carries one.
release_gate() {
    _release="$1"; shift
    if [ -n "$_release" ]; then api_gate --release "$_release" "$@"; else api_gate "$@"; fi
}

it "a release override that is not X.Y.Z stops the run"
OUT="$(AETHERGRAM_RELEASE=banana "$ROOT/Scripts/run-checks.sh" --validate-only 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 2 ] || ! printf '%s\n' "$OUT" | grep -q 'AETHERGRAM_RELEASE=banana is not X.Y.Z'; then
    printf '%s\n' "$OUT"
    fail "an override of banana exited $GATE_RC rather than 2"
elif ! AETHERGRAM_RELEASE=0.4.0 "$ROOT/Scripts/run-checks.sh" --validate-only >/dev/null 2>&1; then
    fail "an override of 0.4.0 was refused too, so the refusal is not about the value"
else
    pass
fi

it "a release the api gate cannot read is refused rather than defaulted"
OUT="$(release_gate banana --base v0.3.1 --head v0.3.2 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 2 ] || ! printf '%s\n' "$OUT" | grep -q 'release banana is not X.Y.Z'; then
    printf '%s\n' "$OUT"
    fail "the gate exited $GATE_RC rather than 2 on a release of banana"
else
    pass
fi

# v0.3.0 carries no CHANGELOG.md, so the gate can only refuse its break as a patch, rather than
# stop for want of a heading, if the override reached it.
it "the release override reaches the gate in place of the CHANGELOG's"
OUT="$(release_gate 0.2.2 --base v0.2.1 --head v0.3.0 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 1 ] || ! printf '%s\n' "$OUT" | grep -q 'releasing 0.2.2 (patch)'; then
    printf '%s\n' "$OUT"
    fail "an override of 0.2.2 exited $GATE_RC rather than refusing the break as a patch"
elif ! OUT="$(release_gate "" --base v0.3.1 --head v0.3.2 2>&1)" \
    || ! printf '%s\n' "$OUT" | grep -q 'releasing 0.3.2 (patch)'; then
    printf '%s\n' "$OUT"
    fail "with no override the gate did not read the release from v0.3.2's CHANGELOG"
else
    pass
fi

if [ -n "$RELEASE_OVERRIDE" ]; then
    it "the working tree breaks nothing release $RELEASE_OVERRIDE may not break"
else
    it "the working tree breaks nothing its CHANGELOG entry does not allow"
fi
if OUT="$(release_gate "$RELEASE_OVERRIDE" --print-additions 2>&1)"; then
    printf '%s\n' "$OUT" | sed 's/^/        /'
    pass
else
    printf '%s\n' "$OUT"
    fail "Scripts/check-api-breaks.sh refused the working tree against the last release"
fi

printf '\nrelease heading gate\n'

# CI runs the check on a tag push only, so every refusal it can make is proved here, on each run.
heading_gate() { "$ROOT/Scripts/check-release-heading.sh" "$1" --changelog "$2"; }
EM="$(printf '\342\200\224')"
heading_fixture() { printf '# Changelog\n\nIntro.\n\n%s\n\nBody.\n\n## 0.3.2 %s 2026-09-23\n' "$1" "$EM" > "$2"; }

it "the tag v0.3.2 was cut from matches its own CHANGELOG's heading"
git -C "$ROOT" show v0.3.2:CHANGELOG.md > "$TMP/changelog-v0.3.2" 2>/dev/null
if OUT="$(heading_gate v0.3.2 "$TMP/changelog-v0.3.2" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the heading gate refused the CHANGELOG v0.3.2 shipped with"
fi

it "a heading naming another release, one with no date, or a hyphen for the dash is refused"
MISSING=""
for CASE in "## 0.3.2 $EM 2026-09-23|the top heading is" "## 0.4.0|is not" "## 0.4.0 - 2026-09-23|is not" \
    "## Unreleased|the top heading is" "## 0.4.0 $EM soon|is not"; do
    HEADING="${CASE%|*}"; REASON="${CASE##*|}"
    heading_fixture "$HEADING" "$TMP/changelog-bad"
    OUT="$(heading_gate v0.4.0 "$TMP/changelog-bad" 2>&1)"; GATE_RC=$?
    { [ "$GATE_RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "$REASON"; } \
        || MISSING="$MISSING [$HEADING: exit $GATE_RC, $OUT]"
done
heading_fixture "## 0.4.0 $EM 2026-10-01" "$TMP/changelog-good"
if [ -n "$MISSING" ]; then
    fail "not refused as expected:$MISSING"
elif ! OUT="$(heading_gate v0.4.0 "$TMP/changelog-good" 2>&1)"; then
    printf '%s\n' "$OUT"
    fail "the same fixture with a dated 0.4.0 heading was refused, so the refusals are not about the heading"
else
    pass
fi

it "a tag that is not vX.Y.Z cannot run the heading gate"
OUT="$(heading_gate 0.4.0 "$TMP/changelog-good" 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 2 ]; then
    printf '%s\n' "$OUT"
    fail "a tag with no v exited $GATE_RC rather than 2"
else
    pass
fi

printf '\ndocumentation gate\n'

# Swift Package Index builds the docs with a DocC plugin it injects, since the package takes no
# dependency, not even that one. So they are built here from each module's symbol graph with docc's
# warnings as errors, which is what makes an unresolved symbol link fail. The api gate's build
# directory is reused, warm.
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)" || MAC_SDK=""
DOC_TARGET="$(uname -m)-apple-macosx$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
docs_gate() {
    _pkg="$1"; _build="$2"; _out="$3"
    [ -n "$MAC_SDK" ] || { printf 'xcrun found no macosx SDK\n'; return 1; }
    swift build --package-path "$_pkg" --scratch-path "$_build" --target AethergramTelemetryDeck || return 1
    _bin="$(swift build --package-path "$_pkg" --scratch-path "$_build" --show-bin-path)" || return 1
    for _m in AethergramCore AethergramTelemetryDeck; do
        rm -rf "$_out/$_m" && mkdir -p "$_out/$_m/graphs" || return 1
        xcrun swift-symbolgraph-extract -module-name "$_m" -I "$_bin/Modules" -target "$DOC_TARGET" \
            -sdk "$MAC_SDK" -minimum-access-level public -module-cache-path "$_bin/ModuleCache" \
            -output-dir "$_out/$_m/graphs" || return 1
        # A catalog is optional; without one the module's page comes from its symbols alone.
        set --
        for _catalog in "$_pkg/Sources/$_m"/*.docc; do [ -d "$_catalog" ] && set -- "$_catalog"; done
        xcrun docc convert "$@" --additional-symbol-graph-dir "$_out/$_m/graphs" \
            --fallback-display-name "$_m" --fallback-bundle-identifier "$_m" \
            --output-path "$_out/$_m/$_m.doccarchive" --warnings-as-errors || return 1
    done
}

it "a doc comment linking a symbol that does not exist is refused"
BAD="$TMP/broken-doc-link"
copy_package "$BAD"
printf '/// Links ``NoSuchSymbolProbe``.\npublic enum BrokenDocLinkProbe {}\n' > "$BAD/Sources/AethergramCore/BrokenDocLink.swift"
OUT="$(docs_gate "$BAD" "$API/build" "$BAD.docs" 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then
    fail "documentation with an unresolved symbol link built"
elif ! printf '%s\n' "$OUT" | grep -q 'NoSuchSymbolProbe'; then
    printf '%s\n' "$OUT"
    fail "the documentation build failed for a reason other than the link"
else
    pass
fi

it "the documentation builds with no warnings"
if OUT="$(docs_gate "$ROOT" "$API/build" "$TMP/docs" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "docc refused the documentation"
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
