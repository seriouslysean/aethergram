# Contributing

## Toolchain

Xcode 26.6, which provides Swift 6.3. `.swift-version` pins 6.3, the manifest's tools version is
6.3, and CI runs against `Xcode_26.6.app` and fails if that Xcode reports a Swift older than 6.3.

## Setup

Point git at the committed hooks once per clone. Git will not let a repo commit this setting,
which is why every hook framework has the same step and each of them brings a runtime to do it.

```sh
git config core.hooksPath .githooks
```

The hooks run `Scripts/scan-for-leaks.sh`, over the staged tree before the commit and over the
message as it is written. It touches no network and takes milliseconds.

## The rule that matters

**A fix ships with a test that fails without it.** Not a test that passes afterwards, which proves
nothing: a test you have watched fail on the unfixed code and pass on the fixed code.

That is a regression test with the ordering made explicit: it fails before the fix is applied and
passes after.

This package is a consent gate with a queue attached. A gate is the one kind of code whose failure
mode is silence — it keeps collecting, the tests keep passing, and nothing surfaces until someone
reads a dashboard that should have been empty. So the consent suite asserts at four layers, not
one: the transport was not called, the queue storage was not called, no bytes reached disk, and
neither the identifier nor the payload provider ran. A transport-only assertion cannot tell
"dropped before enqueue" from "enqueued but not yet sent", and only the first is what consent
means.

Run the checks before you push.

```sh
Scripts/run-checks.sh
```

`Tests/` is SwiftPM's and is reached by `swift test`. `Scripts/` holds the repo-level checks that
are not Swift, which is where a Swift package puts them.

It runs offline, and needs a full clone with the release tags: the leak scan reads every commit
message in history and the api-break gate builds the tags. Deepen a shallow clone with
`git fetch --unshallow --tags` first. The gates, in order:

| Gate | What it holds |
|---|---|
| Leak scan | No tracked file's name or staged content, and no commit message in history, identifies a consumer, a person, or a machine. File contents in earlier commits are not scanned |
| iOS builds | The package for iOS in release as extension-safe (`-application-extension`), and the core alone with no adapter in reach |
| Privacy manifest | `PrivacyInfo.xcprivacy` declares Product Interaction and Device ID, neither linked nor used for tracking, for analytics alone, and no tracking, tracking domain, or required-reason API. The iOS build ships it unchanged in the adapter's bundle, and no other bundle carries one |
| watchOS build | The package builds for watchOS in release at its declared floor, watchOS 11 |
| Consumer fixture | `Tests/Fixtures/ConsumerHost`, a package that imports the umbrella alone with no upcoming-feature flag, builds for iOS as extension-safe, and the root package takes nothing from it |
| API break | The working tree's public API, diffed against the last release tag, breaks nothing the release in `CHANGELOG.md`'s top heading may break: nothing in a patch, anything in a 0.x minor |
| Release heading | `Scripts/check-release-heading.sh` refuses a heading that names another release, has no date, or uses a hyphen for the dash |
| Suite | `swift test` passes and runs at least `ROOT_TESTS_FLOOR` tests |

Each gate is first watched refusing known-bad input — a copy of the package broken on purpose, a
malformed manifest, a manifest declaring a linked or an extra type, a break from the package's own
history — so a gate that never fires cannot pass as one that passes. `ROOT_TESTS_FLOOR` in
`run-checks.sh` catches tests that go missing; raise it in the change that adds tests, and lower it
only with the tests it lost named.

## Every change starts as an issue

Open an issue before writing code, even for a one-line fix, so the reason survives longer than the
diff. Record what the wrong behaviour actually was, ideally as the code that produces it.

Branch from `main` and name the branch after the issue, as in `7-queue-survives-a-corrupt-file`.
Open a pull request that closes it with `Closes #7`. Merge with a merge commit rather than a
squash, so each commit on `main` stays individually revertable.

An agent commits and opens the pull request; the owner reviews the diff and merges. Commit
messages, issues, and pull request bodies carry no session link, agent trailer, or co-author line.

