#!/bin/sh
# Refuse a change to the public API that the release being prepared is not allowed to make.
#
#   Scripts/check-api-breaks.sh [--base <tag>] [--head <ref>] [--release <X.Y.Z>] [--scratch <dir>]
#
# `swift package diagnose-api-breaking-changes` reports nothing here: the only product is an
# umbrella that declares nothing, and the modules behind it get no baseline. So each module is
# dumped with `swift-api-digester -dump-sdk` at the base and at the head, and the two dumps are
# diagnosed against each other. The digester reports removals and changes; it never reports an
# addition, so an addition slipping into a patch passes this gate.
#
#   --base     the release to compare against, a `vX.Y.Z` tag. Default: the latest one reachable
#              from HEAD.
#   --head     the ref to check. Default: the working tree, uncommitted edits included.
#   --release  the version being prepared. Default: the version in the top `## X.Y.Z` heading of
#              CHANGELOG.md at the head. A heading equal to the base means no release entry has
#              been written yet, which is read as a patch, since a patch is what an undeclared
#              change is allowed to be.
#   --scratch  where builds and dumps go. A commit's dump is keyed by its hash, so runs sharing a
#              directory build each commit once, and every build shares one build directory, so
#              the SDK's module cache is built once. Default: a temp directory removed on exit.
#
# A break passes only when the release moves the major, or on 0.x the minor, per STABILITY.md.
# Exit 0: no break, or breaks the release may make. 1: a break the release may not make.
# 2: the gate could not run, which is never a pass.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="AethergramTelemetryDeck"
MODULES="AethergramCore $ADAPTER"

BASE=""
HEAD=""
RELEASE=""
SCRATCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 || exit 2 ;;
        --head) HEAD="${2:-}"; shift 2 || exit 2 ;;
        --release) RELEASE="${2:-}"; shift 2 || exit 2 ;;
        --scratch) SCRATCH="${2:-}"; shift 2 || exit 2 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

die() { printf 'api gate: %s\n' "$1" >&2; exit 2; }

if [ -z "$SCRATCH" ]; then
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aethergram-api.XXXXXX")" || die "no temp directory"
    trap 'rm -rf "$SCRATCH"' EXIT
fi
mkdir -p "$SCRATCH" || die "cannot create $SCRATCH"

is_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# No `sort -V` under dash: compare field by field. Prints -1, 0, or 1.
compare_versions() {
    _a="$1"; _b="$2"
    for _i in 1 2 3; do
        _x="$(printf '%s' "$_a" | cut -d. -f"$_i")"
        _y="$(printf '%s' "$_b" | cut -d. -f"$_i")"
        [ "$_x" -gt "$_y" ] && { echo 1; return; }
        [ "$_x" -lt "$_y" ] && { echo -1; return; }
    done
    echo 0
}

[ -n "$BASE" ] || BASE="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null)" \
    || die "no release tag reachable from HEAD; a shallow or tagless clone cannot run this gate"
BASE_VERSION="${BASE#v}"
is_version "$BASE_VERSION" || die "base $BASE is not a vX.Y.Z tag"
BASE_SHA="$(git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}")" || die "no commit for $BASE"

if [ -n "$HEAD" ]; then
    HEAD_SHA="$(git -C "$ROOT" rev-parse --verify --quiet "$HEAD^{commit}")" || die "no commit for $HEAD"
fi

if [ -z "$RELEASE" ]; then
    if [ -n "$HEAD" ]; then
        CHANGELOG="$(git -C "$ROOT" show "$HEAD_SHA:CHANGELOG.md" 2>/dev/null)" || die "no CHANGELOG.md at $HEAD"
    else
        CHANGELOG="$(cat "$ROOT/CHANGELOG.md" 2>/dev/null)" || die "no CHANGELOG.md"
    fi
    TOP="$(printf '%s\n' "$CHANGELOG" | sed -n '/^## /{p;q;}')"
    RELEASE="$(printf '%s\n' "$TOP" | sed -n 's/^## \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    # An `## Unreleased` heading says nothing about what the release may break, so it cannot pass.
    is_version "$RELEASE" || die "CHANGELOG.md's top heading carries no X.Y.Z version: '$TOP'"
fi
is_version "$RELEASE" || die "release $RELEASE is not X.Y.Z"
[ "$(compare_versions "$RELEASE" "$BASE_VERSION")" -ge 0 ] \
    || die "release $RELEASE is older than the base $BASE"

R_MAJOR="$(printf '%s' "$RELEASE" | cut -d. -f1)"; R_MINOR="$(printf '%s' "$RELEASE" | cut -d. -f2)"
B_MAJOR="$(printf '%s' "$BASE_VERSION" | cut -d. -f1)"; B_MINOR="$(printf '%s' "$BASE_VERSION" | cut -d. -f2)"
if [ "$R_MAJOR" -gt "$B_MAJOR" ]; then
    MAY_BREAK=1; KIND="major"
