# PGP message state: honest rendering of encrypted mail

Date: 2026-07-25
Status: Approved — ready for implementation planning

## Goal

Make the macOS/iOS app tell the truth about the OpenPGP state of every message
it shows, matching what `kypost-android` already does and what
`kypost-server/docs/E2E_PGP.md` §"Mobile plan" requires of every mobile client.

Today this app reads none of the relay's five `pgp*` fields. Two consequences,
both user-facing defects rather than missing polish:

1. A **client-protected** message (server holds no key, no body is returned)
   renders as an empty message. The user is shown a blank email with no
   explanation and no route to the content.
2. A **server-decrypted** message renders silently, giving the user no way to
   tell that the server read their mail — which is the exact distinction the
   `server`/`client` protection split exists to make legible.

## Background: the two protection modes

`kypost-server` offers two modes, chosen **at key generation only**, with no
downgrade path (`backend/internal/users/users.go:102-115`):

| | `server` | `client` (default) |
|---|---|---|
| Server can read your mail | Yes | No |
| Readable in this app | Yes | No — deep-links to webmail |

**Mobile and desktop-native clients implement only the degradation, never the
crypto.** This is settled, not an open question: `docs/E2E_PGP.md` supersedes an
earlier plan to port the browser's crypto to the native apps, because a device
that pairs by QR never learns the account password that the wrapped key envelope
is sealed under, and every workaround (per-device keys, Keychain-held keys,
server-side re-encryption) is worse than the problem. This app therefore holds
**no** private key and will not gain one under this design.

Deliberate consequence: for a `client`-mode account, this app can never render
encrypted mail. That is the correct behavior, not a limitation to work around.

## Requirements

Straight from `docs/E2E_PGP.md` §"What mobile apps must implement", which names
`kypost-for-Mac` as still needing all five:

1. Read `pgpEncrypted`, `pgpSigned`, `pgpVerified`, `pgpSignerFingerprint`, and
   `pgpDecryptError` off the inbox row. All are `omitempty` server-side, so
   absent means "no OpenPGP content" — the decoded defaults are the contract,
   not an unknown state.
2. `pgpEncrypted` with an **empty** `pgpDecryptError` means client-protected:
   there is no body and this app cannot produce one. Say so, and offer a link to
   webmail. A **non-empty** `pgpDecryptError` is the different case where the
   server tried and failed — show that error.
3. `pgpEncrypted` **with** a body means the server decrypted it. Surface that
   too. Mark the *list* row for the first two cases only.
4. `POST /api/mail/send` returns **409** with `clientSideNeeded: true` when a
   client-protected account asks the server to sign or encrypt. Treat it as
   "not available here", not as a generic failure.
5. The webmail deep link is `/read?mailbox=<mailbox>&message=<messageId>`, with
   `mailbox` omitted for INBOX. Hand it to the system so the user's browser or
   installed PWA handles it — **never** an in-app WebView, which shares no
   session and would put an account-password field inside this app.

## Design

### 1. The rule — `KyPost/Domain/Models/PgpMessageState.swift` (new)

Pure functions, Foundation only, so the decisions are unit-testable without
SwiftUI or a stubbed network, and so no view re-derives them.

```swift
enum PgpMessageState: Equatable, Sendable {
    case none                // No OpenPGP content: render normally.
    case clientProtected     // Encrypted; server deliberately did not decrypt. No body exists.
    case decryptFailed       // Encrypted; server tried and failed. There is a real error to show.
    case decryptedByServer   // Encrypted; server decrypted it for us. Worth disclosing.
}

func pgpMessageState(
    pgpEncrypted: Bool,
    pgpDecryptError: String,
    body: String?
) -> PgpMessageState
```

Ported character-for-character from Android's `pgp/PgpMessageState.kt`
(`pgpMessageStateOf`). **The
ordering is load-bearing:** a non-blank `pgpDecryptError` is checked *before*
the body, because the server populates the error and leaves the body empty.
Reading that as `clientProtected` would send the user to webmail for a message
that will fail there too, for a reason we were already told.

```
!pgpEncrypted              -> .none
!pgpDecryptError.isBlank   -> .decryptFailed
!body.isBlankOrNil         -> .decryptedByServer
otherwise                  -> .clientProtected
```

Two companions in the same file:

```swift
/// SF Symbol for an inbox row, or nil for no marker.
func pgpRowSymbol(_ state: PgpMessageState) -> String?

/// Whether to show a signature verdict at all, given the message state.
func showsSignaturePill(state: PgpMessageState, signed: Bool) -> Bool

func webmailMessageURL(serverUrl: String, mailbox: String, messageId: String) -> URL?
```

