# AGENTS.md

Rules for working in this repo. `CONTRIBUTING.md` holds the hook setup, the checks (`Scripts/run-checks.sh`, run offline on a full clone with the release tags), and the release sequence.

## The package

1. Consent is the core's invariant and never an adapter's option, because a gate a caller can route around is not a gate.
2. Before consent is granted, a recording entry point enqueues and retains no event data, writes no analytics storage, resolves no analytics identifier, advances no analytics counter, and calls no transport. A transient input value discarded at the gate is not collection: this is not a zero-allocation promise, and it neither forbids the bookkeeping consent and erasure need nor relaxes the tested consent invariant.
3. Withdrawing consent erases what was collected under it, since an off switch that leaves yesterday's signals on disk to be sent later is not an off switch.
4. Assert the consent invariant at every layer the recorder touches, because a transport-only assertion cannot tell "dropped before enqueue" from "enqueued but not yet sent".
5. Only the adapter module knows a vendor exists, and the core must still compile with every adapter deleted.
6. Keep vendor vocabulary — endpoints, salts, field names, app identifiers — on the adapter, because none of it means anything to a second backend.
7. Take every host decision through a protocol the host conforms, never a constant in the package, since a package cannot know which container an app may write to or how it mints an identifier.
8. Leave signal names to the host, because names are its domain vocabulary and this package is not its dictionary.
9. Publish the umbrella and nothing else, so a host imports one module and the boundary between core and adapter stays one-directional.
10. Take no third-party dependency, ever. A transport that pulls in a package to talk HTTP has replaced one SDK with another.
11. Talk to a vendor over `URLSession` against its documented API, and treat an undocumented field as one that will change without telling you.
12. State a comment's constraint rather than its restatement of the next line, and keep it short.

## Publishing

13. Never let anything published identify a consumer: no app name, bundle identifier, scheme, cross-repo issue number, absolute home path, or email address, in code, comments, tests, or prose.
14. Remember the leak is usually prose, because the transport gets edited from inside a private app and a comment written there travels.
15. Read an issue or pull request body back before filing it, since no hook can gate what is typed into a web form.
16. Describe a failure rather than its reporter: an adoption report is "a host app", not its name.

## Verifying

17. Ship a fix with a test you have watched fail without it, because a fix verified once by hand is a fix the next one can break silently.
18. Name a test for the failure it prevents rather than the function it calls.
19. Prove a gate fails on known-bad input before trusting it to pass, and keep that proof as a test.
20. Remember that a gate which never fires looks exactly like one that passes.
21. Tag a suite at its header as documentation, never as a selector: `--filter` is a regex over `<test-target>.<test-case>`, so a tag filter matches nothing and still exits 0.
22. Keep the tag vocabulary short by design, and add one only when a suite applies it, because a tag nothing uses is a category nobody is thinking in.
23. Write POSIX `sh` in `Scripts/` and `.githooks/`, and avoid bashisms so the same scripts run under `dash`.
24. Obtain one independent adversarial review of each coherent change's actual diff, covering the relevant concurrency, consent, and published claims, because the suite only re-proves past failures. A change is done when its acceptance criteria and required checks pass and material in-scope objections are resolved with evidence. A correction gets a focused recheck of itself and the behavior it affects, not an automatic new broad review. Log a credible unrelated defect separately; a serious one may block a release without widening the task. Do not file every finding outside a fixed list as an accepted risk.

## Working

25. Start every change from an issue and a branch named for it, so the reason outlives the diff. One issue may carry an owner-approved set of related items; keep each independently useful correction separable with its tests, and an inseparable correction whole.
26. Merge with a merge commit rather than a squash, so each commit on `main` stays individually revertable.
27. Commit and open the pull request on the owner's behalf.
28. Keep session links, agent trailers, and co-author lines out of commit messages, issues, and pull request bodies, because they point outside this repository, and the commit-msg hook refuses the trailer shapes a message can carry.
29. Write terse, factual prose that opens with the substance and still reads in whole sentences.
30. Build what a host needs or a measurement shows, and move the rest to an issue that names what would reopen it, because every addition to a published package is a contract to keep.

## Declaring for the vendor

31. Start a declaration about the vendor, such as a privacy-manifest type, identifier hashing, or a wire default, from the vendor's own authoritative artifact at an identified version, keep only what describes this adapter's actual behavior, and record the evidence for each material difference, because a host's store disclosures were written against that SDK and neither intuition nor a verbatim copy describes this implementation. Read the SDK as reference, never as a dependency.
