
# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## Testing

- Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`.
- `KyPost.xctestplan` is the shared test plan, referenced from the
  shared scheme. Both test targets set `parallelizable: false`, and that must
  stay off.

  Swift Testing parallelizes test functions in-process by default. With it on,
  roughly one full-suite run in six aborts with SIGABRT: an uncaught
  Objective-C exception is thrown inside SwiftData/CoreData's
  `performBlockAndWait` and rethrown across the block boundary, killing the
  process. Whichever tests are in flight are then reported as failures, so the
  names change every run and are unrelated to the real fault — pure JSON and
  theme tests "fail" in 0.000s because they never ran. No single test is the
  trigger (skipping the prime suspect does not help), and the app itself is
  unaffected: it opens exactly one ModelContainer, where the suite opens dozens
  concurrently.

  Note `parallelizable` belongs on each entry in `testTargets`, not in
  `defaultOptions`, where it is silently ignored.

## Local Contracts

### The OpenPGP library (`Dependencies/GopenPGP`, `Domain/Security/PgpCrypto.swift`)

GopenPGP is consumed as a **binary XCFramework pinned by SHA-256** in
`Dependencies/GopenPGP/Package.swift`. SwiftPM refuses the download if the
bytes stop matching, which is the only property that makes an opaque binary in
a crypto path acceptable.

- The binary is built by `.github/workflows/gopenpgp-xcframework.yml` from
  ProtonMail/gopenpgp at the tag in `Dependencies/gopenpgp.env`, using
  **upstream's own `build.sh`** rather than a reimplemented `gomobile bind`.
  Reimplementing it got three things wrong that the script encodes; call the
  script.
- **The build is not bit-reproducible.** Two runs of the same pinned tag
  produced different hashes. gomobile embeds build IDs and paths and the job
  does not pin Xcode, so the checksum identifies one specific build. Do not
  write a verification procedure that assumes rebuilding reproduces the hash.
- **Verify a checksum against the asset, never against the release notes.**
  The first release's notes quoted a hash the asset did not have, because two
  workflow runs raced and one clobbered the other's upload. The workflow now
  serialises and refuses to overwrite an existing release, but the habit is
  what protects you: `shasum -a 256` the download, or read GitHub's own
  `digest` field.
- **Only `PgpCrypto.swift` and its conforming types may `import Gopenpgp`.**
  The v2→v3 API break is recent enough that a swap must touch one file. The
  reader, compose, and the signature binding must never learn which library is
  underneath.

### Reading client-protected mail (`Domain/UseCases/EncryptedMessageReader.swift`)

- **The decrypted body is never persisted.** Not to SwiftData, not to the
  cached body field. It is returned to the caller and lives for the life of the
  view showing it.
- **The exit table is eleven distinct cases, not one error string.** Each gets
  its own sentence and sometimes its own button. Two that are easy to get
  wrong: `cancelled` is not an error — the user dismissed a sheet they raised,
  so the screen simply goes back to offering Decrypt; and `noEncryptedContent`
  is *terminal*, so the UI must not offer Retry. `readOutcomeAllowsRetry` is
  the single place that decides this.
- **`signerKeys` arrive already narrowed to the resolved sender.** Do not
  re-narrow them, and never parse a `From` header to do it. Android shipped
  exactly that and a differential harness caught it disagreeing with the
  server's parser on 27 of 111 adversarial headers.
- **Render `resolvedSender`, never the raw `From`,** wherever a verdict is
  shown. The two are separable by an attacker, and a correct verdict displayed
  next to the wrong address is still a lie.
- A decrypt failure must **not** clear `EnrollmentSession`. One message failing
  says nothing about the held key, and clearing re-prompts for every later
  message.
- `EnrollmentSession` holds the key as bytes it can zero, and every session
  boundary must clear it: app lock, backgrounding, memory pressure, security
  wipe, unpair. Android's equivalent was missed by the wipe path, which then
  reported "Complete" with the private key still in the process heap.

### Signature attribution is entity-level (`Domain/Security/GopenPGPCrypto.swift`)

A signature is attributed to a bound key by **entity fingerprint**, never by
key id. This is not a style preference; the two live at different levels and
mixing them fails silently:

- `VerifyResult.SignedByKeyIdHex()` returns the signature packet's *issuer* id,
  which is the signing **subkey's** whenever a subkey signed.
- `KeyRing.GetHexKeyIDsJson()` returns `PrimaryKey.KeyId` per entity — no
  subkeys, and there is no API that lists them.

Match one against the other and every subkey-signed message resolves to
"unknown signer" — no error, no alarm, and in the safe direction, which is what
makes it survive review. `SignedByKey()` returns the entity, so its fingerprint
is comparable to what a bound public key reports about itself.

Two further rules that are only visible as things the code does **not** do:

- Never call `insecureDisableUnauthenticatedMessagesCheck`,
  `insecureAllowDecryptionWithSigningKeys`, `disableIntendedRecipients` or
  `disableVerifyTimeCheck`. Each is an opt-out, so integrity checking and
  signature strictness are what happen by leaving them alone. Adding one would
  read like a fix for a decryption failure.
- `maxDecompressedMessageSize` must stay set to `maxDecompressedPlaintextBytes`.
  The library enforces the cap *during* decompression; the default is not this
  app's cap, and without it an encrypted zip bomb is an OOM kill.

GopenPGP also verifies against the **decryption key** whether or not it was
offered, so self-sent mail reads as verified. Harmless — signing needs the
private half — but a test whose message is signed by the key that decrypts it
is not testing which keys are trusted.

### Device enrollment (`Domain/Security/DeviceEnvelope|EnrollmentVault|EnrollmentCeremony`)

- **Gated on Hostile Location Protection being off.** Enabling HLP destroys the
  envelope; turning HLP back off does not restore it, and must not — the user
  re-runs the ceremony deliberately. Checked at the start of the ceremony *and*
  again before storing, because the user can flip it mid-window.
- **A device with no passcode cannot enrol.** The envelope's protection *is*
  the lock screen. Report it, do not degrade.
- The device key allows the **device credential**, not biometry alone. Biometry-
  only invalidates on every enrollment change, costing an ordinary user a full
  re-ceremony — and enrolling a biometric already requires the passcode, so the
  attacker it would exclude already holds what the key accepts.
- Adopt an existing device key only if it still matches the spec. Presence
  alone means a key from an earlier build with weaker parameters is reused
  forever with no signal, silently breaking the migration the design plans for.
- The envelope AAD is **length-prefixed**, and the fingerprint is normalised
  and validated where the AAD is built — not by doc comment. Space-grouped hex
  reaching an AAD that strips whitespace produces an authentication failure the
  design reports as a substituted-key alarm.
- A failed open is **hostile or stale, never a retry**. A 404 on the envelope
  covers both "never sealed" and "expired" — one case, so a caller cannot split
  them.
- The enrollment code is derived from **this device's own key material**, never
  from anything the server returned, or the comparison compares the server
  against itself. 14 Crockford characters: the search is offline, so length is
  a work factor, not a per-attempt probability.
- The ceremony takes no platform types. That is what makes its whole exit table
  a plain unit test; if a port of it needs a host app to test, the port went
  wrong.

### PGP signature trust (`Domain/Models/PgpSignatureState.swift`)

- **There is no client-side `From` parser, and there must not be one.** Android
  deleted theirs after a differential harness over 111 adversarial headers found
  27 divergences from the server's parser — worst, the RFC 5322 comment
  `Bob (Eve <eve@evil>) <bob@x>`, where the server binds `bob@x` and the client
  bound `eve@evil`, letting any contact forge a verified badge for anyone.
  Three fix rounds each closed one construct and opened another. The server
  ships `signerKeys` already narrowed to the sender it resolved; consume that
  narrowing, never reproduce it.
- This app has two address parsers and **neither may reach a verdict**:
  `RelayMailSource.splitSender` fills display fields, and `EmailAddress.parse`
  builds outgoing recipients. Audited 2026-08-18; keep them apart.
- Six states, not verified/unverified. The line that matters is **identity**
  (`verifiedConfirmed` — confirmed out of band) versus **continuity**
  (`verifiedSeenBefore` — same key as last time). Most keys arrive by Autocrypt
  harvest, so a flat "verified" overclaims for nearly all of them. The wording
  is part of the contract.
- Ordering is load-bearing: a `conflict` outranks both a good key and an
  invalid signature for the same sender, because reporting the survivor as
  verified hides precisely the event worth reporting.
- `signerUnknown` is **not an accusation** and does not mark a row: an ordinary
  correspondent not yet in the address book, a rotated key, and a forgery are
  locally indistinguishable.
- Key-id extraction is injected. An unparseable bound key must only ever shrink
  the candidate set, never grant a pass, and subkey ids must match — a signing
  subkey's id differs from the primary's, so matching only the primary rejects
  every normally signed message.

### Phishing flag and message-body navigation

- `$Phishing` is the reserved RFC 8621 keyword the server sets on mail
  impersonating KyPost. Matched case-insensitively and trimmed, because IMAP
  keywords are case-insensitive and a server may echo back `$phishing` for a
  keyword set as `$Phishing`. Exact match — `$PhishingReport` is a different
  keyword. The message is flagged **in place**: nothing moves or hides mail.
- The relay's `keywords` array must stay decoded and **unioned** with the
  tab-derived label, never replacing it. The label drives the tab strip; the
  wire list carries protocol keywords. Dropping either loses something.
- `$`-prefixed keywords are IMAP protocol flags, not user labels: they are
  filtered out of the tab strip, the row chips, and the Keywords settings
  screen. The phishing warning must not be hideable. (Divergence from Android,
  whose `KeywordTabs.buildTabs` does not filter them.)
- **The message body reaches only http/https.** An allowlist, not a denylist.
  Handing a link tap to `openURL` hands it to the system, and the system routes
  this app's own scheme back into this app — so a `kypost://native-pair` link
  in a message would raise the pairing confirmation on top of the sender's
  pretext. A mail body has no business opening `file:`, `tel:` or any other
  scheme either, and a denylist needs updating every time one appears.