`pgpRowSymbol` returns `lock.fill` for `.clientProtected`,
`exclamationmark.triangle.fill` for `.decryptFailed`, and `nil` otherwise.
`.decryptedByServer` is deliberately unmarked: the row opens and reads normally,
so in a `server`-mode mailbox a marker would decorate nearly every row while
carrying nothing the user can act on — and the detail view discloses it anyway.

`showsSignaturePill` returns `true` **only** for `.decryptedByServer` with
`signed == true`. This is a correctness rule, not a styling choice. The web
client (`frontend/src/pages/ReadPage.tsx:1568-1571`) can fall back to a *local*
decrypt for the signature verdict; this app cannot. For a `clientProtected`
message the server never saw the plaintext, so its `pgpSigned`/`pgpVerified`
values are not a verdict about content anyone verified — rendering "signature
not verified" there would assert something we have no basis for. For
`decryptFailed` the web guards on `!decryptFailed` for the same reason.

`webmailMessageURL` returns `nil` when `serverUrl` isn't a usable absolute URL,
which callers render as *no button* rather than a dead one. `mailbox` is omitted
when blank or `INBOX`, matching the links the web app builds for itself.

### 2. Data flow

`RelayEmailDTO` gains five optional fields; the `omitempty` contract means the
Swift-side defaults are authoritative:

```swift
var pgpEncrypted: Bool?          // -> false
var pgpSigned: Bool?             // -> false
var pgpVerified: Bool?           // -> false
var pgpSignerFingerprint: String? // -> ""
var pgpDecryptError: String?     // -> ""
```

`Email` and `EmailEntity` gain the same five with those defaults.

