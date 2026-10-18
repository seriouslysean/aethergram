# Changelog

What each release changed that a host can see. What a version number promises is in
[STABILITY.md](STABILITY.md); this file is the history that contract was applied to.

## 2.1.0 — 2026-10-05

No API or payload change from 0.5.0: nothing in the API list moved, and every signal carries the
fields and the values it carried there, `sdk.version` included. What changes is what the number
is.

### One version

- `sdk.version` is the package's release version. It was a separate payload version, which 0.5.0
  moved to 2.1.0, so a dashboard read "Aethergram 2.1.0" for a package whose newest tag was
  `v0.5.0`. Host builds already send 2.1.0 and a version a reader has seen cannot go backward, so
  the package's numbering resumes there. No 1.x release exists.
- Every release after this one moves the stamp, one that changes only behaviour included. A
  reader grouping on `sdk.version` sees a value per release rather than per payload shape, and
  this file is where to learn which releases share a shape. This release stamps what 0.5.0
  stamped, so a reader cannot tell those two apart. [STABILITY.md](STABILITY.md) keeps what each
  release before this one stamped.
- The package leaves 0.x, so the major position is in play: a removal or a signature change in
  the API list is a major release, where a 0.x minor could carry one.
- A payload field the package stops attaching, or sends in a new form, is a major release, a new
  one is a minor, and a corrected value that keeps its key and form is a patch. Those were the
  payload version's rules and are now the package's.
- A host takes this release by editing its manifest. `exact: "0.5.0"` stays on 0.5.0, and
  `from: "0.5.0"` stops below 1.0.0.
- The install snippets read `from: "2.1.0"` rather than `exact:`, so a host copying one takes
  every 2.x release. Pinning `exact:` is still open to a host that wants each release on its own
  schedule.

### Tooling

- `Scripts/check-version-stamp.sh` refuses a tree whose `Aethergram.version` is not the version
  in this file's top heading, and runs in `Scripts/run-checks.sh`. The release heading check
  already holds that heading to the tag, so a tag, its heading, and the stamp agree.

## 0.5.0 — 2026-09-29

A 0.x minor that changes the API list: `EnvironmentSnapshot`'s initializer and stored properties
change, and `beginSession()` returns a value. The payload version moves to 2.1.0, which adds three
fields and a preset and fixes two values, each checked against TelemetryDeck's SwiftSDK at
`58f43629`, its docs at `2b9c2108` (the default-parameters reference, `basics/acquisition.md`, and
`articles/decide-to-drop-ios-version.md`), and its KotlinSDK at `10b87d4a`.

### Payload 2.1.0

- `device.systemMajorVersion`, sent as `TelemetryDeck.Device.systemMajorVersion`: the major OS
  version, `26`. The vendor documents it among its default parameters, its SDK sends it, and its
  docs describe the prebuilt system-version chart offering a major-version breakdown beside the
  major.minor one.
  All three version strings stay bare (`26.5.1`, `26.5`, `26`). The default-parameters reference
  types each only as a String, and the vendor's own articles show both forms; its Swift SDK
  prefixes the platform where its Kotlin SDK sends the major and major.minor versions bare. A
  changed form would split every chart already grouped on the bare `systemVersion` and
  `systemMajorMinorVersion`, and the new field takes the same form as those two.
- `runContext.language`, sent as `TelemetryDeck.RunContext.language`: the language the app runs in,
  the locale's language code.
- `calendar.dayOfWeek`, sent as `TelemetryDeck.Calendar.dayOfWeek`: the local day numbered as ISO
  8601 numbers it, Monday 1 through Sunday 7, as the vendor documents it and its SDK sends it.
- `userPreference.language` is the language the user most prefers on the device, the language
  subtag of the first `Locale.preferredLanguages` entry, as the vendor defines it. It was the
  locale's language, which is the app's, so an app localized only in English reported `en` from a
  device set to German. The key and the form are unchanged.
- `calendar.isWeekend` is `true` on a Saturday or a Sunday, as the vendor defines it, and is
  derived from the day of week. It followed the locale's weekend, so under a Friday-Saturday weekend
  a Friday reported `true` and a Sunday `false`. The key and the form are unchanged.
- `PresetSignal.newInstallDetected`, `acquisition.newInstallDetected`, sent as the vendor's
  `TelemetryDeck.Acquisition.newInstallDetected`. The vendor's docs name that signal as how new
  users are detected, sent on first launch. Its SDK sends it whenever a session starts with no
  stored session behind it, which is also after 90 days without a session, or after sessions that
  each lasted under a second. This package reports it once per retention record, so only after an
  install or an erase.

