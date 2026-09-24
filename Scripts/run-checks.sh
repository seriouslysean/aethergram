#!/bin/sh
# Aethergram repo checks. The gates run in the order a failure is cheapest to read.
#
#   Scripts/run-checks.sh    offline, no network; needs the release tags, so not a shallow clone
#
# The leak scan runs first because it is milliseconds and its failure is about what is committed
# rather than what the code does. The commit-message gate is proved next on known-bad input, since
# a gate that never fires looks exactly like one that passes. The build gates compile what the suite
# cannot reach, the consumer fixture compiles what a host writes, the api-break gate holds
# the public API to what the release being prepared may change, the release heading gate is proved
# on the refusals a tag push would make, and `swift test` is the correctness gate.

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

# Apple reads an SDK's manifest out of the bundle it ships in, so it is checked where the build put
# it rather than only where it is committed. Apple's "collect" is transmitting off the device: the
# adapter transmits and the core never does, so the declaration ships in the adapter's bundle alone.
MANIFEST="Sources/AethergramTelemetryDeck/PrivacyInfo.xcprivacy"
ADAPTER_BUNDLE="Aethergram_AethergramTelemetryDeck.bundle"

# `raw` prints a bool as true or false, an array as its count, and a dictionary as its keys sorted,
# one a line; `-expect` refuses a value of another type, so a string "false" is not a bool.
plist_raw() { plutil -extract "$2" raw -expect "$3" -o - "$1" 2>/dev/null; }

# Every reason a manifest is not the adapter's declaration, one a line; nothing when it is. The
# declaration is TelemetryDeck's SDK's at 2.14.1, which sends the same hashed identifier. That SDK's
# UserDefaults reason covers its own reads; this package calls no required-reason API.
manifest_refusals() {
    _m="$1"
    [ -f "$_m" ] || { printf 'no file\n'; return; }
    plutil -lint "$_m" >/dev/null 2>&1 || { printf 'not a valid property list\n'; return; }
    # A key path cannot name the root, so its keys are read from a copy nested one level down.
    _root="$TMP/manifest-root.plist"
    rm -f "$_root"
    _keys="$(plutil -create xml1 "$_root" \
        && plutil -insert m -json "$(plutil -convert json -o - "$_m")" "$_root" \
        && plist_raw "$_root" m dictionary)"
    [ "$_keys" = "$(printf '%s\n' NSPrivacyAccessedAPITypes NSPrivacyCollectedDataTypes \
        NSPrivacyTracking NSPrivacyTrackingDomains)" ] \
        || printf 'the top-level keys are [%s]\n' "$(printf '%s' "$_keys" | tr '\n' ' ')"
    [ "$(plist_raw "$_m" NSPrivacyTracking bool)" = false ] || printf 'NSPrivacyTracking is not false\n'
    [ "$(plist_raw "$_m" NSPrivacyTrackingDomains array)" = 0 ] \
        || printf 'NSPrivacyTrackingDomains is not an empty array\n'
    [ "$(plist_raw "$_m" NSPrivacyAccessedAPITypes array)" = 0 ] \
        || printf 'NSPrivacyAccessedAPITypes is not an empty array\n'
    _count="$(plist_raw "$_m" NSPrivacyCollectedDataTypes array)"
    [ "$_count" = 2 ] \
        || printf 'NSPrivacyCollectedDataTypes holds %s types rather than 2\n' "${_count:-no array of}"
    _i=0
    _types=""
    while [ "$_i" -lt "${_count:-0}" ]; do
        _e="NSPrivacyCollectedDataTypes.$_i"
        _t="$(plist_raw "$_m" "$_e.NSPrivacyCollectedDataType" string)"
        [ -n "$_t" ] || _t="entry $_i"
        [ "$(plist_raw "$_m" "$_e" dictionary)" = "$(printf '%s\n' NSPrivacyCollectedDataType \
            NSPrivacyCollectedDataTypeLinked NSPrivacyCollectedDataTypePurposes \
            NSPrivacyCollectedDataTypeTracking)" ] \
            || printf '%s: the keys are not exactly the four a collected type declares\n' "$_t"
        [ "$(plist_raw "$_m" "$_e.NSPrivacyCollectedDataTypeLinked" bool)" = false ] \
            || printf '%s: NSPrivacyCollectedDataTypeLinked is not false\n' "$_t"
        [ "$(plist_raw "$_m" "$_e.NSPrivacyCollectedDataTypeTracking" bool)" = false ] \
            || printf '%s: NSPrivacyCollectedDataTypeTracking is not false\n' "$_t"
        { [ "$(plist_raw "$_m" "$_e.NSPrivacyCollectedDataTypePurposes" array)" = 1 ] \
            && [ "$(plist_raw "$_m" "$_e.NSPrivacyCollectedDataTypePurposes.0" string)" \
                = NSPrivacyCollectedDataTypePurposeAnalytics ]; } \
            || printf '%s: NSPrivacyCollectedDataTypePurposes is not analytics alone\n' "$_t"
        _types="$_types$_t
"
        _i=$((_i + 1))
    done
    [ "$(printf '%s' "$_types" | LC_ALL=C sort)" = "$(printf '%s\n' NSPrivacyCollectedDataTypeDeviceID \
        NSPrivacyCollectedDataTypeProductInteraction)" ] \
        || printf 'the types are [%s] rather than Device ID and Product Interaction once each\n' \
            "$(printf '%s' "$_types" | paste -s -d ' ' -)"
}

