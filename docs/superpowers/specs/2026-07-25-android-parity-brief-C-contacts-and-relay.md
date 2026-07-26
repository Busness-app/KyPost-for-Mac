# Android parity brief C: contacts depth, relay outcomes, settings polish

Date: 2026-07-25
Status: Handoff brief — for a fresh session. Not a design; a scoping note.

## What this is

One of three buckets from a 2026-07-25 gap analysis between `kypost-android`
and `kypost-for-Mac`. Bucket B (PGP message state) has an approved design at
`2026-07-25-pgp-message-state-design.md`. Bucket A is
`2026-07-25-android-parity-brief-A-security-hardening.md`. This is C — the
grab-bag: medium-sized, mostly additive, lowest risk of the three.

Unlike A, there is **no existing spec**. Start with
`superpowers:brainstorming`, and consider splitting C further — the contacts
work and the relay/settings work share nothing.

## Read first

Android's design specs, which are the source of truth for intended behavior:

- `kypost-android/docs/superpowers/specs/2026-07-18-contact-fields-editor-design.md`
- `.../2026-07-18-contact-self-flag-design.md`
- `.../2026-07-19-contact-delete-confirmation-design.md`
- `.../2026-07-19-contact-sync-intro-popup-design.md`
- `.../2026-07-22-security-keyword-spacing-push-warning-design.md`

## C1. Contact groups

Android has a full group layer this app lacks: `data/GroupDao`, `GroupEntity`,
`GroupLinkDao`, `GroupLinkEntity`, plus `contacts/GroupsSyncClient`,
`GroupSyncModels`, `GroupSyncRepository`, and
`contacts/device/DeviceGroupLinker`.

This app has `Contact.groupIDs: [String]` (`Domain/Models/Contact.swift:93`)
and nothing that resolves those UUIDs to names — the comment says "app-only in
v1 (no CNGroup materialization)."

Scope note from Android's own client: `GET /api/groups` is **pull-only**, with
no delta cursor (always a full fetch), and two-way group *creation*
(`POST /api/groups`) is explicitly out of scope there. Don't design past that
without checking the server.

Decide separately whether macOS/iOS should materialize groups as `CNGroup` in
the system Contacts database. Android's `DeviceGroupLinker` does the equivalent;
this app's `SystemContactsExporter` currently does not, and that is a real
product decision, not an oversight to fix by reflex.

## C2. Pending contact change queue

Android has `data/PendingContactChangeDao` + `PendingContactChangeEntity` — a
durable offline queue for local edits awaiting push. This app relies on
`ContactEntity.needsSync` plus `ContactSyncReconciliation`.

Establish whether that is actually a gap before building anything. The flag may
be sufficient for this app's sync shape; Android's queue may exist for reasons
specific to its `WorkManager` scheduling. **This is the item most at risk of
being cargo-culted.**

## C3. Contact editor and list UX

Four separate Android features, each with its own spec above:

- **Fields editor** — `RepeatableFieldList`, `ExpandableSectionView`. This app
  has `LabeledListEditor`; compare rather than assume absence.
- **Self flag** — `dto.isSelf`, which gates the PGP-identity badge (see C4).
  Not present here at all.
- **Delete confirmation** — a confirm step before contact deletion.
- **Sync intro popup** — a first-run explainer before contact sync begins.

## C4. PGP identity badges (deferred out of bucket B)

Android's `pgp/PgpIdentityStatus.kt` (`hasPgpIdentity`) answers "does the paired
account have a PGP identity on the server." Its consumers are all contact
screens — `ContactsListActivity:126`, `ContactDetailActivity:103`,
`ContactEditActivity:423` — and every one is gated on `dto.isSelf`.

It therefore **depends on C3's self-flag** and was deferred out of bucket B for
that reason.

Worth reading `PgpIdentityStatus.kt`'s doc comment before designing: there is no
device-reachable "does this account have an identity" endpoint.
`GET /api/pgp/identity` is web-session-cookie only, so Android reuses the QR
token mint (`GET /api/pgp/qr/token`, reachable from a paired device) and reads
200-vs-400 as yes-vs-no. It returns **null, not false**, when the check can't be
made — callers must not render "no identity" for "couldn't ask."

Separately: the contact-side **fingerprint** hardening (`pgp/PgpFingerprint.kt`,
storing a locally computed fingerprint on the contact) is filed in **bucket A**,
not here, because it is a relay-trust issue. If C4 and A land in either order,
check they agree on where the fingerprint comes from.

## C5. Relay rate limiting

Android maps relay **429 + `Retry-After`** to `MailOutcome.RateLimited` — the
per-device lockout. Note it is mapped in `RelayMailSource.execute` /
`downloadAttachment` rather than in `mapErrorCode`, which cannot see response
headers.

Here, `NetworkError.rateLimited` exists (`HTTPClient.swift:20,33`) and is
handled for desktop pairing, but the mail layer has no `MailOutcome` case for
it — `MailOutcome.from` maps only `unauthorized` and `notPaired`, so a 429 falls
through to `.failure("rateLimited")` and the user gets a raw enum name with no
retry hint.

**Coordinate with bucket B**, which changes `NetworkError.conflict` to carry a
response body for the same reason (headers and bodies are discarded on non-2xx
in `HTTPClient.swift:142-144`). If B has landed, extend its mechanism rather
than adding a parallel one.

## C6. Settings spacing and the push metadata warning

Android's 2026-07-22 pass added dp-scaling and warning-callout helpers to
`AppTheme`, spaced out the Security and Keyword settings screens, and — the
substantive part — **warned users that push notifications relay metadata**
(sender, subject) through a third party.

The spacing is Android-specific layout work with no direct analogue here. The
warning is not: it is a factual disclosure about this app's push path, and this
app has the same path. Port the disclosure, skip the layout.

The Security settings screen it lives on does not exist here yet — it arrives
with **bucket A**. Either sequence C6 after A, or put the warning on the
existing push/notification settings surface.

## Suggested decomposition

C1+C2+C3+C4 (contacts) and C5+C6 (relay/settings) are independent. C5 is small
enough to fold into bucket B's session if B has not been implemented yet.