### API

- `SignalRecorder.beginSession()` returns `true` when the call created the retention record, which
  makes its session the first counted since install or since the last erase. It is
  `@discardableResult`, so an existing call compiles unchanged. It returns `false` on every later
  session, on a repeat in the same activation, and while collection is not permitted. The session
  `resetClosingCollection(during:)` reopens is counted by that reopen, so no later `beginSession()`
  reports it: a host that counts a data reset as a new install records the preset once that call
  returns. A `RetentionStore` whose `load()` returns nil, for a record it could not decode
  included, reads as no record, and the next session reports `true`.
- `SignalRecorder.recordNewInstallDetected(parameters:)` records the preset, unprefixed like the
  other presets. The recorder never records it on its own: a host calls it when `beginSession()`
  returns `true`, on the path every other signal takes, so whatever the host applies there covers
  it too.
- `EnvironmentSnapshot` holds the OS version once, as `systemMajorVersion`, `systemMinorVersion`,
  and `systemPatchVersion`, in place of `systemVersion` and `systemMajorMinorVersion`, and derives
  all three version fields from it. `language` becomes `preferredLanguage` and `appLanguage`. The
  initializer takes the new properties.
- `EnvironmentSnapshot.current()` takes `preferredLanguages:`, defaulting to
  `Locale.preferredLanguages`.

### Upgrading

- A call to `EnvironmentSnapshot`'s initializer passes the three version components and the two
  languages. Calls to `current()` and `beginSession()` change nothing.
- An install whose retention record predates the upgrade already has one, so `beginSession()`
  never reports it as new.
- A host swapping to this package from the vendor's SDK starts every existing install without a
  retention record (ADOPTING.md, Phase 6). Its first `beginSession()` after the swap returns
  `true`, and recording the preset on that answer counts every existing install as new on the
  migration day. After that, a user returning from 90 days away is not counted as new again, as
  the SDK would count them, and the three OS version fields arrive bare where the Swift SDK sent
  them with the platform.

### Tooling

- A contract suite records a signal through the recorder, encodes it with the adapter, and holds it
  to TelemetryDeck's SwiftSDK at `58f43629` and its default-parameters reference at `2b9c2108`, as
  read on 2026-09-29: the key set, the value forms, the deliberately absent keys and their reasons,
  and the install preset's name. The test floor rises to 224.
- The consumer fixture compiles a host's activation with the new preset.

## 0.4.2 — 2026-09-25

A patch: nothing in the API list moved, and the payload version stays 2.0.0.

### Delivery

- A drain that `reset()`, `resetClosingCollection(during:)`, or a decline cancelled after it had
  finished its delay, but before it took a batch, could still take the queue recorded after that
  erase. It then sent from a cancelled task, which `TelemetryDeckTransport` reads as retryable, so
  the recorder owed a backoff before those signals went out: a draw between 10 and 20 seconds at
  the default intervals, during which `flushAndWait()` started no pass. A drain now takes a batch
  only while it is still the recorder's scheduled drain. The signals stayed queued under the grant
  that recorded them, and nothing was sent without consent, before or after this change.

### Tooling

- The leak scan's message tier matches co-author and session trailers in any capitalization. It
  reads a message as bytes whatever the caller's locale, and exits with an error rather than
  reporting clean when it cannot read the message file or either grep over it fails.
- Each scanner pattern has a check that fails when that pattern is removed.
- CI checks out with `actions/checkout` v7.0.1.

## 0.4.1 — 2026-09-24

A patch: nothing in the API list moved, and the payload version stays 2.0.0.

### Privacy manifest

- `PrivacyInfo.xcprivacy` moved from the core's bundle to the TelemetryDeck adapter's,
  `Aethergram_AethergramTelemetryDeck.bundle`. The core ships no manifest: Apple counts data as
  collected when it is transmitted off the device, and the core never transmits.
- It declares Product Interaction and Device ID, not linked to the user, not used for tracking, and
  collected for analytics, as TelemetryDeck's SDK declares them at 2.14.1. 0.4.0 declared both
  linked. The adapter hashes the identifier on the device exactly as the vendor's SDK hashes it, so
  the vendor's not-linked declaration holds here too. No tracking, tracking domains, or
  required-reason APIs, as in 0.4.0.