- Un-gestured navigations stay blocked regardless of scheme: a
  `<meta http-equiv="refresh">` is plain HTML and a main-frame navigation, so
  neither the JavaScript switch nor `loadsSubresources` touches it.

### Mail delta sync (`Data/Mail`, `Data/Storage/MailCursorStore.swift`)

- **`isFullWindow` is derived from what we asked for, never from the wire's
  `delta` flag.** A relay predating the matching server fix labels a `since=0`
  response `delta: true` all the same, and only a full window can say what is
  *absent*.
- **Only a full window may prune.** A partial delta describes what changed;
  everything it omits is still legitimately in the mailbox. Pruning against one
  deletes the folder.
- **An "updated" row carries no body.** Merge into the existing row and keep
  the cached body; a blank incoming `bodyMode` never overwrites a known one. If
  there is no existing row, **skip it** — storing it creates a row whose empty
  body is indistinguishable from a client-protected message, and the reader
  then claims end-to-end encryption for mail the server decrypted. A
  metadata-only delta is not a delivery.
- **Advance the cursor only after the rows are committed.** A crash between
  the two costs a refetch; the other order loses messages permanently.
- Cursors are opaque server strings — never assume numeric or ordered. Scoped
  per pairing *and* folder, with the resync stamp on its **own** scope key:
  sharing one lets writing the stamp re-authorise a stale cursor for a new
  pairing.
