# Android feature parity — implementation plan

Date: 2026-08-18
Status: Plan. Supersedes the open items of the 2026-07-25 parity briefs A/B/C.
Reference repo: `../KyPost-for-Android` @ `56d72a3`

## What this is

A gap analysis between `KyPost-for-Android` and this repo, and the ordered
work to close it. The 2026-07-25 briefs split the same problem into buckets
A (security hardening), B (PGP message state) and C (contacts/relay/settings).
A and B have landed. **C never did**, and Android has since shipped an entire
on-device PGP stack that did not exist when those briefs were written.

Android is the reference implementation for every relay contract. Its
`app/AGENTS.md` and `app/src/main/AGENTS.md` are the binding statements of
those contracts; read them before touching a wire format. Do not guess.

## Scope decisions taken before writing this

- **On-device PGP is in scope, sequenced in line** (Phases 7–10). This reverses
  the README's "This app holds no PGP private key by design" and the "no
  external Swift package dependencies" property. Both claims get rewritten as
  part of Phase 8, not quietly left stale.
- **Contacts must behave the same as on Android**, which settles the groups
  question in full: the group layer *and* its `CNGroup` materialization in
  Apple Contacts are both in scope (Phase 5).
- **The app-lock PIN, lockout ladder and wipe are in scope** (Phase 11). This
  reverses `AppLockStore.swift`'s written decision — "Deliberately no PIN or
  lockout fields — verification is LAContext's job, lockout is the OS's" — and
  the README's "The OS owns the rate-limiting and the lockout, and there is no
  app-specific PIN." Reversing it is the point; say so in the docs rather than
  deleting the old sentence and pretending it was never the position.
- **Out of scope, deliberately:** iPad/large-screen master-detail (Android's
  2026-08-14 foldable work; macOS already has `NavigationSplitView` and iOS
  regular-width was not asked for), the downloaded-attachment ledger (its
  Android premise is the shared Downloads collection, which has no Apple
  analogue the app can reach back into), and UnifiedPush (Android's
  FCM-alternative; APNs is the only Apple transport).

## Where the two apps actually stand

Endpoints Android calls that this app does not:

| Endpoint | Phase |
| --- | --- |
| `GET /api/groups` | 5 |
| `GET /api/mail/pgp-payload` | 9 |
| `POST /api/mail/send-pgp` | 10 |
| `POST /api/pgp/recipients/resolve` | 10 |
| `POST /api/pgp/device/enrollment-key` | 7 |
| `GET /api/pgp/device/envelope` | 7 |
| `POST /api/pgp/device/enrollment-state` | 7 |

Endpoints this app calls that Android does not: `POST
/api/notifications/desktop/register` (desktop pairing — correctly ours alone).

Already at parity, and not to be re-litigated: 15 themes (exact name and
palette match), keyword tabs, contact sync + dedupe + reconciliation, system
contacts two-way export, pull mode and the notification cursor, MFA number
matching, deregister/unpair, TOFU SPKI pinning, Hostile Location Protection,
attachments (send, list, download), reply/reply-all/forward, server draft
save, the four-state `PgpMessageState`, and the PGP QR key exchange.

`README.md`'s "Known gaps (v2 candidates)" list is stale: attachments, reader
actions and draft save have all landed. Fix it in Phase 0.

---

## Phase 0 — Contracts and repo housekeeping

Cheap, unblocks the rest, no runtime change.

1. **Import `Mobile_Mail_Relay.md`.** `README.md` and `AGENTS.md` both name it
   as the source of truth for relay endpoints and payload shapes, and the file
   does not exist in this repo. Copy it from Android and mark it as mirrored,
   not owned.
2. **Update this repo's `Client_Encrypted_Send.md`.** Android's copy carries a
   "PARTLY SUPERSEDED" banner explaining that its central premise — "This
   device never holds the account's private key" — stopped being true when
   enrollment landed. Ours still asserts the superseded premise as fact, and
   Phases 7–10 will contradict it. Port the banner, adapted.
