# Security

## Reporting a vulnerability

Report it privately through GitHub's [private vulnerability
reporting](https://github.com/seriouslysean/aethergram/security/advisories/new), which opens a
draft advisory visible only to you and the maintainer. Do not open a public issue.

That link works only while private vulnerability reporting is enabled in Settings → Advanced
Security. If that page is not available the setting is off, and saying so in a public issue,
without describing what you found, is enough to get it turned on.

This is a solo project. It offers no response-time commitment, because it could not keep one.

## What the consent gate covers

Consent is the trust boundary and it is checked before anything happens. Until the host calls
`updateConsent(.granted)`, `record` enqueues nothing, writes nothing to disk, resolves no
identifier, advances no counter, and reaches no transport. Withdrawing consent erases the queue
file, the retention record, and the pending batch.

Erasing is best effort against a filesystem that can refuse it, and that is the one place the
promise is narrower than it sounds. If the queue file can be neither deleted nor overwritten, the
bytes stay where they are, and what is still guaranteed depends on how far the refusal went. The
store that was told to erase refuses to read that file for as long as it lives, so nothing goes
out through it. A mark written beside the file carries that refusal into later processes. Where
even the mark is refused — one set of permissions can stop all three — the refusal ends with the
process that made it, and a later one can read a file it was never told about.

So: bytes outliving a delete the filesystem refused is that failure and not this one. Those bytes
restored or sent while the store that erased them is alive, or while a mark it managed to write is
standing, is a vulnerability.

In scope is anything that gets data past that gate: a path that enqueues before the check, a
provider closure invoked while the answer is withheld, a queue file that survives a decline, a
counter that a host's data reset cannot reach, or a grant that resurrects signals recorded under
a previous decline.

Also in scope is the wire: a request built with a field the host did not supply, a payload that
carries more than the caller passed, or an adapter that persists anything at all. Adapters own the
wire and nothing else, so anything an adapter writes to disk is a bug in this model.

## What the package does not cover

The package does not decide what a signal means. Names, parameter keys, and values are the host's,
and a host that puts a user's name in a parameter has published a user's name. Nothing here
inspects payload content, and a report that this package transmitted what a caller handed it is
not a vulnerability.

Nor is the identifier the package's. `clientUserProvider` is the host's, called only on a transmit
consent already permits; how it is derived, whether it is stable, and whether it is reversible are
the host's decisions and the host's disclosure.

The queue file is a normal file in a directory the host chose. It has the permissions that
directory has, and an attacker who can write there can write to the whole container. No file
layout changes that, and reports resting on that access are not vulnerabilities in this model.

The vendor `appID` is public by that vendor's convention and ships in every binary. Finding it in
a binary is expected.
