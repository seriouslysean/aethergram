# Contributing

## Setup

Point git at the committed hooks once per clone.

```sh
git config core.hooksPath hooks
```

The pre-commit hook runs `test/no-leaks.sh`. It touches no network and takes milliseconds.

## The rule that matters

**A fix ships with a test that fails without it.** Not a test that passes afterwards, which proves
nothing: a test you have watched fail on the unfixed code and pass on the fixed code.

This package is a consent gate with a queue attached. A gate is the one kind of code whose failure
mode is silence — it keeps collecting, the tests keep passing, and nothing surfaces until someone
reads a dashboard that should have been empty. So the consent suite asserts at four layers, not
one: the transport was not called, the queue storage was not called, no bytes reached disk, and
neither the identifier nor the payload provider ran. A transport-only assertion cannot tell
"dropped before enqueue" from "enqueued but not yet sent", and only the first is what consent
means.

Run the suite before you push.

```sh
test/run.sh
```

## Every change starts as an issue

Open an issue before writing code, even for a one-line fix, so the reason survives longer than the
diff. Record what the wrong behaviour actually was, ideally as the code that produces it.

Branch from `main` and name the branch after the issue, as in `7-queue-survives-a-corrupt-file`.
Open a pull request that closes it with `Closes #7`. Merge with a merge commit rather than a
squash, so each commit on `main` stays individually revertable.

An agent commits and opens the pull request; the owner reviews the diff and merges. Commit
messages and pull request bodies carry no session link, agent trailer, or co-author line.

## Writing the test

Tests live under `Tests/`, one suite per concern, and each test is named for the failure it
prevents rather than the function it calls. `A corrupt queue file loads as empty and is purged`
says what breaks if it regresses; `testLoadCorrupt` does not.

Nothing in the suite reaches the network. The adapter's tests assert the request a batch produces
— its URL, its headers, its body — and drive outcomes through an injected `URLSession`, so a
failure points at the wire format rather than at a vendor being slow.

Before you write the fix, write the test and watch it fail. A test written afterwards tends to
assert what the code now does rather than what it should do.

## Nothing published may identify a consumer

This repo is public. The apps that use it are not, and the development model is to edit the
transport from inside one of them, so a comment written in that context can carry a private app
name, a bundle identifier, or an issue number into a public commit. Prose is the leak, not code.

`test/no-leaks.sh` runs in the suite and in the pre-commit hook. It refuses absolute home paths,
email addresses, cross-repo issue references, and bare issue numbers. It matches shapes that point
outside this repo, and it reads tracked files, so stage a file before expecting it to be scanned.

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
- No third-party dependency. `Package.swift` has no `dependencies:` line and is not getting one.

## Releasing

1. `test/run.sh` passes on a clean checkout.
2. Update the version in the install snippets in `README.md` and `ADOPTING.md`, so a
   reader copying one gets the release being cut rather than the previous one.
3. Merge the pull request.
4. Confirm local `main` matches `origin/main`.
5. Tag `vX.Y.Z` and push the tag, then publish a release naming the issues it closes.

What a version number promises is in [STABILITY.md](STABILITY.md).

## Rules for the code itself

See [AGENTS.md](AGENTS.md).
