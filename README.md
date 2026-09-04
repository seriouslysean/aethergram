# Aethergram

An app-agnostic analytics transport for Swift. Consent-gated, durable, and dependency-free: it
talks to an ingest API over `URLSession` and pulls in no SDK to do it.

Nothing is collected until the host says consent was granted. Until then `record` allocates
nothing, writes nothing, resolves no identifier, advances no counter, and reaches no transport. A
later decline erases what was collected under the grant — the queue file, the retention counters,
and the pending batch — rather than merely stopping new writes. That is the package's one
non-negotiable property, and `ConsentEnforcementTests` asserts it at all four layers.

## Modules

| Module | What it holds |
|---|---|
| `AethergramCore` | The signal type, the durable queue, batching, backoff, consent state and enforcement, retention counters, and the `SignalTransport` protocol. Knows no vendor. |
| `AethergramTelemetryDeck` | One conformance to `SignalTransport`: the v2 ingest body, the endpoint, and the canonical-to-vendor wire-name table. The only module that knows a vendor exists. |
| `Aethergram` | The umbrella, and the only product. `@_exported` re-exports of the two above. |

Deleting the adapter leaves the core compiling. That is the test of whether the boundary is real,
and it is also what a second adapter costs: conform `SignalTransport`, change nothing else.

## Install

```swift
.package(url: "https://github.com/seriouslysean/aethergram", from: "0.1.1")
```

```swift
.target(name: "YourApp", dependencies: [.product(name: "Aethergram", package: "aethergram")])
```

Depend on a release tag, never on `main`.

## Using it

Every host-specific decision is a protocol or a closure you supply, because a package cannot know
which container your app may write to, how it mints an identifier, or where it stores an answer.

```swift
import Aethergram

let recorder = SignalRecorder(
    configuration: AethergramConfiguration(
        signalPrefix: "Example.",
        logSubsystem: "com.example.app"
    ),
    transport: TelemetryDeckTransport(
        configuration: TelemetryDeckConfiguration(
            appID: "<your dashboard app id>",
            isTestMode: TelemetryDeckConfiguration.testPartition(for: .current())
        ),
        logSubsystem: "com.example.app"
    ),
    // Where the queue lives is yours: an extension writes to its own container,
    // an app may want somewhere else.
    queueStorage: FileSignalQueueStorage(
        directory: myApplicationSupportDirectory,
        logSubsystem: "com.example.app"
    ),
    // Where the retention counters live is yours too, and they must be
    // reachable by whatever your data-reset path clears.
    retentionStore: MyRetentionStore(),
    // Called only on a transmit consent already permits, so an implementation
    // that mints on first read cannot plant an identifier before the answer.
    clientUserProvider: { myAnalyticsIdentifier }
)

recorder.updateConsent(.granted)   // or .declined / .neverAsked
recorder.beginSession()            // a session boundary is host-specific
recorder.record("Session.started", parameters: ["surface": "home"])
```

Signal names are yours. The package prefixes them with `signalPrefix` and otherwise does not
interpret them, because names are your domain vocabulary.

## What it does with a signal

A recorded signal is appended to an in-memory queue and written to a durable file, so a process the
OS kills without warning loses nothing. Delivery is coalesced: nothing waits once a batch is full,
`transmitInterval` otherwise. A retryable failure keeps the batch queued and backs off
exponentially to `maxBackoffInterval`; a permanent rejection drops it rather than retrying against
an endpoint that will keep refusing. Past `queueLimit` the oldest signals are dropped, because the
recent ones describe the version someone is actually running.

Recording is synchronous and never throws. Transmission is the async half, and it is the only half.

## Adopting it

The migration from a vendor SDK is in [ADOPTING.md](ADOPTING.md).

## Contributing

The workflow is in [CONTRIBUTING.md](CONTRIBUTING.md), and the conventions the code holds itself to
are in [AGENTS.md](AGENTS.md).

## Stability

What a version number promises is in [STABILITY.md](STABILITY.md).

## Security

How to report a vulnerability, and what the consent gate does and does not cover, is in
[SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