- Purchase History and Other Diagnostic Data are no longer declared. A host that calls
  `recordPurchaseCompleted` or `recordError` declares those types in its own manifest and App Store
  answers.

### Tooling

- The privacy-manifest check pins the manifest's content and its place in the adapter's bundle,
  and is proved refusing a manifest with a linked or an extra type.

## 0.4.0 — 2026-09-23

A 0.x minor with no API break: two methods added to `SignalRecorder`, a platform and a privacy
manifest added, nothing in the API list removed or changed. The payload version stays 2.0.0.

### Additions

- `SignalRecorder.flushAndWait()` starts one delivery pass now and waits for it to finish, then for
  every queue write submitted by then, the pass's removal included, to reach the store. It starts
  no pass, and waits only for the writes, when a retry is already owed, which it never hurries,
  when consent is not granted, or while collection is closed for a reset. An erase while it waits
  cancels the pass. Cancelling the caller returns it promptly and forfeits the promise that the
  writes reached the store; it still takes the recorder's lock first. It promises that pass's
  completion, not delivery of everything queued.
- `SignalRecorder.resetClosingCollection(during:)` is `reset()` with collection closed for the
  length of the closure. Collection reopens when the last overlapping call returns or throws, and
  the reopen opens a counted session if consent permits, where `reset()` mints only an uncounted
  session identifier. During the closure a decline erases and stands, a grant takes effect at the
  reopen, `flush()` waits for the queue writes only, `flushAndWait()` starts no pass, and `reset()`
  erases and leaves collection closed.
- watchOS 11 is declared, with iOS 18 and macOS 15.
- The core's bundle, `Aethergram_AethergramCore.bundle`, ships `PrivacyInfo.xcprivacy`: no
  tracking, no tracking domains, no required-reason APIs, and Product Interaction, Device ID,
  Purchase History, and Other Diagnostic Data collected for analytics, linked to the user and not
  used for tracking. A host's own manifest and App Store answers must still reflect what it sends.
- `SignalTransport.send` is spelled `nonisolated(nonsending)` in the protocol rather than left to
  the module's feature flag. The requirement means what it meant, and a plain `async` witness
  still conforms.

### TelemetryDeck adapter

- `TelemetryDeckTransport` sends over an ephemeral session with no cookie, credential, or URL cache
  store by default, where 0.3.2 used `URLSession.shared`, so nothing the host's shared session
  holds reaches the ingest. A session passed to `session:` is used as given.
- `TelemetryDeckConfiguration` traps at construction on a `baseURL` whose scheme is not `https`.
  0.3.2 accepted any scheme. A development server over `http` has to move to `https`.

### Delivery

- A retry after a failure is owed at a random draw between the larger of `transmitInterval` and
  half the backoff ceiling, and the ceiling, rather than at the ceiling, so installs that failed
  together do not retry together.
- A grant onto a non-empty queue restored from a killed process schedules its delivery, rather
  than waiting for the next record or flush. The restore reads and decodes the whole queue file on
  the granting thread, under the recorder's lock: 1,000 signals, the default `queueLimit`, measured
  about 38 ms cold on a simulator, and 10,000 about 380 ms.

### Waiting and erasure

- `flush()`, `reset()`, and a decline wait for the queue writes submitted before the call, where
  0.3.2 waited until the writer went idle, including for writes other threads kept submitting. A
  write submitted after the call lengthens the wait by at most one store call.
- A purge refused with an error of code 4 from a domain other than Cocoa's is treated as a refused
  delete, taking the overwrite and marker path, rather than read as "no file there".

### Upgrading

- On resign or background, call `flush()`, then run `flushAndWait()` inside the platform's
  expiring-time API, `ProcessInfo.performExpiringActivity` in an extension or `beginBackgroundTask`
  in an app, and cancel it when the time expires. ADOPTING.md has both patterns.
- Replace a decline, rotate the identifier, re-grant, `beginSession()` sequence with
  `resetClosingCollection { rotate() }`, and do not follow it with `beginSession()`. A host lock no
  longer needs to span the erase.

### Known limits

- Every queue write rewrites the whole file, about 819 KB for a full queue at the default 1,000
  signals and about 13.6 ms on a Mac. Records that arrive while a write is pending coalesce into
  one write.
- Overflow eviction and a permanent rejection lose signals, and a failed removal write can resend a
  batch: delivery is at least once.
- An install from TestFlight with no receipt reports the `dev` channel, which lands in the same
  test partition as `beta`.

