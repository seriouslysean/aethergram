#!/bin/sh
# Refuse to publish anything that identifies a consuming app, a person, or a machine.
#
# This repo is public and the apps that use it are not. The leak is prose, not code: the transport
# gets edited from inside a consumer, so a comment written in that context can carry a private app
# name or an issue number into a public commit.
#
# It matches shapes: paths, addresses, and references that point outside this repo. It reads
# tracked files, so an unstaged file is invisible to it -- the pre-commit hook runs after staging,
# which is where the shapes it guards actually reach a commit.
#
# A bare app name with no surrounding shape is beyond this scanner: the pattern that would catch it
# matches every ordinary word, and a deny-list tracked here would itself carry the names it
# protects. That shape rests on review of the diff.
#
#   test/no-leaks.sh          scan tracked files
#   test/no-leaks.sh --all    also scan every commit message in history

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
FOUND=0

scan() {
    _what="$1"; _re="$2"
    # Exclude this file and the suite: they contain the patterns by definition.
    _hits="$(git grep -nE "$_re" -- . ':!test/no-leaks.sh' ':!test/run.sh' 2>/dev/null)"
    [ -n "$_hits" ] && printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  %s: %s\n' "$_what" "$_l"; done
    # A leak can live entirely in a tracked filename with clean content, invisible to git grep above.
    _names="$(git ls-files -- . ':!test/no-leaks.sh' ':!test/run.sh' | grep -E "$_re" 2>/dev/null)"
    [ -n "$_names" ] && printf '%s\n' "$_names" | while IFS= read -r _n; do printf '  %s (filename): %s\n' "$_what" "$_n"; done
    [ -z "$_hits" ] && [ -z "$_names" ]
}

printf 'scanning tracked files\n'

scan "absolute home path" '/Users/[a-zA-Z0-9]|/home/[a-zA-Z]' || FOUND=1
scan "email address" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' || FOUND=1
# owner/repo#123 pointing somewhere else is how one repo's issue history reaches a public commit.
scan "cross-repo issue reference" '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+' || FOUND=1
# A bare three-or-more-digit issue number is almost never this repo's, which numbers from 1.
scan "foreign issue number" '#[0-9]{3,}' || FOUND=1
# Decision-record and ruling ids point into a private doc tree and mean nothing published.
scan "private record reference" '(DR|RL)-[0-9]{3}' || FOUND=1

if [ "${1:-}" = "--all" ]; then
    printf 'scanning commit messages\n'
    _hits="$(git log --all --format='%H %s%n%b' 2>/dev/null \
        | grep -nE '/Users/[a-zA-Z0-9]|/home/[a-zA-Z]|[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+|#[0-9]{3,}')"
    [ -n "$_hits" ] && { printf '%s\n' "$_hits" | head -20; FOUND=1; }
fi

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
