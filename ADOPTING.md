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
.package(url: "https://github.com/seriouslysean/aethergram", exact: "0.3.2")
```

Depend on a release tag, never on `main`. Add the `Aethergram` product to the target that owns
analytics, usually the extension or app that actually emits. What has to hold is one recorder per
process and one queue store per file, because the queue directory and the logging subsystem belong
to a process. A shared framework that constructs the recorder with a directory and a subsystem the
linking process hands it meets both.

Build. Nothing is wired yet, so nothing should change.

## Phase 2: conform the host protocols

Four decisions are yours, and each arrives through a seam rather than a constant, because a package
cannot know which container your app is allowed to write to.

**Where the queue lives.** `FileSignalQueueStorage(directory:logSubsystem:)` writes an atomic file.
Give it a directory the process can write to and that the OS will not clear underneath you, and
choose by who can erase it:

| Directory | Who can erase the queue | What that costs |
|---|---|---|
| The process's own container, such as an extension's Application Support | Only that process | A decline or reset made in another process has to be carried to it (Phase 4) |
| An app group container | Any process in the group can reach the file | Two live stores over one file are unsupported, so the processes still coordinate the same way |

Conform `SignalQueueStorage` yourself only if a file is wrong for you. `Signal`'s `Codable` form is
not API, so a conformance that stores signals encoded must treat a decode failure as an empty
queue, as `FileSignalQueueStorage` does.

**Where the retention counters live.** Conform `RetentionStore` over storage your existing data-reset
path already clears. This is the point of the protocol: counters kept somewhere a reset cannot
reach mean a user who erased their data kept a retention history.

**How the identifier is minted.** `clientUserProvider` is a closure returning your analytics
identifier, unhashed. It is called only on a transmit that consent already permits, so an
implementation that mints and persists on first read still cannot plant an identifier before the
user answers. Keep it that way: do not pre-warm it. Returning nil sends nothing and backs the
drain off as if the send had failed.

**What the default payload says.** `environmentProvider` defaults to
`EnvironmentSnapshot.current().parameters`, which reports OS, locale, and build channel. An
override replaces the whole environment, not adds to it: start from
`EnvironmentSnapshot.current().parameters` and merge your own fields in, or you lose OS, locale,
and build channel, keeping only whatever fields you added. `sdk.name`, `sdk.version`, and
`sdk.nameAndVersion` are not part of that default — the recorder stamps them on every signal
itself, independently of `environmentProvider`, so no override, merged or not, can drop them. A
parameter passed to `record` still wins a key collision over any of this, including `sdk.name`;
naming it there is the caller's decision, not one the package catches.

**Where the seams run.** Every seam but the transport and the queue's writes is called with the
recorder's lock held:

| Seam | Thread | Under the recorder's lock |
|---|---|---|
| `clientUserProvider` | The drain's, a utility-priority task | Yes |
| `environmentProvider` | Whichever thread makes the first permitted record after a grant | Yes |
| `RetentionStore` | Whichever thread calls `record`, `beginSession`, `endSession`, `updateConsent`, or `reset` | Yes |
| `SignalQueueStorage.load()` | Whichever thread records or drains first | Yes |
| `SignalQueueStorage.persist` and `purge` | The recorder's serial writer queue | No; `flush()`, `reset()`, and a decline wait on that queue |
| `SignalTransport.send` | The drain's | No |

So each of them:

- Is cheap, and reads storage that is safe from any thread: `UserDefaults`, the Keychain, or a
  value behind a `Mutex`.
- Never uses `MainActor.assumeIsolated`, which traps off the main thread, and the drain is always
  off it.
- Never uses `DispatchQueue.main.sync`, which deadlocks against a record the main thread is making
  while it waits for the lock.
- Never calls back into the recorder. Under the lock that fails a precondition and terminates the
  process; from `persist` or `purge`, a `flush()`, `reset()`, or decline waits on the queue it is
  running on.

`UIDevice` is main-actor isolated, so an identifier read from it is read on the main actor and
stored where the provider can reach it from any thread. Read it in the activation step, after the
answer is adopted and only when it permits collection. The OS supplies `identifierForVendor`, so
reading it mints and persists nothing; it can be nil, so read it again at every activation rather
than once per process:

```swift
let analyticsIdentifier = Mutex<String?>(nil)   // import Synchronization

// On the main actor, in the activation step:
recorder.updateConsent(answer)
if answer.permitsCollection {
    let identifier = UIDevice.current.identifierForVendor?.uuidString
    analyticsIdentifier.withLock { $0 = identifier }
    recorder.beginSession()
}