### Tooling

- `Scripts/run-checks.sh` adds an api-break gate against the last release tag, which reads the
  release from this file's top heading; the release-heading check; a watchOS build at the floor; a
  privacy-manifest check; a consumer fixture build; and a floor on the root suite's test count. It
  needs the release tags, so not a shallow clone.
- CI runs `Scripts/check-release-heading.sh` on every push of a tag matching `v*`, refusing a tag
  this file's top heading does not name with a date.

## 0.3.2 — 2026-09-23

A patch: nothing in the API list moved, and the payload version stays 2.0.0.

### Configuration and traps

- `AethergramConfiguration` clamps `transmitInterval` and `maxBackoffInterval` to a ceiling far
  past any real schedule and below about 9.2e18 seconds, where a sleep that runs traps. An interval
  from there crashed the host at the first sleep that ran on it — the coalescing sleep its first
  record scheduled whenever `batchSize` is above 1, or a backoff sleep — and one past about 1.7e20
  seconds, where `Duration.seconds` itself traps, crashed wherever it was first made a `Duration`.
  That configuration now runs, and the property reads back the clamped value. An interval that is
  not finite, or not positive, still traps at construction, as in 0.3.1. `queueLimit` is not
  capped, and one that is not positive still traps there too.
- `TelemetryDeckTransport` fails a precondition naming the background `URLSession` at the first
  send over one. The send aborted the host at the same moment before, with an `NSGenericException`
  about completion handlers that did not name the transport.
- Calling back into the recorder from a seam it calls under its lock (`clientUserProvider`,
  `environmentProvider`, any `RetentionStore` call, `SignalQueueStorage.load()`) still terminates
  the process, now through a precondition at the recorder entry point that was re-entered rather
  than inside the lock's own recursion check.

### Consent and erasure

- A pending erase is never superseded by a snapshot submitted after it. The queue writer keeps the
  purge and the newest snapshot apart and runs the purge first, so a reset racing a record can no
  longer leave a queue the store could not read on disk for a later grant.
- A purge never creates the queue file. A decline before anything was granted, in a directory that
  refuses the delete, used to be able to write one.
- Across an erase, the cancelled send from before it may still be in flight while the drain after
  it sends a different batch. The erase takes the drain claim instead of waiting for the cancelled
  send to unwind. Sends were never promised to be serial.

### Durability

- A queue file that could not be read is retried on every write. Once a read succeeds, what the
  file held, up to the newest `queueLimit` signals, is kept ahead of the recorder's queue in every
  write, for the next process to load and send. A store wrapped in another conformance keeps the
  bound it already has: 1,000, unless it or a copy of it was also given to a recorder directly.
  Previously the writes stopped for the life of the process.
- The look for the erasure mark checks the mark's reachability and no longer reads file
  attributes.

### Retention counters and payload

- Day strings (`acquisition.firstSessionDate` and the distinct-day history) are `yyyy-MM-dd` in the
  Gregorian calendar, in the time zone of the calendar the recorder was given. A device set to
  another calendar used to send its own year, such as a Buddhist year 543 ahead. A stored record
  is converted when the recorder loads it: a day that already reads as a Gregorian date between
  2015-01-01 and tomorrow is kept, any other is read in the recorder's calendar and kept converted
  only if the result lands in that window, and otherwise kept as written. So a rebuilt or
  downgraded record is never converted twice. A day written before 0.3.2 under the Ethiopic
  calendar's Incarnation-era numbering that also reads as a Gregorian date in that window — any
  day from Ethiopic year 2015 on outside the thirteenth month — cannot be told apart from a
  Gregorian one and is left as written; one that does not, such as `2018-13-01`, is read as
  Ethiopic like any other. One written under the Chinese or Dangi calendar in a leap month carries
  no leap-month flag, so it converts to the same day of the ordinary month before it: 2025-07-25, written as `0042-06-01`, converts to 2025-06-25.
- A session's first recorded signal after `beginSession()` is checkpointed, so a session killed
  inside the ten-second checkpoint interval is measured to that signal rather than discarded.
- `endSession()` closes only a session this recorder opened, and a `record` advances only that
  session's checkpoint. A session left open by another process is closed by the next
  `beginSession()` against its own last activity, rather than stretched to now.