elif [ "$R_MAJOR" -eq 0 ] && [ "$R_MINOR" -gt "$B_MINOR" ]; then
    MAY_BREAK=1; KIND="0.x minor"
elif [ "$R_MINOR" -gt "$B_MINOR" ]; then
    MAY_BREAK=0; KIND="minor"
else
    MAY_BREAK=0; KIND="patch"
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)" || die "xcrun found no macOS SDK"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)" || die "xcrun found no macOS SDK version"
# The SDK's own version rather than the package's floor: a module built for any earlier floor
# loads under it, so a tag that raised the floor still dumps.
DUMP_TARGET="$(uname -m)-apple-macosx$SDK_VERSION"

# Builds the package at $1 in build directory $2 and dumps each module's public API into $3.
dump_package() {
    _pkg="$1"; _build="$2"; _out="$3"
    mkdir -p "$_out"
    _bin="$(swift build --package-path "$_pkg" --scratch-path "$_build" --show-bin-path)" || return 1
    # The build directory is shared between packages, so a module the previous one left behind
    # must not stand in for one this package failed to produce.
    for _m in $MODULES; do rm -rf "$_bin/Modules/$_m".* "$_bin/$_m".swiftmodule; done
    # The adapter depends on the core, so one target builds both.
    if ! _log="$(swift build --package-path "$_pkg" --scratch-path "$_build" --target "$ADAPTER" 2>&1)"; then
        printf '%s\n' "$_log" >&2
        return 1
    fi
    for _m in $MODULES; do
        # Without -abort-on-module-fail a module that fails to load dumps as an empty root and
        # exits 0, which would diagnose as an API with nothing in it to break.
        xcrun swift-api-digester -dump-sdk -abort-on-module-fail -module "$_m" \
            -I "$_bin/Modules" -I "$_bin" -sdk "$SDK" -target "$DUMP_TARGET" \
            -o "$_out/$_m.json" >&2 || return 1
        grep -q '"kind": "TypeDecl"' "$_out/$_m.json" || {
            printf 'api gate: the dump of %s declares no type\n' "$_m" >&2
            return 1
        }
    done
}

# A tagged commit is dumped once per scratch directory; the working tree is dumped every run.
dump_commit() {
    _sha="$1"; _dir="$SCRATCH/$_sha"
    [ -f "$_dir/dumped" ] && return 0
    rm -rf "$_dir" && mkdir -p "$_dir/src" || return 1
    # An archive rather than a worktree, so nothing is registered in the caller's repository.
    git -C "$ROOT" archive -o "$_dir/src.tar" "$_sha" && tar -x -f "$_dir/src.tar" -C "$_dir/src" || return 1
    dump_package "$_dir/src" "$SCRATCH/build" "$_dir/api" || return 1
    : > "$_dir/dumped"
}

dump_commit "$BASE_SHA" || die "could not dump $BASE"
BASE_API="$SCRATCH/$BASE_SHA/api"
if [ -n "$HEAD" ]; then
    dump_commit "$HEAD_SHA" || die "could not dump $HEAD"
    HEAD_API="$SCRATCH/$HEAD_SHA/api"
    HEAD_NAME="$HEAD"
else
    HEAD_API="$SCRATCH/worktree/api"
    rm -rf "$HEAD_API"
    dump_package "$ROOT" "$SCRATCH/build" "$HEAD_API" || die "could not dump the working tree"
    HEAD_NAME="the working tree"
fi

printf 'api: %s -> %s, releasing %s (%s)\n' "$BASE" "$HEAD_NAME" "$RELEASE" "$KIND"
TOTAL=0
for M in $MODULES; do
    REPORT="$SCRATCH/diagnose-$M.txt"
    rm -f "$REPORT"
    xcrun swift-api-digester -diagnose-sdk --input-paths "$BASE_API/$M.json" \
        --input-paths "$HEAD_API/$M.json" -o "$REPORT" >/dev/null 2>&1
    # The report is section headers with findings between them. No headers means the diagnose
    # never ran, and reading that as "no findings" is a gate that cannot fire.
    grep -q '^/\* Removed Decls \*/$' "$REPORT" 2>/dev/null || die "the diagnose of $M produced no report"
    BREAKS="$(grep -v '^/\*' "$REPORT" | grep -v '^[[:space:]]*$')"
    if [ -z "$BREAKS" ]; then
        printf '  %s: no breaks\n' "$M"
    else
        COUNT="$(printf '%s\n' "$BREAKS" | wc -l | tr -d ' ')"
        TOTAL=$((TOTAL + COUNT))
        printf '  %s: %s breaks\n' "$M" "$COUNT"
        printf '%s\n' "$BREAKS" | sed 's/^/    /'
    fi
done

if [ "$TOTAL" -gt 0 ] && [ "$MAY_BREAK" -eq 0 ]; then
    printf 'api: %s breaks, and a %s release may not break the API. Declare the release in CHANGELOG.md or restore the API.\n' \
        "$TOTAL" "$KIND"
    exit 1
fi
exit 0
