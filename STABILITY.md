# Stability contract

What a host may rely on across releases, and what may still change without notice. Anything not
listed here is an implementation detail.

## What is API

The `public` surface of the `Aethergram` product, reached through the umbrella import:

- `SignalRecorder`: its initializer's parameter list, `updateConsent`, `record`,
  `recordPurchaseCompleted`, `recordError`, `beginSession`, `endSession`, `flush`, and `reset`.
- `AethergramConfiguration`: its stored properties, its initializer's defaults, and the two pure
  policy functions `deliveryDelay(queued:)` and `backoffInterval(consecutiveFailures:)`. The
  initializer traps on a `batchSize` or `queueLimit` that is not positive and on a
  `transmitInterval` or `maxBackoffInterval` that is not finite and positive, so a bad value fails
  at launch rather than at the first signal. It clamps an interval only when one is large enough
  to have crashed the host at its first retry. Ceilings for `queueLimit` and the intervals are
  planned for a minor release.
- `ConsentState`, its raw values, and its `permitsCollection` verdict. The raw values are API
  because a host persists them.
- The host seams: `SignalQueueStorage`, `RetentionStore`, and `SignalTransport`, along with
  `SignalBatch`, `TransportOutcome`, `RetentionRecord`, and `PurchaseDetails`, including
  `PurchaseDetails.init(transaction:)` where StoreKit is available. A type conforming to one of
  these today keeps compiling across a minor release.
- `Signal`, its stored properties and its initializer: a custom `SignalQueueStorage` constructs
  one on `load()`, and a custom `SignalTransport` reads one out of every `SignalBatch`. Its
  `Codable` form is not: see below.
- `FileSignalQueueStorage` as a supplied conformance, including its default filename.
- `PayloadKey`'s constants and `PresetSignal`'s raw values, because a dashboard is built on those
  strings and renaming one is a data outage.
- `EnvironmentSnapshot`: its initializer, its stored properties, `current()` and the parameters it
  produces, and `calendarParameters(at:calendar:)`.
- `RunContextChannel`'s cases and raw values, which `EnvironmentSnapshot.channel` carries.
- `TelemetryDeckConfiguration`, including `defaultBaseURL` and `ingestURL`, `TelemetryDeckTransport`,
  and `TelemetryDeckConfiguration.testPartition(for:)`. `TelemetryDeckTransport`'s initializer traps
  on a background `URLSession`.

A new case in a public enum — `PresetSignal`, `RunContextChannel`, `TransportOutcome`,
`ConsentState` — is a minor addition. A host that switches over one of them must carry a `default`
branch; an exhaustive switch without one stops compiling when a case arrives.

## What is not

- Anything `internal`, including the package's own identity constants and the wire-name table's
  storage. The names it maps to are a vendor's contract, not this package's.
- Log messages, their categories, and their format. Do not parse them.
- `Signal`'s `Codable` form. A custom `SignalQueueStorage` that stores signals encoded must treat
  a decode failure as an empty queue, as `FileSignalQueueStorage` does, because a release may
  change the form.
- The on-disk shape of the queue file, and anything else the store writes beside it.
  `FileSignalQueueStorage` is written and read by this package alone; an old file that fails to
  decode against the current `Signal` shape is purged and the process keeps recording, which is the
  documented behaviour rather than a migration. A shape change does not always trigger that — it
  depends on what moved — but a required field does: 0.3.0's `sessionID` is not optional, so a
  0.2.x file throws against it and is purged.

  A file that cannot be *read* is the opposite answer, because a read fails for reasons the queue
  is not responsible for — a protected file while the device is locked, a container briefly out of
  reach. It is left where it is, and every write retries the read. Until one succeeds the writes
  stay off the file: the queue keeps transmitting from memory, and loses only its durability
  against a kill. Once a read succeeds, what the file held is written ahead of the recorder's
  queue in every write, for the next process to load and send. A purge that can neither delete nor
  overwrite the file leaves
  an empty marker file beside it, which every later read takes as "restore nothing" until the
  delete lands. Both the marker's name and its existence are implementation detail.
- The on-disk shape of the retention record beyond what `RetentionRecord`'s `Codable`
  conformance promises. Decoding follows that conformance wherever the host's `RetentionStore`
  persists the bytes — the protocol itself specifies no decoding, the storage is the host's.
  `firstSessionDay` is required, every other key decodes to a default when absent, so a host
  upgrading across a release keeps an install's acquisition date and day history. A record with no
  `firstSessionDay` fails to decode and is treated as absent, not recovered.
- The precise timing of a transmission. `deliveryDelay` and `backoffInterval` are the contract;
  when the task actually runs is the scheduler's business.
- Which exact `TransportOutcome` a given HTTP status maps to, beyond the retryable-versus-permanent
  distinction. A status moving between those two is a behaviour change and gets release notes.

## The payload version

`sdk.name`, `sdk.version`, and `sdk.nameAndVersion` are stamped on every signal. That version is
the payload contract's, not the package's: it moves when the set of fields the package attaches
changes, or when the form one of them takes changes. A release that changes only behaviour leaves
it alone.

It follows semantic versioning against the field set, and the reader is who it promises to: a
removed field breaks whoever keyed on it, so a removal is major, an addition is minor, and a
changed form is whichever of the two a reader would have to react to.

A fix that brings a field back to the form it always promised is none of those. 0.3.2 left the
version at 2.0.0 while making `acquisition.firstSessionDate` Gregorian on every device: it always
meant a Gregorian `yyyy-MM-dd` date, and a device set to another calendar was sending it wrong.

## How versions move

Semantic versioning, against the API list above.

- Patch: a fix with no API change.
- Minor: additions — a new preset, a new payload key, a new parameter with a default. Existing
  conformances keep compiling.
- Major: a removal or a signature change in the API list, or a change to a `PayloadKey` or
  `PresetSignal` string.

While the package is 0.x the major position is not in play, so a change that would be major above
1.0 is a minor release: `0.1.z` to `0.2.0`, never `0.1.1`. A patch on a 0.x line still promises
what a patch promises, which is that nothing in the API list moved.

That distinction is what a range depends on. `from:` is `upToNextMajor`, so every 0.x release a
host has not pinned exactly is one it will resolve into. A release that changes the API list
cannot be reached that way without breaking a build, which is why the position it occupies is a
promise rather than a label. The install snippets in README.md and ADOPTING.md pin `exact:` for
the same reason: a 0.x minor may change the API list, and a host should take that on its own
schedule rather than inherit it on the next resolve.

Depend on a release tag. `main` is a moving target. What each release changed is in
[CHANGELOG.md](CHANGELOG.md).

## Platforms and toolchain

iOS 18 and macOS 15, Swift tools 6.3, language mode 6. Raising a platform floor or the tools
version is a major release, because a host that cannot build it cannot use it. macOS is a build
and test host, not a shipping channel: `EnvironmentSnapshot` reports every macOS run as `dev`, so
`TelemetryDeckConfiguration.testPartition(for:)` puts every macOS install in the test partition,
and a macOS host that ships must supply `isTestMode` itself.

## Dependencies

None, and that is a contract rather than a current state. A release that added one would not be a
release of this package.