it "a malformed privacy manifest is refused"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>NSPrivacyTracking</key></dict>\n' > "$TMP/bad.xcprivacy"
if plutil -lint "$TMP/bad.xcprivacy" >/dev/null 2>&1; then
    fail "plutil accepted a manifest with no closing plist element and a key with no value"
else
    pass
fi

it "a manifest declaring a linked type, or a type beyond the two, is refused"
# Copies of the committed manifest, each broken one way, so each refusal is read for its own reason.
if [ -n "$(manifest_refusals "$ROOT/$MANIFEST")" ]; then
    fail "$MANIFEST is itself refused, so refusing a copy of it proves nothing"
else
    cp "$ROOT/$MANIFEST" "$TMP/linked.xcprivacy"
    plutil -replace NSPrivacyCollectedDataTypes.0.NSPrivacyCollectedDataTypeLinked -bool YES "$TMP/linked.xcprivacy"
    cp "$ROOT/$MANIFEST" "$TMP/extra.xcprivacy"
    plutil -insert NSPrivacyCollectedDataTypes -json '{"NSPrivacyCollectedDataType":
        "NSPrivacyCollectedDataTypePurchaseHistory", "NSPrivacyCollectedDataTypeLinked": false,
        "NSPrivacyCollectedDataTypeTracking": false,
        "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAnalytics"]}' \
        -append "$TMP/extra.xcprivacy"
    LINKED="$(manifest_refusals "$TMP/linked.xcprivacy")"
    EXTRA="$(manifest_refusals "$TMP/extra.xcprivacy")"
    if ! printf '%s\n' "$LINKED" | grep -q 'NSPrivacyCollectedDataTypeLinked is not false'; then
        fail "a type marked linked was not refused as linked: [${LINKED:-accepted}]"
    elif ! printf '%s\n' "$EXTRA" | grep -q 'holds 3 types rather than 2'; then
        fail "a third type was not refused as one beyond the two: [${EXTRA:-accepted}]"
    else
        pass
    fi
fi

it "the privacy manifest declares no linked, tracking, or extra type, and no tracking or required-reason API"
REFUSALS="$(manifest_refusals "$ROOT/$MANIFEST")"
if [ -n "$REFUSALS" ]; then
    fail "$MANIFEST is not the declaration the adapter makes:
$(printf '%s\n' "$REFUSALS" | sed 's/^/           /')"
else
    pass
fi