- Folder names are unvalidated server strings, so cursor keys hash them. That
  stops a crafted name colliding with another folder's key, and keeps the
  user's folder taxonomy out of a plaintext defaults file. Under Hostile
  Location Protection the store is memory-only for the same reason.
- **A push tap forces a full resync before opening its target.** The cached row
  is fine for the list; rendering the detail screen from it can show a stale
  `bodyMode` or stale PGP state.

### Relay error mapping (`Data/Mail/MailSource.swift`)

- `NetworkError.from` sees a status code and a body, never headers. Anything
  header-derived — currently `Retry-After` — is parsed at the call site holding
  the `HTTPURLResponse` and passed in. Android hit the same wall and resolved
  it the same way; do not try to read headers inside the mapper.
- A `Retry-After` that is not delta-seconds reads as **absent, never zero**.
  "Retry immediately" is the one answer a malformed header must not produce.
- 400 carries its body as `.badRequest(body:)`, because the relay answers
  plain text there and the body is the only discriminator — unlike the two
  409s, which are told apart by JSON field. Deciding what that text *means*
  belongs in `RelayMailSource`, not `HTTPClient`.
- An unconfigured account (400 "imap configuration is required…") is its own
  outcome. Never build UI for the server's web-only mail configuration
  endpoints: an unconfigured relay is an empty state pointing at the web app,
  not a form.
