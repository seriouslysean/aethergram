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
# Exit 0: the constant is the heading's version. 1: it is not, which includes a heading that names
# no release. 2: the check could not run.

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
# and a computed value is one this check cannot read. Every line naming the constant counts,
# whatever precedes it, so a declaration's text in a comment cannot stand in for the real one.
DECLARATIONS="$(grep -cE 'static[[:space:]]+(let|var)[[:space:]]+version[[:space:]:=]' "$SOURCE")"
[ "$DECLARATIONS" -eq 1 ] || die "$SOURCE names \`static let version\` on $DECLARATIONS lines, not one"
STAMP="$(sed -n 's/^[[:space:]]*static let version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"[[:space:]]*$/\1/p' "$SOURCE")"
[ -n "$STAMP" ] || die "the declaration in $SOURCE is not \`static let version = \"X.Y.Z\"\`"

# A tab after the hashes is a heading too, and skipping one would read the release under it.
TOP="$(sed -n '/^##[[:space:]]/{p;q;}' "$CHANGELOG")"
[ -n "$TOP" ] || die "$CHANGELOG has no ## heading"
# The heading's first word, whole: `2.1.0x` and `2.1.0.1` name no release, where a prefix would
# read both as 2.1.0.
HEADING_VERSION="$(printf '%s\n' "$TOP" | sed 's/^##[[:space:]]*//; s/[[:space:]].*$//')"
printf '%s\n' "$HEADING_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || HEADING_VERSION=""

if [ "$STAMP" = "$HEADING_VERSION" ]; then
    printf 'version stamp: Aethergram.version %s is the release in "%s"\n' "$STAMP" "$TOP"
    exit 0
fi

printf 'version stamp: Aethergram.version is %s, but the top heading is "%s"\n' "$STAMP" "$TOP"
exit 1