3. **Rewrite `README.md`'s known-gaps list** to what is actually missing.
4. **Add `SECURITY.md`.** Android has one that is honest about where each
   control stops. This app has none, and it ships the same TOFU pinning, the
   same HLP tradeoffs and (after Phase 8) the same on-device key. Mirror the
   structure; the Apple specifics differ.
5. ~~**Add `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`**~~ — already landed
   upstream in `7e1fbbf`.
6. **Fix `main`, which does not compile** (found 2026-08-18, present on
   `origin/main`). `NetworkError.responseTooLarge` was added by the
   hostile-review fixes and `MailOutcome.message(for:)` was never updated, so
   the switch is non-exhaustive. The test target then fails separately on
   `DesktopPairingService.isValidCode` being called from a nonisolated context.
   Both are fixed in the same working tree as 5e; they are one-liners.

   **Three tests also failed on `origin/main`. All three are now resolved:**
   - `MfaNumberMatchTests.orderDoesNotPinTheAnswerToOnePosition` — a real
     security bug, and the pinned position was the smaller half of it. The
     Swift port was still on a design Android has since removed wholesale:
     client-invented LCG decoys seeded on the challenge id (so the wrong
     answers, and by elimination the right one, were derivable by anyone
     holding the id), a hardcoded 2-digit width, and a deterministic "shuffle"
     that did not vary by challenge. Ported Android's current
     `push/MfaNumberMatch.kt`: server-supplied values only, width from the
     server, real shuffle held for the life of the challenge. **Done.**
   - `PinnedSessionDelegateTests.anUnsupportedKeyShapeProducesNoHash` — the
     test was stale, not the code. A DER fallback was added so key shapes
     outside the six-entry header table still hash, because otherwise the pin
     silently never armed for them. Verified the RSA-1024 fixture's expected
     hash independently with `openssl` rather than adopting what the code
     emitted. **Done.**
   - `NetworkingTests.parsesOptionalRegParameter` — also a stale test: its
     `reg` was cross-origin with `srv`, which the parser now refuses by
     design. The refusal already had its own test. **Done.**

7. **Add CI.** There is no `.github/` here at all. Android has `ci.yml`,
   `codeql.yml` and `release.yml`. Minimum: `xcodebuild test` on the shared
   test plan for every PR. Note `KyPost.xctestplan` must keep
   `parallelizable: false` on **both** test targets — see `AGENTS.md` for why
   (roughly one run in six otherwise SIGABRTs inside SwiftData).

---

## Phase 1 — Relay wire parity

Small, self-contained, no new dependencies. Do this before Phase 2; delta sync
is much harder to reason about on top of a body whose mode is guessed.

### 1a. `bodyMode` and `hasAttachments` — **done 2026-08-18**

`RelayEmailDTO` (`KyPost/Data/Mail/RelayMailSource.swift:44`) decodes neither.
Android's contract:

> Email bodies carry the relay's `bodyMode` (`html`/`plain`) through the Room
> cache and into `EmailDetailActivity`; plain bodies must be escaped into
> whitespace-preserving block markup for HTML fallback/quoting, while **HTML
> bodies must not be detected by content when the server supplied a mode**.

Decode both, carry `bodyMode` through `EmailEntity` to the reader, and render a
known-plain body natively rather than through WebKit — Android does this so
reading never requires horizontal scrolling. `hasAttachments` drives the row
marker. Schema migration required (`AppSchemaVersions.swift`).

### 1b. Folder CRUD — **done 2026-08-18**

Android's `MailSource` has `createFolder` / `renameFolder` / `deleteFolder`,
and `FolderInfo` carries `deletable`. Ours lists folders and nothing else. Add
the three calls, the `deletable` field, and the sidebar/folder-menu affordances.

### 1c. The missing `MailOutcome` cases — **done 2026-08-18**

Ours has 8 cases; Android's has 10, and the three it has that we lack are each
a different sentence to the user:

- **429 + `Retry-After`** → `rateLimited(retryAfter:)`. This is parity brief
  C5, still open. `NetworkError.rateLimited` exists but `HTTPClient` discards
  response headers on non-2xx, so the seconds never reach the user. Android
  notes this must be mapped in the per-request path, **not** in the status-code
  mapper, which cannot see headers. Same constraint applies here.
