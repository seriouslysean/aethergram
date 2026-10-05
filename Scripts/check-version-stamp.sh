#!/bin/sh
# Refuse a stamped version the CHANGELOG's top heading does not name.
#
#   Scripts/check-version-stamp.sh [--source <file>] [--changelog <file>]
#
# `Aethergram.version` is stamped on every signal as `sdk.version`, and it is the package's release
# version. The top `## X.Y.Z` heading of CHANGELOG.md names the release being prepared, or the last
# one cut, so the two agree on every commit. check-release-heading.sh holds that heading to the tag
# being cut, which is what makes all three agree on a release.
#
# Exit 0: the constant is the heading's version. 1: it is not. 2: the check could not run.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf 'version stamp: %s\n' "$1" >&2; exit 2; }

SOURCE="$ROOT/Sources/AethergramCore/Aethergram.swift"
CHANGELOG="$ROOT/CHANGELOG.md"
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE="${2:-}"; shift 2 || exit 2 ;;
        --changelog) CHANGELOG="${2:-}"; shift 2 || exit 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -r "$SOURCE" ] || die "no source at $SOURCE"
[ -r "$CHANGELOG" ] || die "no changelog at $CHANGELOG"

# Exactly one declaration, and a literal: none or two leaves no one constant to hold to the heading,
# and a computed value is one this check cannot read.
DECLARATIONS="$(grep -c '^[[:space:]]*static let version[[:space:]:=]' "$SOURCE")"
[ "$DECLARATIONS" -eq 1 ] || die "$SOURCE declares \`static let version\` $DECLARATIONS times, not once"
STAMP="$(sed -n 's/^[[:space:]]*static let version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"[[:space:]]*$/\1/p' "$SOURCE")"
[ -n "$STAMP" ] || die "the declaration in $SOURCE is not \`static let version = \"X.Y.Z\"\`"

TOP="$(sed -n '/^## /{p;q;}' "$CHANGELOG")"
[ -n "$TOP" ] || die "$CHANGELOG has no ## heading"
HEADING_VERSION="$(printf '%s\n' "$TOP" | sed -n 's/^## \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"

if [ "$STAMP" = "$HEADING_VERSION" ]; then
    printf 'version stamp: Aethergram.version %s is the release in "%s"\n' "$STAMP" "$TOP"
    exit 0
fi

printf 'version stamp: Aethergram.version is %s, but the top heading is "%s"\n' "$STAMP" "$TOP"
exit 1