// The provider reads the stored copy:
clientUserProvider: { analyticsIdentifier.withLock { $0 } }
```

**What blocks the caller.** A record does not wait for the queue write: the encode and the write
happen on the writer queue. Three calls do wait on it, until no write is pending — including one
submitted while they wait:

| Call | Returns once | Extended by recording from another thread |
|---|---|---|
| `flush()` | No queue write is pending. It does not wait for the send. | Yes, for as long as it continues |
| `updateConsent` with anything but `.granted` | The erase has reached the queue store and the retention store. | No: a record after a decline writes nothing |
| `reset()` | The same. | Yes, while consent is granted: a reset leaves it as it was |

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

`TelemetryDeckTransport` takes an optional `session:`. Pass only a default or ephemeral
configuration: a background `URLSession` fails a precondition at construction.

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

**The order every process takes.**

1. Construct one recorder per process, owned process-wide — a static or an app-level object, not a
   view controller that can be created twice. Give each `FileSignalQueueStorage` a file of its
   own; two live stores over one file are unsupported.
2. On every activation, launch included, and before anything records, adopt the stored answer
   with `recorder.updateConsent(storedAnswer)`. A recorder starts at `.neverAsked` in every process
   and reads no answer on its own. A non-granted answer adopted here erases, by design: that is
   how a decline made while this process was not running reaches what it collected.
3. Call `beginSession()` on activation.
4. Record.
5. On deactivation, call `endSession()` and then `flush()`.

A session is host-specific: an extension's active cycle is not an app foreground, so the package
counts and you decide when. Two shapes of the same order:

| Host | Activation (steps 2–3) | Deactivation (step 5) |
|---|---|---|
| A Messages extension's `MSMessagesAppViewController` | `willBecomeActive(with:)` | `willResignActive(with:)` or `didResignActive(with:)` |
| A SwiftUI app | `scenePhase` becoming `.active` | `scenePhase` leaving `.active` |

The view controller calls into the process-wide recorder; it does not own one.

**Re-read the stored answer at every activation, not only at launch.** A process can be suspended
and resumed across a change made elsewhere, and step 2 is what adopts it.

**A reset or decline made in another process.** A containing app cannot reach a queue in its
extension's own container, and the extension's recorder only learns of an answer it is handed.
Record the change in storage both processes can read, such as an app group's `UserDefaults`, and
have the process that owns the queue adopt it on its next activation, before anything records:

```swift
if sharedDefaults.bool(forKey: "analyticsResetPending") {  // written by the other process
    recorder.updateConsent(.declined)                       // erases this process's queue and counters
    sharedDefaults.removeObject(forKey: "analyticsResetPending")
}
let answer = storedConsentAnswer()                          // a decline made elsewhere lands here
recorder.updateConsent(answer)
if answer.permitsCollection { recorder.beginSession() }
```

**A host with no consent ask.** Hard-coding `updateConsent(.granted)` makes collection on by
default, and that is not consent. The gate is only as honest as the answer fed to it, so a host
that never asks must not describe itself as consent-gated.

Then replace the SDK's emit calls with `record(_:parameters:floatValue:)`, one surface at a time.
`signalPrefix` is prepended to your names so one dashboard can hold several surfaces; presets
bypass it, because their names are the package's.

Use `recordPurchaseCompleted` and `recordError` where they fit rather than hand-rolling equivalents
— an adapter maps them onto the vendor's own events, and a hand-rolled purchase signal will not
join with anything.

## Phase 5: wire the data reset

`reset()` erases what the package persists: the pending queue, the file behind it, and the
retention counters. Wire it into whatever your app calls a data reset — that is the point of the
`RetentionStore` seam, since counters kept somewhere a reset cannot reach mean a user who erased
their data kept a retention history.

Erasing the file is best effort against a filesystem that can refuse it, and SECURITY.md says what
that leaves. In short: a store that could not delete its file refuses to read it again for as long
as it lives, and a mark beside the file carries that refusal into later processes — but where the
delete, the overwrite and the mark are all refused, the bytes are still there and the refusal ends
with the process. Do not describe your reset to a user as physical deletion of the queue; what it
reliably ends is the collection, the counters, and anything that would have been sent.

Three things about the order around it, because none of them are the package's to do for you.

**Keep the gate shut across the whole reset, not only during the erase.** A reset leaves consent
alone, so the gate is open on either side of it and a signal recorded a microsecond later is a
legitimate signal. If the reset also rotates your analytics identifier, that signal can leave under
the identifier you are rotating away from, which is the linkage the rotation exists to break. Shut
the gate, do both halves, then read the answer again and restore it:

```swift
myConsentLock.withLock {                    // the same lock your consent writes take
    recorder.updateConsent(.declined)       // shuts the gate and erases, in one call
    rotateMyAnalyticsIdentifier()           // nothing recorded from here can carry the old one
    let answer = myStoredConsentAnswer      // read back now, not captured before the reset
    recorder.updateConsent(answer)
    if answer.permitsCollection { recorder.beginSession() }
}
```

`updateConsent(.declined)` erases exactly what `reset()` erases, so that sequence replaces the
`reset()` call rather than joining it. A signal recorded inside the window is dropped rather than
misattributed, which is what a reset should do with it.

Read the answer back at the end rather than capturing it at the start, and take the whole sequence
under the lock the last of these three points describes. A decline arriving mid-reset — the user's
own, or one adopted from another device — is otherwise overwritten by the grant the reset captured
before it, which turns collection back on for someone who has just turned it off.

That lock is yours and the recorder knows nothing about it, so keep it out of the closures you
hand over. `clientUserProvider`, `environmentProvider`, every `RetentionStore` call, and
`SignalQueueStorage.load()` run inside the recorder's own lock, and one of them taking a lock that
a caller holds while calling in is the two orders that deadlock. `SignalQueueStorage.persist` and
`purge` run outside it, on the writer queue that `flush()`, `reset()`, and a decline wait on, so
one of them taking your lock deadlocks against a caller that holds it while making one of those
calls.

What shutting the gate cannot do is recall a request already handed to the transport. The erase
cancels it, and the supplied adapter stops it through `URLSession`, but whatever the server had
already received stays received. That request carries the batch it claimed before the erase, under
the identifier resolved for it, which is the correct attribution for signals recorded before the
reset; nothing recorded after it can join that batch. If your reset has to complete with no request
outstanding at all, that is a property of your own network stack rather than something the package
promises.

**Reopen the counted session.** The erase takes the retention record with it and the package opens
no session on its own, so until the next `beginSession()` every signal goes out with no acquisition
or retention fields at all. Call it at the end of a reset that left collection enabled — the last
line of the snippet above, and the same call your activation path makes.

**Serialize your own consent check with your own identifier read.** If an emit path checks the
stored answer and then resolves an identifier that mints on first read, a decline landing between
those two lines leaves an identifier minted under an answer that is now "no". The package's gate
cannot undo that: the identifier is yours, and it was minted by your code before anything reached
the recorder. Hold one lock across the check and the resolve, and take the same lock where the
answer changes.

## Phase 6: delete the SDK

Remove the vendor SDK dependency, its initialization, and every remaining call into it. Two
transports live at once is the drift this replaces, so do not leave it in place "for now".

Search without extension filters. A stale initialization in a lifecycle hook is one nobody notices
until it posts.

Two things the swap does to the data, so the dashboard's owner hears them before the charts show
them:

- **The retention counters restart.** The package does not read the SDK's counters, and the
  `RetentionStore` starts empty, so every existing install's first `beginSession()` after the swap
  creates its record: `acquisition.firstSessionDate` becomes the migration day and the session and
  day counts start from zero. A cohort chart shows every existing install arriving on that day.
- **The user hash carries over only if the input does.** The adapter sends the hex SHA-256 of
  `clientUserProvider`'s string with `salt` appended. The vendor's Swift SDK hashed the same way:
  its `customUserID` if the app set one, and otherwise its default identifier, which on iOS is
  `UIDevice.current.identifierForVendor?.uuidString` (`SignalManager.swift` and
  `CryptoHashing.swift` in its source). For an install to keep its hash, return that same string,
  unhashed, and keep `salt` at the SDK's value — empty unless the app set one.

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
- The privacy manifest and the App Store privacy answers. The package ships no
  `PrivacyInfo.xcprivacy` and calls none of the required-reason APIs directly, so declare what it
  sends in the embedding app's manifest and privacy answers. By the data types Apple's App Privacy
  Details use:

  | Data type | What in the payload |
  |---|---|
  | Product Interaction | Every signal: its name, parameters, and timestamps |
  | User ID or Device ID | `clientUser`, hashed, as stable as the identifier you return |
  | Purchase History | `recordPurchaseCompleted`, if you call it |
  | Other Diagnostic Data | `recordError`, device model, OS version, locale |

  Whether each is linked to the user or used for tracking is your answer, not the package's.