- **400 "imap configuration is required…"** → `notConfigured`. Direct the user
  to the web app. Android's rule is absolute: *never build UI for the server's
  web-only mail configuration endpoints; an unconfigured relay is an empty
  state, not a form.*
- **502** → `upstreamFailure`, retryable with backoff. Currently collapses into
  a generic failure string.

---

## Phase 2 — Mail delta sync — **done 2026-08-18**

The largest non-PGP item. Every refresh here fetches a full folder snapshot;
Android has a cursor, a delta merge and a documented self-heal.

Port `MailCursorStore`, `MailFetchResult`'s delta fields, `reconcileFetchResult`
and the `forceFullResync` path. Three things must not be lost in translation:

1. **`isFullWindow` is not the wire's `delta` flag.** A relay predating the
   matching server fix labels a `since=0` response `delta: true` all the same.
   `isFullWindow` is what tells you `messages` is complete enough to prune the
   folder against, and pruning is the only self-heal for a removal you were
   never told about.
2. **The nil-body hazard is already documented in our own code.**
   `RelayMailSource.swift:52-56` records it: `body: String?` collapses to `""`
   in `toDomain`, so a body-less delta "updated" row for a server-decrypted
   message evaluates to `.clientProtected` and sends the user to webmail for a
   message they can already read. Carry nil through as a distinct "unknown"
   **before** enabling delta fetches. This is a prerequisite, not a follow-up.
3. **A push tap must force a full resync before opening its target.** Android's
   contract: the cached row is fine for the list, but opening it before the
   resync can render the detail screen with a stale `bodyMode` or stale PGP
   state. Neither `PushNotificationDispatcher` nor `DeepLinkHandler` does this
   today.

---

## Phase 3 — Phishing flag — **done 2026-08-18**

Tiny and high-value. The server sets the RFC 8621 reserved keyword `$Phishing`
on inbound mail impersonating KyPost itself. Android's `mail/PhishingFlag.kt`
is 25 lines: a literal, and a case-insensitive membership test — case-insensitive
because IMAP keywords are, and a case-sensitive check silently drops the
warning on precisely the mail it exists for. The message is flagged in place;
nothing moves or hides mail.

Port the helper, badge the row and the reader header, add the test.

---

## Phase 4 — Push metadata disclosure — **done 2026-08-18**

Parity brief C6's substantive half. Android warns users that push notifications
relay metadata (sender, subject) through a third party. This app has the same
path — APNs instead of FCM — and says nothing. Port the disclosure onto
Settings → Security. Skip Android's dp-scaling layout work; it has no analogue.

---

## Phase 5 — Contacts depth — **done 2026-08-18** (parity brief C, reopened)

### 5a. Groups

Android: `data/GroupDao`, `GroupEntity`, `GroupLinkDao`, `GroupLinkEntity`,
`contacts/GroupsSyncClient`, `GroupSyncModels`, `GroupSyncRepository`,
`contacts/device/DeviceGroupLinker`. Here: `Contact.groupIDs: [String]`
(`Domain/Models/Contact.swift:93`) and nothing that resolves those UUIDs.

`GET /api/groups` is **pull-only with no delta cursor** — always a full fetch,
full local refresh. Two-way group creation (`POST /api/groups`) is explicitly
out of scope in Android's own client. Do not design past that without checking
the server.

**Decided: materialize groups as `CNGroup`**, matching Android's
`DeviceGroupLinker`. Contacts behave the same on both platforms; a group that
exists in the app and not in Apple Contacts is a divergence, not a
simplification. `SystemContactsExporter` gains group membership alongside the
card export, under the same link-based identity discipline it already uses for
cards — a `CNGroup` the app did not author is adopted, never rewritten or
deleted.

Note this interacts directly with Phase 5e's bug: group membership is a second
thing that duplicates when card identity is misjudged, so land 5e first.

### 5b. Self flag, delete confirmation, sync intro popup

Three separate Android features, each with a design spec in
`../KyPost-for-Android/docs/superpowers/specs/`:

- `dto.isSelf` — absent here entirely, and Phase 5c depends on it.
- A confirm step before contact deletion (2026-07-19 spec).
- A first-run explainer before contact sync begins (2026-07-19 spec).