- For an app extension on iOS or Mac Catalyst (macOS reads no receipt),
  `EnvironmentSnapshot.current()` resolves the receipt that `runContext.channel` is read from
  against the containing app's bundle rather than the extension's own, falling back to the
  extension's when the app's bundle gives no receipt location. The `.appex` has to sit two
  directory levels under the `.app`, as in `PlugIns/` or `Extensions/`; any other layout keeps the
  extension's own.
- A `calendar.hourOfDay` value outside 0-23, which a caller can pass since caller parameters win,
  goes to the wire unchanged instead of trapping the send.
- A caller key spelled as a vendor wire name wins over the package key mapped onto that name, on
  every run. The winner used to depend on dictionary order.

### Scheduling and logging

- The drain runs at utility priority rather than the priority of the call that scheduled it.
- A queue overflow logs once when it begins and once when it ends, rather than on every record. It
  ends when a delivery or a permanent rejection leaves the queue below the limit; an erase clears
  it without the ending line. A store skipping writes logs when the skipping starts and when it
  stops or its reason changes, rather than on every write.

### Tooling

- CI builds the package for iOS release as extension-safe, and the core alone with no adapter in
  reach.
- The history scan forgives the pull request number in the subject GitHub writes on a merge
  commit, and nowhere else. The scanner and the check runner are scanned line by line, with only
  their exact fixture lines allowed.

## 0.3.1 — 2026-09-12

A patch: nothing in the API list moved and the payload version stood still.

- A zero-delay request — a `flush()` or a full batch — no longer skips the backoff a failure owes.
- A queue file that cannot be read is left in place rather than purged; one that cannot be decoded
  is still purged.
- A purge that can neither delete nor overwrite the queue file leaves a mark beside it, which every
  later load reads as "restore nothing" until the delete lands.
- The file store serializes its reads, writes, and erases against each other.
- An erase gives up the drain slot in the same lock section, so a record landing just after it
  schedules its own drain.
- ADOPTING.md states the order a host's data reset has to take.

## 0.3.0 — 2026-09-10

A minor release, because a signature in the API list moved.

- `Signal` gained a stored `sessionID`, stamped when the signal is recorded, and `SignalBatch` lost
  its `sessionID`. A custom `SignalTransport` that read `batch.sessionID` must read
  `signal.sessionID` instead. A queue file written by 0.2.x fails to decode against the new
  `Signal`, is purged, and the signals in it are lost. The payload version did not move: the
  session identifier travels as a top-level wire field either way.
- A non-finite `floatValue` is dropped when the signal is constructed or decoded.
- `AethergramConfiguration` traps on a non-finite interval, and the backoff ceiling is floored at
  `transmitInterval`. Retention counters saturate rather than trap.
- Work in flight across an erase is discarded. A counter save or a queue write from before a
  decline or a reset cannot land after it. A send is cancelled and its verdict discarded locally,
  though a request already on the wire can still reach the server. `updateConsent` and `reset()`
  return once the purge has reached the store.
- An overflow eviction during a send no longer causes a resend, and a finished drain restarts for
  signals that landed while it ran.
- A purge whose delete is refused overwrites the queue file in place.
- The adapter no longer writes a debug copy of each request to the caches directory.
- The leak scan reads the index rather than the working tree and refuses numbered issue URLs.

## 0.2.1 — 2026-09-04

- The payload version moved to 2.0.0, the position a removed field earns. 0.2.0 had stamped 1.1.0
  for the same shape; a reader separating shapes treats the two as one.

## 0.2.0 — 2026-09-04

The run-context change 0.1.1 shipped in the patch position, cut again in the minor position the
stability contract requires.

- `EnvironmentSnapshot` reports one `channel` (`RunContextChannel`: `dev`, `beta`, `store`) in
  place of four booleans, and `PayloadKey` carries `runContext.channel` in place of the four
  `runContext.is…` keys.
- The adapter still sends the vendor's legacy `isTestFlight` flag, on every channel.
- The ingest URL writes each path separator once and strips every trailing separator from the base
  path, so it is identical on every Foundation.
- The payload version moved from 1.0.0 to 1.1.0, in error; see 0.2.1.

## 0.1.1 — 2026-09-04

Shipped in the patch position against the rule it should have been cut under: it removed four
`PayloadKey` constants and changed `EnvironmentSnapshot`'s stored properties and initializer.
Depend on 0.2.0 or later instead.

- One run-context channel in place of four booleans, as in 0.2.0.
- The ingest URL writes each path separator once.

## 0.1.0 — 2026-09-03

First release: a consent-gated, dependency-free analytics transport for Swift, with one adapter.
