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

# Every tier reads through git, and a git that cannot read the repo finds no hits: without this,
# a scan outside a work tree, or of one git refuses to trust, reports clean.
die() { printf 'scan-for-leaks: %s\n' "$1" >&2; exit 2; }
[ "$(git rev-parse --is-inside-work-tree)" = "true" ] || die "not inside a git work tree"

# github.com/<owner>/<repo>/issues/<n> or /pull/<n> is the same cross-repo pointer as
# owner/repo#N, spelled as a URL. Defined once so the file tier and MESSAGE_RE agree.
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

# The runner's fixtures and this file's own entries below carry the shapes on purpose. Each is
# allowed as its exact `path:line`, not by file, so any other line staged into either is still
# refused. A fixture that changes has to change here too.
fixture_lines() {
    cat <<'EOF'
Scripts/run-checks.sh:    && printf 'see /Users/example\n' > leak.txt \
Scripts/run-checks.sh:    printf '# see /Users/somebody\n' >> "$RUNNER/Scripts/run-checks.sh"
Scripts/run-checks.sh:    elif ! printf '%s\n' "$OUT" | grep -q 'Scripts/run-checks.sh:.*/Users/somebody'; then
Scripts/run-checks.sh:printf 'fix: a thing\n\nSee github.com/foo/bar/issues/42\n' > "$TMP/issueurl"
Scripts/run-checks.sh:printf 'fix: a thing\n\n# see github.com/foo/bar/issues/42\n' > "$TMP/hashline"
Scripts/run-checks.sh:printf 'Merge pull request #4812 from seriouslysean/x\n' > "$TMP/mergesubject"
Scripts/run-checks.sh:printf 'fix: crash when the widget reloads (#4812)\n' > "$TMP/squashsubject"
Scripts/run-checks.sh:printf 'fix: a thing\n\nSee #100 for why.\n' > "$TMP/bodynumber"
Scripts/run-checks.sh:    && fixture_git merge -q --no-ff -m 'Merge pull request #101 from seriouslysean/101-a-branch' side
Scripts/run-checks.sh:    && fixture_git commit -q --allow-empty -m 'fix: crash when the widget reloads (#4812)'
Scripts/run-checks.sh:elif ! printf '%s\n' "$OUT" | grep -q '#4812'; then
Scripts/run-checks.sh:    && fixture_git commit -q --allow-empty -m 'Merge pull request #4812 from seriouslysean/x'
Scripts/run-checks.sh:    && fixture_git commit -q --allow-empty -m 'fix: a thing' -m 'Merge pull request #102 from seriouslysean/102-a-branch'
Scripts/run-checks.sh:elif ! printf '%s\n' "$OUT" | grep -q '#102'; then
Scripts/run-checks.sh:printf 'fix: a thing\n\n# ------------------------ >8 ------------------------\ndiff --git a/x b/x\n+see #404\n' > "$TMP/verbose"
EOF
}

# Drops `path:n:line` hits whose `path:line` is a fixture line, and this file's lines that are
# themselves entries. A path holding a colon never matches, so it fails closed.
drop_fixture_lines() {
    FIXTURE_LINES="$(fixture_lines)" awk '
        BEGIN { n = split(ENVIRON["FIXTURE_LINES"], a, "\n"); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
        {
            p = index($0, ":"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
            q = index(rest, ":"); line = substr(rest, q + 1)
            if ((path ":" line) in ok) next
            if (path == "Scripts/scan-for-leaks.sh" && (line in ok)) next
            print
        }'
}

scan() {
    _what="$1"; _re="$2"
    # git grep exits 1 for no match; anything past that is git failing, which is not a clean tree.
    _hits="$(git grep --cached -nE "$_re" -- .)"
    [ $? -le 1 ] || die "git grep failed"
    _hits="$(printf '%s\n' "$_hits" | drop_fixture_lines)" || die "could not apply the fixture lines"
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
# owner/repo#N pointing somewhere else is how one repo's issue history reaches a public commit.
scan "cross-repo issue reference" '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+' || FOUND=1
# A bare three-or-more-digit issue number is almost never this repo's, which numbers from 1.
scan "foreign issue number" '#[0-9]{3,}' || FOUND=1
# Decision-record and ruling ids point into a private doc tree and mean nothing published.
scan "private record reference" '(DR|RL)-[0-9]{3}' || FOUND=1
scan "issue or pull request URL" "$ISSUE_URL_RE" || FOUND=1

if [ "${1:-}" = "--all" ]; then
    printf 'scanning commit messages\n'
    # Subjects and bodies are read apart, so GitHub's shapes are forgiven on a subject and nowhere else.
    _subjects="$(git log --all --format='%H %s')" || die "git log failed"
    _bodies="$(git log --all --format='%H%n%b')" || die "git log failed"
    scan_messages "$(printf '%s\n' "$_subjects" \
        | sed -e "$MERGE_SUBJECT_SED" -e "$SQUASH_SUBJECT_SED")" || FOUND=1
    scan_messages "$_bodies" || FOUND=1
fi

if [ "$FOUND" -eq 0 ]; then
    printf 'clean\n'
    exit 0
fi
printf '\nrefusing: the above would be published.\n'
exit 1