The fields editor (`RepeatableFieldList`, `ExpandableSectionView`) is **not**
assumed missing — compare against our `LabeledListEditor` first.

### 5c. PGP identity badges

Android's `pgp/PgpIdentityStatus.hasPgpIdentity` answers "does the paired
account have a PGP identity on the server," and every consumer is gated on
`isSelf`. Two rules to carry over verbatim:

- There is **no device-reachable identity endpoint**. `GET /api/pgp/identity`
  is web-session-cookie only, so Android reuses the QR token mint (`GET
  /api/pgp/qr/token`) and reads 200-vs-400 as yes-vs-no.
- It returns **nil, not false**, when the check cannot be made. Callers must
  not render "no identity" for "couldn't ask."

Also port Android's rule that **the account's own PGP identity is never in the
contacts database**. Reading the self-contact's `pgpKey` for the badge or the
fingerprint is the bug both helpers replaced — it is empty for essentially
every user. The fingerprint beside the user's own QR comes from
`GET /api/pgp/bootstrap`'s `publicKey`, hashed locally by `PgpFingerprint`.
Never from `/api/pgp/qr/key`: that is single-use server-side, so fetching our
own key with it burns the code being displayed.

### 5e. The match-key asymmetry — **fixed 2026-08-18**

Found while scoping this phase, and fixed ahead of it because groups ride on
the same identity machinery.

`SystemContactMapper.matchKeys(for: CNContact)` offered **every** email a card
carries. `matchKey(for: Contact)` offered only `emails.first`. A person the app
knew by two addresses, whose card in Contacts.app carried only the second one,
matched on neither side:

1. `adoptMatchingCards` found no candidate, so the export created a **second
   card** in Contacts.app.
2. `importNewCards`' identity guard (`knownKeys`) held only primary emails, so
   the user's original card read as someone the app had never heard of and
   became a **second app contact** — created with `needsSync: true`, so the
   duplicate was pushed to the relay and fanned out to every other device.

Both sides now offer every identity they hold. `repairImportedDuplicates` was
also rewritten to group by connected components over shared keys: it grouped on
a single primary-email key, which is exactly the key the two duplicate rows
disagree on, so it could not clean up after the bug it exists to clean up
after. Regression tests cover both halves plus the two ways the new grouping
could over-merge.

**Still open, and Phase 5's first task:** `Contact.primaryEmail` /
`primaryPhone` are `emails.first` / `phones.first`, so email *order* remains
load-bearing in other places. Audit the rest of the contact layer for the same
assumption before adding groups on top of it.

### 5d. Pending contact change queue — **evaluated, skipped; the defect it hid is fixed**

The queue itself is not needed here: Android's exists to carry a payload
snapshot per edit, and this app's `needsSync` flag plus
`ContactSyncReconciliation` covers the same ground.

But the property the queue provides *structurally* was genuinely missing. A
push reads its payload before the network call and then cleared `needsSync`
**by localId**, so an edit landing while the push was in flight was marked
synced without ever having been sent — a silent lost update. `clearNeedsSync`
now takes the pushed snapshots and clears only where `updatedAt` has not
advanced, which is the same discipline `ContactDAO.upsert` already applies to
the mirror-image case (a stale server write landing after a local edit).

Fixed with the mechanism already in the codebase rather than by porting the
queue — which is what "most at risk of being cargo-culted" was warning about.

Android has `PendingContactChangeDao` + `PendingContactChangeEntity`; we rely
on `ContactEntity.needsSync` plus `ContactSyncReconciliation`. Brief C flagged
this as **the item most at risk of being cargo-culted** — Android's queue may
exist for `WorkManager` scheduling reasons that do not apply. Establish that it
is a real gap before building anything.

---

## Phase 6 — The signature trust model — **done 2026-08-18**

Prerequisite for Phase 9, and worth shipping on its own. Our `PgpMessageState`
has the four content states; Android has those **plus** a six-value
`PgpSignatureState`: `NONE`, `VERIFIED_CONFIRMED` (a bound key the user
confirmed out of band — the only state that claims identity),
`VERIFIED_SEEN_BEFORE` (still matches its TOFU pin, never confirmed — claims
continuity only, "same key as last time"), `SIGNER_UNKNOWN` (no bound key; an
ordinary correspondent, a rotated key and a forged `From` are locally
indistinguishable, so this is not an accusation), `KEY_CHANGED` (bound and no
longer matching — the one alarm worth raising), and `INVALID`.

