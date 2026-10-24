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
#   scan-for-leaks.sh                     scan tracked files
#   scan-for-leaks.sh --range BASE HEAD   also scan the messages of BASE..HEAD, for CI; an all-zero
#                                         BASE (a new ref) scans HEAD's own message
#   scan-for-leaks.sh --all               also scan every commit message in history, as an audit
#   scan-for-leaks.sh --message FILE      scan one commit message, for the commit-msg hook

set -u
# Bytes are read as bytes. In a UTF-8 locale, a message in another encoding makes sed fail, and a
# read that fails leaves nothing to match.
LC_ALL=C
export LC_ALL

# Resolve the message path against the caller's directory, before the cd below moves out of it.
MSG=""
if [ "${1:-}" = "--message" ]; then
    [ -n "${2:-}" ] || { printf 'usage: scan-for-leaks.sh --message FILE\n' >&2; exit 2; }
    MSG="$2"
    case "$MSG" in /*) ;; *) MSG="$PWD/$MSG" ;; esac
fi
# CI fills both ends from the event, so an empty one is a run that lost its range, not an empty
# range: it fails rather than scanning nothing.
if [ "${1:-}" = "--range" ]; then
    [ $# -eq 3 ] && [ -n "$2" ] && [ -n "$3" ] || { printf 'usage: scan-for-leaks.sh --range BASE HEAD\n' >&2; exit 2; }
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
FOUND=0

# Every tier reads through git, and a git that cannot read the repo finds no hits: without this,
# a scan outside a work tree, or of one git refuses to trust, reports clean.
die() { printf 'scan-for-leaks: %s\n' "$1" >&2; exit 2; }
[ "$(git rev-parse --is-inside-work-tree)" = "true" ] || die "not inside a git work tree"

# github.com/<owner>/<repo>/issues/<n> or /pull/<n> is the same cross-repo pointer as
# owner/repo#N, spelled as a URL. Defined once so the file tier and MESSAGE_RE agree.
ISSUE_URL_RE='github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/(issues|pull)/[0-9]+'

# What a message must not carry: the tracked-file shapes, plus the trailer keys that only ever
# appear in one. Trailers stay out of the file tier, where a doc naming the shape would refuse
# itself. Their keys are matched in any case, and apart, because `-i` over the rest would let the
# record-id shape match inside ordinary words.
MESSAGE_RE="/Users/[a-zA-Z0-9]|/home/[a-zA-Z]|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+|#[0-9]{3,}|(DR|RL)-[0-9]{3}|$ISSUE_URL_RE"
TRAILER_RE='^[A-Za-z][A-Za-z0-9-]*-Session(-Id)?:'

# A co-author trailer in the form GitHub credits, a name and one address, names a person, and
# GitHub writes one for the owner on a squash merge whenever the commit author is not the pull
# request's. Its address is set aside before MESSAGE_RE reads the line, so the name is still
# scanned. Any other co-author line is refused, as is one naming an app account (`<slug>[bot]`)
# or an agent's own address: a no-reply mailbox, or the addresses Claude Code, Aider, Cursor and
# Copilot write. Both are matched against the lowercased line.
COAUTHOR_RE='^co-authored-by:[ ]*[^<> ][^<>]*<[^<> ]+@[^<> ]+>[ ]*$'
AGENT_COAUTHOR_RE='\[bot\]|<(no-?reply@[^>]*|[^>]*@(anthropic\.com|aider\.chat|cursor\.com|cursor\.sh)|copilot@github\.com|[0-9]+\+copilot@users\.noreply\.github\.com)>'

# GitHub writes one subject itself, on a web merge that runs no hook: `Merge pull request #N from
# <owner>/<branch>`. Its number past 99 would otherwise fail every later history scan, and history
# cannot be rewritten. Only that number, in that place, on the subject of a commit with two parents,
# is removed before the scan; the rest of the subject is still read. Lines carry the `%H ` prefix
# the history tier adds.
MERGE_SUBJECT_SED='s/^\([0-9a-f]\{40,64\} \)Merge pull request #[0-9][0-9]* \(from seriouslysean\/[^ ][^ ]*\)$/\1Merge pull request \2/'

scan() {
    _what="$1"; _re="$2"
    # git grep exits 1 for no match; anything past that is git failing, which is not a clean tree.
    _hits="$(git grep --cached -nE "$_re" -- .)"
    [ $? -le 1 ] || die "git grep failed"
    [ -n "$_hits" ] && printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '  %s: %s\n' "$_what" "$_l"; done
    # A leak can live entirely in a tracked filename with clean content, invisible to git grep above.
    _files="$(git ls-files -- .)" || die "git ls-files failed"
    _names="$(printf '%s\n' "$_files" | grep -E "$_re")"
    [ $? -le 1 ] || die "grep failed on the tracked filenames"
    [ -n "$_names" ] && printf '%s\n' "$_names" | while IFS= read -r _n; do printf '  %s (filename): %s\n' "$_what" "$_n"; done
    [ -z "$_hits" ] && [ -z "$_names" ]
}

# One tier, two callers: the commit-msg hook reads the message being written, the release sweep
# reads every message already in history.
scan_messages() {
    # The patterns reach awk through the environment, which, unlike -v, applies no escapes to them.
    _lines="$(printf '%s\n' "$1" | OK_RE="$COAUTHOR_RE" awk '
        tolower($0) ~ ENVIRON["OK_RE"] { sub(/<[^<>]*>[ ]*$/, "<>") } { print }')" \
        || die "awk failed on the message's co-author trailers"
    _coauthors="$(printf '%s\n' "$1" | OK_RE="$COAUTHOR_RE" AGENT_RE="$AGENT_COAUTHOR_RE" awk '
        { l = tolower($0) }
        l ~ /^co-authored-by:/ && (l !~ ENVIRON["OK_RE"] || l ~ ENVIRON["AGENT_RE"]) { print NR ":" $0 }')" \
        || die "awk failed on the message's co-author trailers"
    # grep exits 1 for no match; anything past that is grep failing, which is not a clean message.
    _plain="$(printf '%s\n' "$_lines" | grep -nE "$MESSAGE_RE")"
    [ $? -le 1 ] || die "grep failed on the message"
    _trailers="$(printf '%s\n' "$1" | grep -inE "$TRAILER_RE")"
    [ $? -le 1 ] || die "grep failed on the message's trailers"
    # A line more than one check matches is printed once.
    _hits="$(printf '%s\n%s\n%s\n' "$_plain" "$_trailers" "$_coauthors" | sed '/^$/d' | sort -t: -k1,1n -u)"
    [ -z "$_hits" ] && return 0
    printf '%s\n' "$_hits" | head -20 | while IFS= read -r _l; do printf '  message: %s\n' "$_l"; done
    return 1
}

if [ -n "$MSG" ]; then
    printf 'scanning the commit message\n'
    # `commit -v` appends the staged diff below a scissors line, which is never part of the
    # published message, so that gets cut first. Nothing after is comment-stripped: whether git
    # itself drops a `#` line depends on commit.cleanup (default "strip" for an editor commit,
    # "whitespace" for `-m`), and a line `-m` keeps must still be caught here. No subject is
    # forgiven either: a hook never sees one GitHub wrote, and a local merge writes `Merge branch`.
    _message="$(sed '/^#\{0,1\} *-\{2,\} >8 -\{2,\}/,$d' "$MSG")" || die "could not read the message"
    scan_messages "$_message" || FOUND=1
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
# owner/repo#N pointing somewhere else is how one repo's issue history reaches a public commit.
scan "cross-repo issue reference" '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+' || FOUND=1
# A bare three-or-more-digit issue number is almost never this repo's, which numbers from 1.
scan "foreign issue number" '#[0-9]{3,}' || FOUND=1
# Decision-record and ruling ids point into a private doc tree and mean nothing published.
scan "private record reference" '(DR|RL)-[0-9]{3}' || FOUND=1
scan "issue or pull request URL" "$ISSUE_URL_RE" || FOUND=1

# Subjects and bodies are read apart, and merge commits apart from the rest, so GitHub's merge
# subject is forgiven where GitHub writes it and nowhere else. Takes the revisions `git log` reads.
scan_history() {
    printf 'scanning commit messages\n'
    _merges="$(git log --merges --format='%H %s' "$@")" || die "git log failed"
    _subjects="$(git log --no-merges --format='%H %s' "$@")" || die "git log failed"
    _bodies="$(git log --format='%H%n%b' "$@")" || die "git log failed"
    scan_messages "$(printf '%s\n' "$_merges" | sed "$MERGE_SUBJECT_SED")" || FOUND=1
    scan_messages "$_subjects" || FOUND=1
    scan_messages "$_bodies" || FOUND=1
}

# An end the clone does not hold would make git log fail; checking first says which one.
commit_of() { git rev-parse --verify --quiet "$1^{commit}" || die "not a commit in this clone: $1"; }

case "${1:-}" in
--all) scan_history --all ;;
--range)
    _head="$(commit_of "$3")" || exit 2
    # GitHub sends an all-zero before, SHA-1 or SHA-256 wide, for a new ref: its own commit is what
    # the push adds, and its ancestors were judged when they landed.
    case "$2" in
    0000000000000000000000000000000000000000|0000000000000000000000000000000000000000000000000000000000000000)
        scan_history "$_head^!" ;;
    *) _base="$(commit_of "$2")" || exit 2; scan_history "$_base..$_head" ;;
    esac
    ;;
esac

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