**No schema version bump.** `EmailEntity.sentTo`/`cc` set the precedent: added
to the live entity with `= ""` defaults inside `AppSchemaV2`, no new
`VersionedSchema`. Default-valued property additions are lightweight-migration
compatible, so a V3 stage would be ceremony. (`AppSchemaVersions.swift` already
lists `EmailEntity.self` in V2's models.)

All five are persisted even though only four drive current UI, because a
second migration to add the remaining two later is strictly worse than one now.
`pgpSignerFingerprint` is stored but **not rendered** in this change — matching
the web, which also stores it without displaying it. Displaying it usefully
means comparing it against a contact's saved key, which belongs with the
contacts work, not here.

### 3. UI

**`EmailListRow`** — a leading `Image(systemName:)` from `pgpRowSymbol` before
the subject, with `.accessibilityLabel` carrying the spelled-out text (ported
from Android's `email_row_pgp_*_description` strings). Android used emoji with a
`contentDescription` because screen readers announce emoji inconsistently in a
`TextView`; SF Symbols are the native idiom here and take theme tint, weight,
and Dynamic Type for free. The *logic* is the parity contract, not the glyphs.

**`EmailDetailView`** — three additions, in order above the existing header:

1. A badge row using the existing `StatusBadgeView(label:isActive:)`, which is
   already this app's port of the web's `.security-badge` + `.security-dot`:
   - Encryption pill, whenever `state != .none`: "PGP: encrypted" (active) /
     "PGP: could not decrypt" (inactive).
   - Signature pill, only when `showsSignaturePill` is true: "signature
     verified" (active) / "signature not verified" (inactive).
2. A banner modeled on the sibling `remoteContentBanner` in the same file —
   same `theme.panel` background, `Shape.field` radius, icon + text + trailing
   button. Copy is ported verbatim from Android's `strings.xml`:
   - `.clientProtected`: "This message is end-to-end encrypted. Only your
     browser holds the key, so it can't be read here." with an **Open in
     webmail** button. When `webmailMessageURL` returns nil, the button is
     replaced by the line "Couldn't work out this server's web address — open
     this message in your browser."
   - `.decryptFailed`: "This message is encrypted and couldn't be decrypted:
     \(error)".
   - `.decryptedByServer`: "This message was encrypted. The server decrypted it
     to show it here."
   - `.none`: no banner.
3. Body suppression for `.clientProtected` and `.decryptFailed` — neither has
   readable content, and rendering an empty `EmailBodyWebView` is the current
   defect. `.decryptedByServer` renders the body normally *plus* its banner.

The webmail link opens via `@Environment(\.openURL)`, which hands off to the
default browser on both platforms. Requirement 5 forbids an in-app WebView here;
note that `EmailBodyWebView` is one, so the link must not be routed through it.
`NSWorkspace` (used in `SettingsViewModel`) is macOS-only and is not used.

All three detail surfaces — iOS navigation (`InboxView:84`), macOS split detail
pane (`MacRootView:348`), and the macOS pop-out window (`MacRootView:485`) —
render through `EmailDetailView`, so all three are covered by one change.

### 4. The 409 send path

`NetworkError` currently discards response bodies on non-2xx
(`HTTPClient.swift:142-144`), so `clientSideNeeded` is indistinguishable from
any other 409. Required change:

- `case conflict` becomes `case conflict(body: String)`.
- `NetworkError.from(statusCode:)` becomes `from(statusCode:body:)`.
- Blast radius: two catch sites need `(_)` added
  (`DesktopRegistrationClient.swift:65`, `MfaResponseClient.swift:58`) and the
  409 assertion in `NetworkingTests.swift:155`.

`RelayMailSource.send` decodes the conflict body and, on `clientSideNeeded:
true`, produces a new `MailOutcome.clientSideNeeded` case. The relay-specific
knowledge stays in `RelayMailSource`; `HTTPClient` stays generic.

Message, ported verbatim from Android's `MailSource.kt:51`: "This account's PGP
key is end-to-end protected, so signing and encryption aren't available on
mobile. Send without them, or use webmail."

**This is a defensive mapping.** Neither this app's `RelaySendRequest` nor
Android's sends `sign`/`encrypt` flags, and neither compose screen offers
toggles, so the 409 cannot fire from either client today. It is specified
because requirement 4 specifies it, and because the failure mode it guards
against — a user who asked for signing silently getting an unsigned message — is
the one outcome the server comment says must never happen.

## Non-goals

- **Any on-device PGP crypto.** Settled by `docs/E2E_PGP.md`; see Background.
- **Compose-side sign/encrypt UI.** No client sends those flags today.
- **A webmail *compose* deep link.** Compose stays in-app.
- **Locally computed key fingerprints.** `ScanPgpKeyView` currently displays the
  relay-supplied `fingerprint` string, which Android stopped trusting
  (`pgp/PgpFingerprint.kt`) because a compromised relay could pair an armored
  key with an unrelated fingerprint, making the user's out-of-band check verify
  a label with no cryptographic tie to the key actually saved. **This app has
  that hole today.** It is a contacts/key-exchange defect, not a mail-rendering
  one, and closing it on Apple platforms means hand-rolling OpenPGP v4
  fingerprint computation with no PGP library. Tracked in the parity handoff
  notes, not fixed here.
- **`hasPgpIdentity` badges.** Android's consumers are all contact screens gated
  on the self-flag, which this app does not have yet.
- **Rendering `pgpSignerFingerprint`.** Stored, not displayed; see §2.

## Testing

Both pure functions get full truth tables — no stubs, no SwiftData, no network.

`pgpMessageState`:
- All four states.
- The ordering case: `pgpEncrypted: true`, non-empty error, **and** a non-empty
  body → `.decryptFailed`, not `.decryptedByServer`.
- Whitespace-only body and whitespace-only error both treated as blank.

`showsSignaturePill`:
- `.decryptedByServer` + signed → true.
- **`.clientProtected` + `pgpSigned: true` → false.** The rule most likely to be
  broken by a well-meaning later edit; it gets an explicit test with a comment
  pointing at the reason.
- `.decryptFailed` + signed → false.
- `.decryptedByServer` + not signed → false.

`pgpRowSymbol`: symbol for the two unreadable states, nil for the other two.

`webmailMessageURL`: INBOX omitted; non-INBOX mailbox included; subfolder path
(`Archive/Receipts`); blank messageId → nil; malformed serverUrl → nil;
trailing slash on serverUrl normalized.

`RelayEmailDTO` decoding: JSON with all five fields absent decodes to
`false`/`""`, proving the `omitempty` contract.

`NetworkError.from(statusCode:body:)`: a 409 body carrying `clientSideNeeded`
maps to `MailOutcome.clientSideNeeded`; a 409 with any other body does not.

Existing suite must stay green; note `KyPost.xctestplan` keeps
`parallelizable: false` on both test targets, and that must not change (see root
`AGENTS.md`).

## Verification

```sh
xcodebuild test -scheme "KyPost" -destination 'platform=macOS'
```

## DOX

`KyPost/Presentation/AGENTS.md` gains the row-marker and banner contracts. Root
`README.md` "Known gaps" loses nothing — none of these were listed — but the
Features section gains a PGP-state line.