Row marking: `KEY_CHANGED` and `INVALID` outrank the content states with a
warning glyph. `SIGNER_UNKNOWN` deliberately does not mark.

**The non-negotiable rule: no client-side `From` parser.** Android deleted
theirs after a differential harness found 27 divergences from the server's
parser across 111 adversarial headers — worst, an RFC 5322 comment like
`Bob (Eve <eve@evil>) <bob@x>`, where the client bound `eve@evil` and the
server binds `bob@x`, letting any contact forge a verified badge for anyone.
The server ships `signerKeys` **already narrowed** to the sender it resolved.
Consume that narrowing; do not reproduce it.

Audit `Utilities/EmailAddress.swift` and `RelayMailSource.splitSender`
(`RelayMailSource.swift:100`) against this. Splitting a sender for *display* is
fine. Binding a signature verdict on it is the defect above. Confirm in code
that the display path and the trust path never meet.

Also port: `signerKeyIdsOf` excludes revoked and expired keys before a
signature can become a trusted state.

---

## Phase 7 — Device enrollment — **next** (no OpenPGP dependency)

The ceremony that seals the account's private key to this device. **This phase
needs no third-party code** — CryptoKit and the Secure Enclave cover all of it.
That is why it comes before the crypto core.

Android source: `pgp/EnrollmentCeremony` (390 lines), `EnrollmentVault`,
`DeviceEnvelope`, `EnrollmentClients`, `EnrollmentState`, `EnrollmentSession`,
`VaultOpener`, `DeviceEnrollmentActivity`. Design specs:
`2026-07-29-on-device-pgp-decryption-design.md` and
`2026-08-06-device-enrollment-ceremony-design.md`.

### The envelope format — fixed wire contract

```
{ "v": "2",
  "alg": "ECDH-P256+HKDF-SHA256+A256GCM",
  "epk": <base64 browser ephemeral public key>,
  "iv":  <base64>,
  "ct":  <base64> }
```

HKDF-SHA256 info string `kypost-device-envelope/v2`, GCM tag 128 bits,
**length-prefixed AAD** (v1's pipe-delimited concatenation was the v1→v2
break). The version tag, the info string and the AAD prefix move together —
changing one alone strands every enrolled device.

Anything malformed, unsupported or wrong-sized parses to nil, and nil means
"re-run the ceremony", never "retry".

### The Apple mapping

- Device keypair: **Secure Enclave P-256**, created with
  `SecAccessControlCreateWithFlags(..., .privateKeyUsage, [.userPresence])`.
  ECDH via `SecKeyCopyKeyExchangeResult`; HKDF and AES-256-GCM via CryptoKit.
- **Allow the device passcode, not biometry-only.** Android's reasoning maps
  exactly: `.biometryCurrentSet` invalidates the key whenever a fingerprint or
  face is added, costing every ordinary user a full re-enrollment; and
  enrolling a biometric already requires the passcode, so the attacker it would
  exclude already holds what this key accepts. `.userPresence` is the choice.
- **No passcode set → cannot enrol.** The envelope's protection *is* the lock
  screen. Report that honestly rather than degrading silently.
- **Adopt an existing key only if it still matches the spec.** Android's
  `existingKeyMatchesSpec` exists because presence-only checks meant a key
  generated by an earlier build with weaker parameters was reused forever with
  no signal — and it silently no-ops exactly the migration the design plans for.

### The ceremony

120-second code buckets, 3-second poll, 5-minute window. Port
`EnrollmentCeremony` as a **platform-free state machine** with injected ports —
the whole reason it exists on Android is that logic living in an Activity is
logic no unit test can reach. Here that means it belongs in `Domain/`, driven
by protocols, testable under Swift Testing with no host app. Every branch is a
user-visible outcome: identity missing, publish rejected, poll timeout,
envelope 404, GCM open failure, auth cancelled, no passcode, re-seal failure,
report failure, user abandons.

