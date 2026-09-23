# Changelog

What each release changed that a host can see. What a version number promises is in
[STABILITY.md](STABILITY.md); this file is the history that contract was applied to.

## 0.3.2

A patch: nothing in the API list moved, and the payload version stays 2.0.0.

### Configuration and traps

- `AethergramConfiguration` clamps `transmitInterval` and `maxBackoffInterval` only when an
  interval is large enough to have crashed the host at its first retry, so such a configuration
  now runs. Every other value behaves as it did in 0.3.1: a value that is not finite, or not
  positive, still traps at construction, and nothing else is capped. Ceilings for `queueLimit` and
  the intervals are planned for a minor release.
- `TelemetryDeckTransport` traps at construction when given a background `URLSession`. Such a
  session used to abort the host at the first send instead.
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
  file held, up to the newest 1,000 signals, is kept ahead of the recorder's queue in every write,
  for the next process to load and send. Previously the writes stopped for the life of the
  process.
- The look for the erasure mark checks the mark's reachability and no longer reads file
  attributes.

### Retention counters and payload

- Day strings (`acquisition.firstSessionDate` and the distinct-day history) are `yyyy-MM-dd` in the
  Gregorian calendar, in the time zone of the calendar the recorder was given. A device set to
  another calendar used to send its own year, such as a Buddhist year 543 ahead. A stored record
  is converted when the recorder loads it: a day that already reads as a Gregorian date between
  2015-01-01 and tomorrow is kept, any other is read in the recorder's calendar and kept converted
  only if the result lands in that window, and otherwise kept as written. So a rebuilt or
  downgraded record is never converted twice. A record written under the Ethiopic calendar before
  0.3.2 cannot be told apart from a Gregorian one, because the year numbers overlap, and is left as
  written.
- A session's first recorded signal after `beginSession()` is checkpointed, so a session killed
  inside the ten-second checkpoint interval is measured to that signal rather than discarded.
- `endSession()` closes only a session this recorder opened, and a `record` advances only that
  session's checkpoint. A session left open by another process is closed by the next
  `beginSession()` against its own last activity, rather than stretched to now.
- For an app extension — an `.appex` inside an `.app` — `EnvironmentSnapshot.current()` resolves
  the receipt that `runContext.channel` is read from against the containing app's bundle rather
  than the extension's own, falling back to the extension's when the app's bundle gives no receipt
  location.
- A `calendar.hourOfDay` value outside 0-23, which a caller can pass since caller parameters win,
  goes to the wire unchanged instead of trapping the send.
- A caller key spelled as a vendor wire name wins over the package key mapped onto that name, on
  every run. The winner used to depend on dictionary order.

### Scheduling and logging

- The drain runs at utility priority rather than the priority of the call that scheduled it.
- A queue overflow logs once when it begins and once when it ends, and a store skipping writes
  logs when the skipping starts and when it stops, rather than on every record.

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
- Work in flight across an erase is discarded: a send, a counter save, or a queue write from before
  a decline or a reset cannot land after it, and `updateConsent` and `reset()` return once the
  purge has reached the store.
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