- 502 is `.upstreamFailure` and retryable with backoff; other 5xx are not.
  Telling the user to retry is only honest for the one that is.

### MFA number matching (`Domain/Models/MfaNumberMatch.swift`)

- **Every value comes from the server.** Never invent decoys. This client used
  to fill a short set from an LCG seeded on the challenge id, which made the
  wrong answers derivable by anyone holding the id and therefore the right one
  derivable by elimination — the entire guarantee of number matching, given
  away. A challenge that does not carry the correct value and exactly
  `choiceCount - 1` decoys of the same width is one this client cannot offer an
  approval for: `options` returns nil and the screen leaves only Deny. There is
  no plain-Approve fallback, and adding one re-opens the MFA-fatigue tap that
  number matching exists to close.
- **Digit width is whatever the server sent**, validated against
  `MfaChallenge.matchDigitsLengthRange`, never an exact literal. The width was
  pinned to 2 in three places across two repositories with no negotiation, so
  widening the server's value space would have silently disabled approval on
  every deployed client.
- **Order is shuffled once per challenge and held.** Do not re-derive it on a
  redraw, and do not sort by a hash of `(challengeId, value)`: that hash
  expands to `H(challengeId) * 31^n + f(value)`, and with equal-width
  candidates the challenge-id term cancels out of every comparison, leaving a
  plain numeric sort that put the answer in the same slot on every challenge.

### Contact groups

- `GET /api/groups` is **pull-only and cursorless**. Every pull is the whole
  truth, so a group absent from the response is deleted locally. This device
  never creates a backend group (Client_Contact_Update.md Part 2 point 3), so
  there is no outbox and nothing to reconcile.
- `CNGroup` materialization is **one direction: backend → device**. A group the
  user made in Contacts is never turned into a backend group — there is no
  endpoint for it.
- Same adoption discipline as cards: an existing link wins, then a group the
  user already has *by name* is adopted rather than duplicated, then a new one
  is created. **An adopted group is never renamed and never deleted** — we did
  not author it.
- Membership removals are scoped to groups this app links. A card the user also
  put in their own group stays in it.
- An unknown group id resolves to no name and is skipped, never rendered as a
  raw UUID and never given an invented name — it only means the cache is
  behind.

### Contact identity (`Data/Contacts/`)

- `SystemContactMapper.matchKeys(for:)` has two overloads — one for `Contact`,
  one for `CNContact` — and **they must stay symmetric**. Each side offers one
  key per email, else the name+phone fallback. When the app side offered only
  `emails.first`, a person whose card carried only their *second* address
  matched on neither side: the export wrote a duplicate card, and the import
  read the original card as a stranger and wrote a duplicate contact — queued
  for the relay, so the duplicate reached the server and every other device.
  A new field that participates in identity goes into both overloads or
  neither.
- `ContactDAO.repairImportedDuplicates` groups by connected components over
  shared keys, not by one key per row. Grouping on a single key cannot see the
  duplicates above, because a non-primary-email match is exactly the case where
  the two rows' primary keys differ.
- `Contact.primaryEmail` / `primaryPhone` are `emails.first` / `phones.first`.
  Anything that treats email order as meaningful is suspect; prefer the
  `matchKeys` set.

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

## Child DOX Index

- `KyPost/App/AGENTS.md` — the dependency graph and its rebuild rule
  (`AppEnvironment` / `SingletonGraph.shared` aliasing), lifecycle/lock
  ordering at launch.
- `KyPost/Presentation/AGENTS.md` — SwiftUI views, view models, and
  components: theming and font contracts, MainActor isolation rules, compose
  recipient tokens and contact search, and the macOS/iOS input deviations.