A background completion is impossible, not merely undesirable: the re-seal
needs a live authentication prompt, so the tail requires the user present and
the app foregrounded.

**404 covers both "never sealed" and "expired"** and they are indistinguishable
by design — one case, so a caller cannot accidentally split them.

### The HLP gate

The envelope is accepted **only when Hostile Location Protection is off**, and
is destroyed when HLP is turned on. It is a deliberate, user-chosen posture
change, not a default. Wire this into `HostileLocationProtectionStore`'s
enable path alongside the existing cache erase.

### Endpoints

`POST /api/pgp/device/enrollment-key` (publish), `GET
/api/pgp/device/envelope` (poll), `POST /api/pgp/device/enrollment-state`
(report). Build every URL from the **paired origin**, never from a
server-supplied URL — a tampered response must not point an authenticated call
at another host, outside the TLS pin. All three go through the pinned session
delegate; on Android the pinning parameter was made non-defaultable precisely
because one call site forgot it and sent the device credential unpinned.

---

## Phase 8 — The OpenPGP crypto core

**This is where the dependency lands, and where two README claims die.**

### The library: GopenPGP v3 — decided

Swift has no OpenPGP in the stdlib. CryptoKit gives AES-GCM, HKDF, P-256 ECDH,
Ed25519, X25519 and SHA — enough for Phase 7's envelope, and nowhere near
enough for OpenPGP packet parsing, key handling, PGP/MIME or compression.
Android leaned on BouncyCastle `bcpg` for exactly this.