## Writing the test

Tests live under `Tests/`, one suite per concern, and each test is named for the failure it
prevents rather than the function it calls. `A corrupt queue file loads as empty and is purged`
says what breaks if it regresses; `testLoadCorrupt` does not.

Nothing in the suite reaches the network. The adapter's tests assert the request a batch produces
— its URL, its headers, its body. The suite is hermetic by construction: outcomes are driven
through an injected `URLSession` and a recording queue storage, which are fakes rather than mocks,
so a failure names the wire format rather than a vendor's availability.

Before you write the fix, write the test and watch it fail. A test written afterwards tends to
assert what the code now does rather than what it should do.

## Nothing published may identify a consumer

This repo is public. The apps that use it are not, and the development model is to edit the
transport from inside one of them, so a comment written in that context can carry a private app
name, a bundle identifier, or an issue number into a public commit. Prose is the leak, not code.

`Scripts/scan-for-leaks.sh` runs in the checks, in the pre-commit hook over the staged tree, and in
the commit-msg hook over the message being written. It refuses absolute home paths, email
addresses, cross-repo issue references, bare issue numbers of three or more digits, private record
ids, and, in a message, agent-session trailers. It also refuses a numbered issue or pull request URL
(`github.com/.../issues|pull/N`) naming any repository, this one included, since a bare number is
not a stable reference either. The file tier reads the index, so stage a file before expecting it
to be scanned.

One exemption, as narrow as it can be. GitHub writes its own subject on a web merge, which runs no
hook: `Merge pull request #N from seriouslysean/<branch>`. The history scan forgives that number, in
that subject, on a merge commit only; the same shape anywhere else, a body included, is still
refused. No tracked line is exempt: each runner fixture the file scan would refuse builds its shape
at run time, and a new one has to do the same.

The scan is a handful of hand-written regexes rather than a secret scanner. What it refuses are
identifying references, not credentials, so a scanner's entropy heuristics and maintained provider
rules match none of them, and the rule set would be hand-written either way. A scanner is also a
dependency, and this package takes none.

**Issues and pull requests are published too, and no hook can gate them.** Before filing, read the
body back and remove anything that is not about this repository: which app hit the bug, what its
targets are called, an issue number from somewhere else, a path from your machine. Describe the
failure, not the reporter.

## The boundaries the review checks

- The core compiles with every adapter target deleted. If it does not, vendor knowledge leaked
  down.
- The test targets depend on `AethergramCore` and the adapter, never on the umbrella. A test that
  needed the umbrella would mean a layer had grown a dependency it is not allowed to have.
- Every host-specific decision — where the queue is written, where the consent answer is stored,
  how the identifier is minted, which logging subsystem to use — arrives through a protocol or a
  closure the host supplies.
- No third-party dependency. `Package.swift` declares no package dependency and is not getting one.

## Releasing

1. `Scripts/scan-for-leaks.sh --all` passes. The hooks are local config a clone has to opt into,
   so the history tier is the only check that covers a message written without them.
2. `Scripts/run-checks.sh` passes on a clean checkout.
3. Update the version in the install snippets in `README.md` and `ADOPTING.md`, so a
   reader copying one gets the release being cut rather than the previous one.
4. Write the release's entry in `CHANGELOG.md` under `## X.Y.Z — YYYY-MM-DD`: every behaviour
   change a host can see, and any trap a host could newly hit. The api-break gate reads the
   release from that heading.
5. Merge the pull request.
6. Confirm local `main` matches `origin/main`.
7. Run `Scripts/check-release-heading.sh vX.Y.Z`; CI runs the same check on the tag push. Then tag
   `vX.Y.Z` with an annotation summarizing the release, and push the tag.
8. Publish a GitHub release from the tag, naming the issues it closes.

What a version number promises is in [STABILITY.md](STABILITY.md).

## Rules for the code itself

See [AGENTS.md](AGENTS.md).
