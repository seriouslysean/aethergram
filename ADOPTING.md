# Adopting Aethergram

Instructions for an agent adding this package to an app that already sends analytics through a
vendor SDK. Work through the phases in order and stop at the end of each one.

## Before you start

Read `README.md` and `AGENTS.md` in this repository, and then read the app's existing analytics
layer: where signals are emitted from, where the consent answer is stored, where the analytics
identifier is minted, and what a data reset currently clears.

Do not invent signal names. Names are the app's vocabulary and this migration changes the
transport, not the dictionary. A dashboard built against the old names must keep working, which is
why the adapter carries a canonical-to-vendor wire-name table rather than renaming anything.

## Phase 1: add the package, emit nothing

```swift
.package(url: "https://github.com/seriouslysean/aethergram", from: "<latest release>")
```

Depend on a release tag, never on `main`. Add the `Aethergram` product to the target that owns
analytics — the extension or app that actually emits, not a shared framework, because the queue
directory and the logging subsystem belong to a process.

Build. Nothing is wired yet, so nothing should change.

## Phase 2: conform the host protocols

Four decisions are yours, and each arrives through a seam rather than a constant, because a package
cannot know which container your app is allowed to write to.

**Where the queue lives.** `FileSignalQueueStorage(directory:logSubsystem:)` writes an atomic file.
Give it a directory the process can write to and that the OS will not clear underneath you — an
extension's own Application Support directory, not a shared group container it may lose access to.
Conform `SignalQueueStorage` yourself only if a file is wrong for you.

**Where the retention counters live.** Conform `RetentionStore` over storage your existing data-reset
path already clears. This is the point of the protocol: counters kept somewhere a reset cannot
reach mean a user who erased their data kept a retention history.

**How the identifier is minted.** `clientUserProvider` is a closure returning your analytics
identifier, unhashed. It is called only on a transmit that consent already permits, so an
implementation that mints and persists on first read still cannot plant an identifier before the
user answers. Keep it that way: do not pre-warm it.

**What the default payload says.** `environmentProvider` defaults to
`EnvironmentSnapshot.current().parameters`, which reports OS, locale, build channel, and the
package's own payload version. Override it only to add fields, and only fields that survive data
minimisation.

## Phase 3: wire the adapter

```swift
let transport = TelemetryDeckTransport(
    configuration: TelemetryDeckConfiguration(
        appID: "<your dashboard app id>",
        salt: "",                       // changing this re-buckets every existing user
        isTestMode: TelemetryDeckConfiguration.testPartition(for: .current())
    ),
    logSubsystem: "com.example.app"
)
```

`isTestMode` has no default on purpose. Deriving it from `DEBUG` alone is what sends Release
simulator runs, developer-device builds, and every beta install to the live partition.
`testPartition(for:)` answers from the build channel instead: only an App Store install is real
usage.

Keep `salt` at whatever the SDK you are replacing used. It is mixed into the identifier before
hashing, so a different value silently re-buckets every existing user and the dashboard reads it as
a wave of new installs.

## Phase 4: route consent, then emit

Call `updateConsent` from wherever the answer is decided, on every path that can change it,
including a decline arriving from another device. Granting only opens the gate; anything else
closes it and erases what was collected under it.

Call `beginSession()` and `endSession()` at your own boundaries. A session is host-specific: an
extension's active cycle is not an app foreground, so the package counts and you decide when.

Then replace the SDK's emit calls with `record(_:parameters:floatValue:)`, one surface at a time.
`signalPrefix` is prepended to your names so one dashboard can hold several surfaces; presets
bypass it, because their names are the package's.

Use `recordPurchaseCompleted` and `recordError` where they fit rather than hand-rolling equivalents
— an adapter maps them onto the vendor's own events, and a hand-rolled purchase signal will not
join with anything.

## Phase 5: delete the SDK

Remove the vendor SDK dependency, its initialization, and every remaining call into it. Two
transports live at once is the drift this replaces, so do not leave it in place "for now".

Search without extension filters. A stale initialization in a lifecycle hook is one nobody notices
until it posts.

Then confirm, on a real run:

1. With consent withheld, the queue file does not exist and no request is made.
2. After granting, signals reach the dashboard under their existing names.
3. After declining, the queue file is gone and the retention record is cleared.
4. A build that is not an App Store install lands in the test partition.

## What stays yours

- Signal names, parameter keys, and the values inside them. Nothing here inspects payload content,
  so a parameter carrying a user's name publishes a user's name.
- The consent UI and where the answer is stored. The package reads a verdict; it does not ask.
- The analytics identifier and its disclosure.
- The privacy manifest. The payload is declared where the emitting code lives, which is your app,
  not this package.