**The choice is GopenPGP v3** (Proton, MIT). The deciding argument is that
Proton Mail iOS ships it: this is the one candidate already carrying a real
encrypted-mail client on these platforms, against the same interop surface
(Autocrypt-harvested keys, PGP/MIME, other people's implementations) that this
app has to survive. ObjectivePGP and Sequoia are not to be revisited without a
conversation — the former's commercial-use terms would need clearing against
GPL-3.0, and the latter adds a Rust toolchain and an LGPL static-linking
analysis for iOS.

Integration rules:

- Ship a **prebuilt, checksum-pinned XCFramework**. Do not add a Go toolchain
  to CI; a mail client's crypto should not be rebuilt from source on every PR
  by machinery nobody reviews.
- Record the version, the checksum and the rejected alternatives in
  `AGENTS.md`, next to the sentence about this repo having had no dependencies.
- Wrap it. Every call site talks to our own `PgpDecryptor` / `PgpEncryptor`
  protocols, never to GopenPGP types directly — the v2→v3 API break is recent
  enough that a swap should touch one file.

### The port

`PgpDecryptor` (242 lines), `PgpEncryptor` (196), `PgpMimeReader`,
`PgpMimeWriter` (175), `SignerBinding`, `Sec1Point`. Carry over the
**32 MiB decompressed-plaintext cap enforced before allocation** — a zip bomb
in an encrypted message is otherwise an OOM kill.

### The documentation debt this creates

Not optional, not a follow-up:

- `README.md`: "This app holds no PGP private key by design" is false after
  this phase. So is "The app has no external Swift package dependencies."
- `Client_Encrypted_Send.md`: Phase 0's banner now applies in full.
- `SECURITY.md` (new in Phase 0): gains the device-enrollment section — the
  envelope is HLP-gated, unwrapping requires the device passcode, a security
  wipe destroys it, and if the wipe cannot, it reports itself incomplete.
- `AGENTS.md`: the dependency and the key-custody reversal both belong here.

---

## Phase 9 — Reading client-protected mail on device

Android source: `pgp/EncryptedMessageReader` (207 lines), `PgpPayloadClient`,
`EnrollmentSession`, `VaultOpener`. Spec:
`2026-08-07-on-device-encrypted-mail-reading-design.md`.

`GET /api/mail/pgp-payload` returns the ciphertext, the detached signature, the
`signerKeys` **already narrowed to the sender the server resolved**, the raw
`From` (display only), and `resolvedSender` (the addr-spec the verdict is
about). Render `resolvedSender` wherever a verdict is shown — it and the raw
sender are separable by an attacker.

Port the full exit table as distinct cases, not one error string: `decrypted`,
`needsUnlock`, `cancelled`, `notEnrolled`, `noSecureLockScreen`, `tooLarge`,
`notClientProtected`, `noEncryptedContent` (404 — terminal, so the UI must not
offer Retry), `unsealFailed`, `fetchFailed`, `decryptFailed`. `cancelled` is
not an error: the user dismissed a sheet they raised, and the screen goes back
to offering Decrypt.

**The decrypted body is never persisted.** Not to SwiftData, not to the cached
body field. It lives in the view for the life of the view.

`clientProtected` stops meaning "cannot be read here" and starts meaning "not
readable here **unless** this device is enrolled and unlocked". Webmail remains
the fallback for every device that is not. `PgpMessageState` and its row-marker
helpers need updating for the new meaning.

Session handling: hold the unsealed key for a configured lock window, and clear
it on app lock, backgrounding and memory pressure. Note honestly — Android's
own spec does — that this may *increase* authentication prompts versus webmail,
which holds the key for the life of the page.

---

## Phase 10 — Client-side encrypted send

Android source: `pgp/ClientEncryptedSender` (195 lines),
`RecipientResolveClient`, `PgpComposeState`, `ComposePgpController`. Spec:
`2026-07-26-client-encrypted-send.md`.

`pgpComposeStateOf(hasIdentity, protection, deviceEnrolled, accountAddress)` is
the whole routing rule; its `clientSide` flag sends compose down
`ClientEncryptedSender` instead of the normal send. Webmail stays the fallback
for an unenrolled device, and for an enrolled one whose `accountAddress` is
blank — no `From` could be built, so the relay would 403.

Rules that are each a specific defect someone already found:

- **Recipient keys come from `POST /api/pgp/recipients/resolve`** — the
  endpoint the server-custody path must never call, and this is the only path
  that may. The inverse rule (use `/check`, never `/resolve`) still holds
  everywhere else. On `/resolve`, 200/409/413 are JSON while 400/500 are plain
  text; that differs from `/check`.
- **Split with `splitRecipientFields`, not `splitAddresses`** — the latter
  dedupes across To/CC/BCC and collapses a BCC recipient into the To header.
- **To+CC share delivery 0; each BCC gets its own ciphertext**, so no BCC
  recipient's key id appears in a packet another recipient can read. Delivery 0
  stays first: index 0 failing is a hard 502, later failures only a warning.
- **The outgoing envelope has no `bcc` field by construction**, and the writer
  emits a fixed, closed header set. That is what structurally guarantees the
  relay's forbidden headers (`Received`, `Authentication-Results`,
  `Return-Path`, `Bcc`) can never appear.
- **The real subject rides inside the ciphertext as a protected header**; the
  outer subject is always the fixed placeholder matching the server's constant.
- **The Sent copy is encrypted to the public half of the vault key**, never to
  bootstrap's `publicKey`. A hostile server supplying "your" key would
  otherwise get a readable copy of every message sent.
- **`tier == "key_changed"` is a broken TOFU pin** — a distinct, louder
  outcome, never folded into "no key on file".
- **There is no pickup fallback on this path and there must not be.** The
  server-side one works by storing plaintext, which is the exact thing client
  custody exists to prevent.
- **`accountAddress` is bootstrap's `suggestedUserIDs[0]` and nothing else** —
  the server derives it from the same expression. Not from the public key's
  User ID, not from the self-contact.
- **Cache the bootstrap, not the composed state.** Custody is fixed at key
  creation, but enrollment can change mid-process, so re-probe on every compose.
- **Sign-only is impossible** on this path (the relay accepts
  `multipart/encrypted` only), so the two chips couple when `clientSide`.

Exit table as distinct cases again: `sent`, `cancelled`, `notEnrolled`,
`noSecureLockScreen`, `unsealFailed`, `notClientProtected`, `noAccountAddress`,
`keyChanged`, `keysMissing`, `tooManyRecipients`, `resolveFailed`,
`encryptFailed`, `sendFailed`.

---

## Phase 11 — App-lock PIN, lockout ladder, and wipe

