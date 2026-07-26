# Android parity brief A: security hardening

Date: 2026-07-25
Status: Handoff brief — for a fresh session. Not a design; a scoping note.

## What this is

One of three buckets from a 2026-07-25 gap analysis between `kypost-android`
and `kypost-for-Mac`. Bucket B (PGP message state) has its own approved design
at `2026-07-25-pgp-message-state-design.md`. This is bucket A. Bucket C is
`2026-07-25-android-parity-brief-C-contacts-and-relay.md`.

## Start here, and read this first

**A 659-line design already exists:
`docs/superpowers/specs/2026-07-22-security-hardening-design.md`.**

Do not write a new one. It was ported from Android's equivalent
(`kypost-android/docs/superpowers/specs/2026-07-22-security-hardening-design.md`,
413 lines) and then substantially *re-derived* against this repo's actual
architecture — it is longer than its source because it verified rather than
assumed. Its status line says "Draft — not yet reviewed." That review is the
first task, not a rewrite.

Spot-check its claims before trusting them wholesale; it was written by a
session that read the files, but it has not been checked by a second pair of
eyes, and the codebase has moved since (the KyPost rename landed after it).

## What Android shipped that this app lacks

All on 2026-07-22, roughly 40 commits, all in
`app/src/main/java/com/urlxl/mail/security/`:

| Android file | What it does |
|---|---|
| `AppLockManager` / `AppLockStore` | lock state, encrypted PIN storage |
| `PinHasher` / `PinPolicy` / `LockoutPolicy` | PBKDF2 PIN, escalating delays, 10-attempt wipe |
| `UnlockActivity` / `LockedActivity` | unlock UI, biometric via `androidx.biometric` |
| `SecuritySettingsActivity` | three toggles with dependency rules |
| `HostileLocationSettings` / `SecurityWipe` / `AppRestart` | no-cache mode, full reset, process relaunch |
| `EphemeralAttachmentProvider` / `AttachmentAction` | disk-free attachment viewing |
| `CredentialCipher` / `CredentialGateSync` | PIN-derived wrapping of the device secret |
| `SpkiPinner` / `PinnedCallFactory` | TOFU certificate pinning |
| manifest | `allowBackup=false`, `FLAG_SECURE` on sensitive screens |

## The one decision that is already made, and diverges from Android

The existing spec (§"Design decision: lean on the platform passcode, don't roll
a custom PIN", line 256) calls for
`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` as the **only** unlock
mechanism — no custom PIN screen.

This is a deliberate divergence from Android, argued at length, and it cascades:
it deletes the need for `PinHasher`, `PinPolicy`, `LockoutPolicy`, and the
custom lockout bookkeeping, and it changes Feature 3's credential gate from
Android's PIN-derived key (`CredentialCipher`) to a Keychain access-control flag
(`kSecAccessControlBiometryCurrentSet` / `.userPresence`).

**Do not "restore parity" by porting the PIN machinery back in without
re-opening that argument.** The reasoning: the OS already provides rate-limiting
and lockout (hardware-backed on iOS), and a custom PIN on macOS would degrade to
"our own PIN screen with no biometric option" on the many Macs without Touch ID.
The stated cost is that unlock becomes "prove you own this device" rather than
"prove you know this app's secret" — a real difference for someone who shares a
device passcode. If that matters, the spec names the incremental fix.

## Known-hard part, flagged by the spec itself

Hostile Location Protection needs the DI graph rebuilt at runtime, because
`SingletonGraph.shared` is a `static let` and every DAO is a `lazy var`
capturing `database.container` at first access, with `KyPostApp` binding the
container once at the `WindowGroup`. The spec describes an
`AppEnvironment`/graph-rebuild mechanism **at the design level only** and
explicitly defers its implementation plan — how `.id(generation)` interacts with
in-flight `Task`s and with open windows and sheets on macOS is called out as
warranting its own design pass.

Budget for that as a separate spike. It is the single most likely thing to blow
up an estimate here.

## Also out of scope per the existing spec

Duress passcode, jailbreak detection, clipboard flagging, secure/overwrite
delete of the old store, blocking plain iOS screenshots (no supported API —
only screen recording and mirroring can be mitigated), and any server-side work
on short-lived or scoped push tokens.

## One extra item, folded in from bucket B

**`ScanPgpKeyView` trusts a relay-supplied fingerprint.** It displays
`key.fingerprint` straight from the `PgpQrClient` response
(`KyPost/Data/Networking/PgpQrClient.swift:48`,
`KyPost/Presentation/Screens/ScanPgpKeyView.swift:154`). Android stopped doing
this deliberately — `pgp/PgpFingerprint.kt` computes the fingerprint from the
key's own bytes, because a compromised relay could otherwise send an armored key
paired with an unrelated fingerprint string, and the user's out-of-band "does
this match?" check would be verifying a label with no cryptographic tie to the
key actually saved.

This app has that hole today. It was excluded from bucket B because it is a
key-exchange defect rather than a mail-rendering one, and because closing it
means hand-rolling OpenPGP v4 fingerprint computation: de-armor the base64,
parse the public-key packet, SHA-1 over `0x99 || len || body` via CryptoKit.
Android gets it free from BouncyCastle; this repo has no external Swift
packages, and adding a PGP dependency for one function is its own decision.

It belongs here because relay-trust assumptions are already this bucket's
subject. Roughly 150 lines plus a test suite with known-answer vectors.

## Suggested first moves

1. Review the existing spec against the current tree; fix what has drifted.
2. Decide the `LAContext`-vs-PIN question for real (the spec recommends; nobody
   has ratified).
3. Split the `AppEnvironment` graph-rebuild into its own design pass.
4. Then `superpowers:writing-plans` on what remains.