it "the privacy manifest ships in the adapter's iOS bundle, and no other bundle carries one"
SOURCED="$(cd "$ROOT" && find Sources -name '*.xcprivacy')"
BUNDLED="$(find "$TMP/ios" -path "*/$ADAPTER_BUNDLE/PrivacyInfo.xcprivacy" 2>/dev/null | head -n 1)"
ELSEWHERE="$(find "$TMP/ios" -name '*.xcprivacy' ! -path "*/$ADAPTER_BUNDLE/*" 2>/dev/null)"
if [ "$SOURCED" != "$MANIFEST" ]; then
    fail "Sources holds [$(printf '%s' "$SOURCED" | tr '\n' ' ')] rather than $MANIFEST alone"
elif [ -z "$BUNDLED" ]; then
    fail "the iOS build produced no $ADAPTER_BUNDLE carrying PrivacyInfo.xcprivacy"
elif ! cmp -s "$ROOT/$MANIFEST" "$BUNDLED"; then
    fail "the bundled manifest differs from $MANIFEST"
elif [ -n "$ELSEWHERE" ]; then
    fail "the iOS build carries a manifest outside $ADAPTER_BUNDLE: [$(printf '%s' "$ELSEWHERE" | tr '\n' ' ')]"
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
# with no upcoming-feature flag: it compiles what a host writes. The build goes to a scratch path,
# never into the tree.
FIXTURE="$ROOT/Tests/Fixtures/ConsumerHost"
fixture_gate() { ios_build "$1" "$2" --target ConsumerHostExtension; }

it "the fixture builds for iOS release as extension-safe"
if OUT="$(fixture_gate "$FIXTURE" "$TMP/fixture-ios" 2>&1)"; then
    pass
else
    printf '%s\n' "$OUT"
    fail "the fixture did not build for iOS release with -application-extension"
fi

it "the fixture build compiles the host's code"
BAD="$TMP/unbuilt-fixture"
copy_package "$BAD"
mkdir -p "$BAD/Tests/Fixtures" && cp -R "$FIXTURE" "$BAD/Tests/Fixtures/"
rm -rf "$BAD/Tests/Fixtures/ConsumerHost/.build"
printf 'let hostProbe: Int = hostMarker\n' > "$BAD/Tests/Fixtures/ConsumerHost/Sources/ConsumerHostExtension/HostProbe.swift"
OUT="$(fixture_gate "$BAD/Tests/Fixtures/ConsumerHost" "$BAD.build" 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -eq 0 ] || ! printf '%s\n' "$OUT" | grep -q 'hostMarker'; then
    fail "the fixture build exited $GATE_RC and never reached the host's code"
else
    pass
fi

# `swift test` at the root must not run the fixture's suite as its own, or compile its sources.
root_takes_fixture() { swift package --package-path "$1" describe 2>&1 | grep -q 'Tests/Fixtures\|ConsumerHost'; }

it "the root package takes no target or source from the fixture"
BAD="$TMP/root-takes-fixture"
copy_package "$BAD"
mkdir -p "$BAD/Tests/Fixtures" && cp -R "$FIXTURE" "$BAD/Tests/Fixtures/"
rm -rf "$BAD/Tests/Fixtures/ConsumerHost/.build"
printf 'package.targets.append(.target(name: "FixtureProbe", path: "Tests/Fixtures/ConsumerHost/Sources/ConsumerHostExtension"))\n' \
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

it "the working tree breaks nothing its CHANGELOG entry does not allow"
if OUT="$(api_gate 2>&1)"; then
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

printf '\nswift test\n'

# Swift Testing's summary line; a run that matched nothing says 0, or prints no line at all.
tests_run() { printf '%s\n' "$1" | sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} .*/\1/p' | tail -n 1; }

# A floor rather than an exact count: suites grow in parallel lanes, and a floor only fails when
# tests go missing. Raise it when the suite grows; lower it only with the tests it lost named.
ROOT_TESTS_FLOOR=211
root_ran_enough() { [ "$1" -eq 0 ] && [ "$(tests_run "$2")" -ge "$ROOT_TESTS_FLOOR" ] 2>/dev/null; }

it "the package suite passes, running at least $ROOT_TESTS_FLOOR tests"
swift test --package-path "$ROOT" > "$TMP/root-tests.log" 2>&1; GATE_RC=$?
cat "$TMP/root-tests.log"
OUT="$(cat "$TMP/root-tests.log")"
if root_ran_enough "$GATE_RC" "$OUT"; then
    pass
else
    fail "swift test exited $GATE_RC having run $(tests_run "$OUT") tests; ROOT_TESTS_FLOOR is $ROOT_TESTS_FLOOR"
fi

# After the full run, so the build is warm. It exits 0 having run nothing.
it "a package run that executes no test is refused"
OUT="$(swift test --package-path "$ROOT" --filter NoSuchTestProbe 2>&1)"; GATE_RC=$?
if [ "$GATE_RC" -ne 0 ] || [ "$(tests_run "$OUT")" != 0 ]; then
    printf '%s\n' "$OUT"
    fail "the filtered run exited $GATE_RC or did not report 0 tests, so it proves nothing about the floor"
elif root_ran_enough "$GATE_RC" "$OUT"; then
    fail "a run of 0 tests passed the package suite's floor"
else
    pass
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