**This reverses a written decision.** `AppLockStore.swift:6-8` and the README
both state that verification is `LAContext`'s job and lockout is the OS's.
Phase 11 replaces that position. Update both, and say what changed and why,
rather than editing the old sentence out.

Android source: `security/PinPolicy` (66), `PinHasher` (86), `PinGate` (72),
`LockoutPolicy` (23), `AppLockStore` (219), `AppLockManager` (385),
`CredentialCipher` (169), `CredentialEnvelope` (76), `AuthGateKey` (98),
`SecurityWipe` (**737**), `SecuritySettingsActivity` (1056). Spec:
`2026-07-22-security-hardening-design.md`. This is the largest single phase by
line count outside PGP, and `SecurityWipe` is where the difficulty is.

### The lockout curve

Attempts 1–2 free (typos happen). Attempt 3 onward adds a growing delay:
30s, 60s, 5m, 15m, 30m. Ten consecutive wrong attempts with no intervening
success wipes local data.

### PIN policy

Minimum length **8**, maximum 12 — not 6. Iteration count cannot defend a small
keyspace: both the verifier and the wrapping key are peppered with a
non-exportable Secure Enclave/Keychain value that forces brute force on-device,
but 10^6 is still minutes-to-an-hour of enclave calls where 10^8 is days.
Reject the run/repeat/keypad-walk/date families that dominate leaked-PIN
datasets — with only ten guesses available, those are a real risk, not a
theoretical one. Existing shorter PINs keep working; the floor applies at
set-and-change time only.

### The two rules that are load-bearing

1. **The wipe fails closed.** It reports each step it could not complete rather
   than claiming a clean erasure, and resumes at next launch. After three
   failed resumes it stops retrying but does **not** forget: the marker
   persists and every later launch blocks the whole app behind "manual recovery
   required" instead of presenting a first-run screen over data still on disk.
   Reinstalling is the recovery.
2. **A PIN that cannot be *checked* is not a wrong PIN.** If the enclave pepper
   backing the verifier is gone or unusable, that must be a distinct state and
   must **not** count toward the wipe threshold. On Android, folding the two
   together meant an OS-level Keystore invalidation made every correct PIN read
   as wrong and destroyed user data in response to an event the user neither
   caused nor could avoid. The Apple equivalent — a Keychain item invalidated by
   a passcode change or a restore-to-new-device — is at least as likely.

Note the interaction with Phase 7: a security wipe must destroy the enrollment
envelope, and if it cannot, the wipe reports itself incomplete.

Also carry over: our `AppLockStore.FlagState` already distinguishes
`unreadable` from `off` for exactly this class of reason. Extend that
discipline to the new fields rather than adding plain `Bool`s beside it.

---

## Sequencing

```
0 ──┬── 1 ── 2
    ├── 3
    ├── 4
    ├── 5
    ├── 6 ─────────────┐
    └── 7 ── 8 ── 9 ───┴── 10
    └── 11
```

- Phases 1–5 and 11 are independent of each other and of the PGP track.
- Phase 1 before Phase 2: delta merging on a guessed `bodyMode` is worse.
- Phase 6 before Phase 9: the reader renders signature verdicts.
- Phase 7 before Phase 8: enrollment needs no library, and having a real
  envelope to unseal is what makes the crypto core testable end to end.
- Phase 11 touches the wipe, which must know about Phase 7's envelope. If 11
  lands first, revisit it when 7 does.

Rough weight, largest first: **8+9+10** (the PGP core and its two consumers) >
**11** (PIN/lockout/wipe) > **2** (delta sync) > **7** (enrollment) > **5**
(contacts) > **6** (signature model) > **1** > **0** > **4** > **3**.

## Verification

Every phase ships with tests in `KyPost Tests/` under Swift Testing, run via
the shared plan:

```sh
xcodebuild test -scheme "KyPost" -destination 'platform=macOS'
```

`parallelizable: false` stays off on both test targets — see `AGENTS.md`.

The platform-free state machines (Phase 7's ceremony, Phase 9's reader, Phase
10's sender) exist in that shape *specifically* so their full exit tables are
plain unit tests with fakes. If a port of one of them ends up needing a host
app to test, the port went wrong.
