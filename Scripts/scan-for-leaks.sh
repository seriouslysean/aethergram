#!/bin/sh
# Refuse to publish anything that identifies a consuming app, a person, or a machine.
#
# This repo is public and the apps that use it are not. The leak is prose, not code: the transport
# gets edited from inside a consumer, so a comment written in that context can carry a private app
# name or an issue number into a public commit.
#
# It matches shapes: paths, addresses, and references that point outside this repo. It reads the
# index (`git grep --cached`), not the working tree, so it sees exactly what a commit would carry:
# staging a leak and then reverting the working copy does not make it invisible.
#
# A bare app name with no surrounding shape is beyond this scanner: the pattern that would catch it
# matches every ordinary word, and a deny-list tracked here would itself carry the names it
# protects. That shape rests on review of the diff.
#
#   scan-for-leaks.sh                 scan tracked files
#   scan-for-leaks.sh --all           also scan every commit message in history
#   scan-for-leaks.sh --message FILE  scan one commit message, for the commit-msg hook

set -u

# Resolve the message path against the caller's directory, before the cd below moves out of it.
MSG=""
if [ "${1:-}" = "--message" ]; then
    [ -n "${2:-}" ] || { printf 'usage: scan-for-leaks.sh --message FILE\n' >&2; exit 2; }
    MSG="$2"
    case "$MSG" in /*) ;; *) MSG="$PWD/$MSG" ;; esac
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
FOUND=0

# github.com/<owner>/<repo>/issues/<n> or /pull/<n> is the same cross-repo pointer as
# owner/repo#123, spelled as a URL. Defined once so the file tier and MESSAGE_RE agree.
ISSUE_URL_RE='github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/(issues|pull)/[0-9]+'

# What a message must not carry: the tracked-file shapes, plus the trailer keys that only ever
# appear in one. Trailers stay out of the file tier, where a doc naming the shape would refuse
# itself.
MESSAGE_RE="/Users/[a-zA-Z0-9]|/home/[a-zA-Z]|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+|#[0-9]{3,}|(DR|RL)-[0-9]{3}|$ISSUE_URL_RE|^(Co-authored-by|[A-Za-z][A-Za-z0-9-]*-Session(-Id)?):"

# GitHub writes two subjects itself, on a web merge that runs no hook: `Merge pull request #N from
# <owner>/<branch>` and a squash subject ending ` (#N)`. The first number past 99 would otherwise
# fail every later history scan, and history cannot be rewritten. Only that number, in that place on
# a subject, is removed before the scan; the rest of the subject is still read. A line may carry the
# `%H ` prefix the history tier adds.
MERGE_SUBJECT_SED='s/^\([0-9a-f]\{40,64\} \)\{0,1\}Merge pull request #[0-9][0-9]* \(from seriouslysean\/[^ ][^ ]*\)$/\1Merge pull request \2/'
SQUASH_SUBJECT_SED='s/ (#[0-9][0-9]*)$//'

scan() {
    _what="$1"; _re="$2"
    # Exclude this file and the runner: they contain the patterns by definition.
    _hits="$(git grep --cached -nE "$_re" -- . ':!Scripts/scan-for-leaks.sh' ':!Scripts/run-checks.sh' 2>/dev/null)"
    [ -n "$_hits" ] && printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  %s: %s\n' "$_what" "$_l"; done
    # A leak can live entirely in a tracked filename with clean content, invisible to git grep above.
    _names="$(git ls-files -- . ':!Scripts/scan-for-leaks.sh' ':!Scripts/run-checks.sh' | grep -E "$_re" 2>/dev/null)"
    [ -n "$_names" ] && printf '%s\n' "$_names" | while IFS= read -r _n; do printf '  %s (filename): %s\n' "$_what" "$_n"; done
    [ -z "$_hits" ] && [ -z "$_names" ]
}

# One tier, two callers: the commit-msg hook reads the message being written, the release sweep
# reads every message already in history.
scan_messages() {
    _hits="$(printf '%s\n' "$1" | grep -nE "$MESSAGE_RE")"
    [ -z "$_hits" ] && return 0
    printf '%s\n' "$_hits" | head -20 | while IFS= read -r _l; do printf '  message: %s\n' "$_l"; done
    return 1
}

if [ -n "$MSG" ]; then
    printf 'scanning the commit message\n'
    # `commit -v` appends the staged diff below a scissors line, which is never part of the
    # published message, so that gets cut first. Nothing after is comment-stripped: whether git
    # itself drops a `#` line depends on commit.cleanup (default "strip" for an editor commit,
    # "whitespace" for `-m`), and a line `-m` keeps must still be caught here.
    scan_messages "$(sed '/^#\{0,1\} *-\{2,\} >8 -\{2,\}/,$d' "$MSG" \
        | sed -e "1$MERGE_SUBJECT_SED" -e "1$SQUASH_SUBJECT_SED")" || FOUND=1
    if [ "$FOUND" -eq 0 ]; then
        printf 'clean\n'
        exit 0
    fi
    printf '\nrefusing: the above would be published.\n'
    exit 1
fi

printf 'scanning tracked files\n'

scan "absolute home path" '/Users/[a-zA-Z0-9]|/home/[a-zA-Z]' || FOUND=1
scan "email address" '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' || FOUND=1
# owner/repo#123 pointing somewhere else is how one repo's issue history reaches a public commit.
scan "cross-repo issue reference" '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+' || FOUND=1
# A bare three-or-more-digit issue number is almost never this repo's, which numbers from 1.
scan "foreign issue number" '#[0-9]{3,}' || FOUND=1
# Decision-record and ruling ids point into a private doc tree and mean nothing published.
scan "private record reference" '(DR|RL)-[0-9]{3}' || FOUND=1
scan "issue or pull request URL" "$ISSUE_URL_RE" || FOUND=1

if [ "${1:-}" = "--all" ]; then
    printf 'scanning commit messages\n'
    # Subjects and bodies are read apart, so GitHub's shapes are forgiven on a subject and nowhere else.
    scan_messages "$(git log --all --format='%H %s' 2>/dev/null \
        | sed -e "$MERGE_SUBJECT_SED" -e "$SQUASH_SUBJECT_SED")" || FOUND=1
    scan_messages "$(git log --all --format='%H%n%b' 2>/dev/null)" || FOUND=1
fi

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
