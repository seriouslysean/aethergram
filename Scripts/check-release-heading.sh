#!/bin/sh
# Refuse to cut a tag the CHANGELOG does not describe.
#
#   Scripts/check-release-heading.sh <vX.Y.Z> [--changelog <file>]
#
# The top `## ` heading of CHANGELOG.md must be `## X.Y.Z — YYYY-MM-DD` for the tag being cut: the
# version equal to the tag's, and the date present, in the shape every earlier entry uses. The api
# gate reads its release from that heading, so a tag cut over the previous release's heading was
# gated as a patch.
#
# Exit 0: the heading names the tag and a date. 1: it does not. 2: the check could not run.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf 'release heading: %s\n' "$1" >&2; exit 2; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: check-release-heading.sh <vX.Y.Z> [--changelog <file>]"
shift
CHANGELOG="$ROOT/CHANGELOG.md"
while [ $# -gt 0 ]; do
    case "$1" in
        --changelog) CHANGELOG="${2:-}"; shift 2 || exit 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "tag $TAG is not vX.Y.Z"
VERSION="${TAG#v}"
[ -r "$CHANGELOG" ] || die "no changelog at $CHANGELOG"

TOP="$(sed -n '/^## /{p;q;}' "$CHANGELOG")"
[ -n "$TOP" ] || die "$CHANGELOG has no ## heading"

# The dash is U+2014, as in every entry before it; the bytes are matched, so no locale is needed.
DASH="$(printf '\342\200\224')"
DATE="$(printf '%s\n' "$TOP" | sed -n 's/.* \([0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]\)$/\1/p')"
if [ -n "$DATE" ] && [ "$TOP" = "## $VERSION $DASH $DATE" ]; then
    printf 'release heading: %s matches %s\n' "$TOP" "$TAG"
    exit 0
fi

HEADING_VERSION="$(printf '%s\n' "$TOP" | sed -n 's/^## \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
if [ "$HEADING_VERSION" != "$VERSION" ]; then
    printf 'release heading: the top heading is "%s", but the tag is %s\n' "$TOP" "$TAG"
else
    printf 'release heading: "%s" is not "## %s %s YYYY-MM-DD"\n' "$TOP" "$VERSION" "$DASH"
fi
exit 1
