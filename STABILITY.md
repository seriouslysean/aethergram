# Stability contract

What a host may rely on across releases, and what may still change without notice. Anything not
listed here is an implementation detail.

## What is API

The `public` surface of the `Aethergram` product, reached through the umbrella import:

- `SignalRecorder`: its initializer's parameter list, `updateConsent`, `record`,
  `recordPurchaseCompleted`, `recordError`, `beginSession`, `endSession`, `flush`, and `reset`.
- `AethergramConfiguration`: its stored properties, its initializer's defaults, and the two pure
  policy functions `deliveryDelay(queued:)` and `backoffInterval(consecutiveFailures:)`.
- `ConsentState` and its `permitsCollection` verdict.
- The host seams: `SignalQueueStorage`, `RetentionStore`, and `SignalTransport`, along with
  `SignalBatch`, `TransportOutcome`, `RetentionRecord`, and `PurchaseDetails`. A type conforming
  to one of these today keeps compiling across a minor release.
- `FileSignalQueueStorage` as a supplied conformance, including its default filename.
- `PayloadKey`'s constants and `PresetSignal`'s raw values, because a dashboard is built on those
  strings and renaming one is a data outage.
- `EnvironmentSnapshot.current()` and the parameters it produces.
- `TelemetryDeckConfiguration`, `TelemetryDeckTransport`, and
  `TelemetryDeckConfiguration.testPartition(for:)`.

## What is not

- Anything `internal`, including the package's own identity constants and the wire-name table's
  storage. The names it maps to are a vendor's contract, not this package's.
- Log messages, their categories, and their format. Do not parse them.
- The on-disk shape of the queue file and the retention record. Both are written and read by this
  package alone; a version that changes the shape reads an old file as unreadable, purges it, and
  keeps recording, which is the documented behaviour rather than a migration.
- The precise timing of a transmission. `deliveryDelay` and `backoffInterval` are the contract;
  when the task actually runs is the scheduler's business.
- Which exact `TransportOutcome` a given HTTP status maps to, beyond the retryable-versus-permanent
  distinction. A status moving between those two is a behaviour change and gets release notes.

## The payload version

`sdk.name`, `sdk.version`, and `sdk.nameAndVersion` are stamped on every signal. That version is
the payload contract's, not the package's: it moves when the set of fields the package attaches
changes, or when the form one of them takes changes. A release that changes only behaviour leaves
it alone.

## How versions move

Semantic versioning, against the API list above.

- Patch: a fix with no API change.
- Minor: additions — a new preset, a new payload key, a new parameter with a default. Existing
  conformances keep compiling.
- Major: a removal or a signature change in the API list, or a change to a `PayloadKey` or
  `PresetSignal` string.

While the package is 0.x the major position is not in play, so a change that would be major above
1.0 is a minor release: `0.1.z` to `0.2.0`, never `0.1.1`. A patch on a 0.x line still promises
what a patch promises, which is that nothing in the API list moved. This is the rule 0.1.1 was cut
against and missed — it removed four `PayloadKey` constants and changed a signature in the API
list, and shipped in the patch position.

That distinction is what a range depends on. `from:` is `upToNextMajor`, so every 0.x release a
host has not pinned exactly is one it will resolve into. A release that changes the API list
cannot be reached that way without breaking a build, which is why the position it occupies is a
promise rather than a label.

Depend on a release tag. `main` is a moving target.

## Platforms and toolchain

iOS 18 and macOS 15, Swift tools 6.3, language mode 6. Raising a platform floor or the tools
version is a major release, because a host that cannot build it cannot use it.

## Dependencies

None, and that is a contract rather than a current state. A release that added one would not be a
release of this package.
