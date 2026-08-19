# KyPost Mobile Mail Relay — Backend Integration Guide

> **MIRRORED, NOT OWNED.** This file is a copy of `Mobile_Mail_Relay.md` from
> the KyPost server and Android repositories, kept here because this repo's
> `README.md` and `AGENTS.md` both name it as the source of truth for relay
> endpoints and payload shapes. **Do not edit it to describe Mac behaviour.**
> Fix the upstream copy and re-mirror; anything Mac-specific belongs in
> `AGENTS.md` or `Client_Encrypted_Send.md`.
>
> It is written from the Android app's point of view and says "the mobile app"
> throughout. Read that as "a paired client". Mirrored 2026-08-18.

This document describes how the (separate-repo) Llama Labels mobile app
should read and send mail through a self-hosted KyPost server. It
mirrors `iOS_Mobile_notify.md` and `Mobile_Contact_Sync.md`'s shape:
concrete request/response JSON, an error table, and a deployment checklist
— written so a fresh Claude session working in the mobile app's repo can
implement against it with no other context.

## Summary

The mobile app **never connects to IMAP/SMTP directly and never holds mail
credentials**. It calls the same backend REST endpoints the web frontend
already uses for reading, organizing, and sending mail — the backend holds
the account's encrypted IMAP/SMTP credentials and proxies every operation.
This mirrors the precedent already set by the web client (which also has
zero direct mail-server connectivity) and by contact sync
(`Mobile_Contact_Sync.md`), which extends the same "backend as relay, client
never touches the origin protocol" philosophy to mobile specifically.

Authentication reuses the existing native-push pairing mechanism — the same
credential contacts sync already reuses. There is no separate mobile login
and no app-specific mail password.

**The credential is per device, and it travels in headers.** Pairing
exchanges a one-time `pairingToken` for a `deviceId` and a `deviceSecret`
minted by the server; every request below carries them as
`X-Kypost-Device-Id` and `X-Kypost-Device-Secret`. The account-wide
`sub`/`hash` query-parameter scheme this document originally described is
**gone** — the server rejects it. Two reasons it had to go: an account-wide
HMAC cannot be revoked for one lost device, and credentials in a URL are
written to every access log and proxy along the way.

**Account setup is out of scope for mobile.** A user must configure their
IMAP/SMTP account once via the web UI (`/api/imap/config`) before mobile can
read or send anything. Mobile never views or sets raw host/username/password
— that endpoint stays cookie-only and mobile should never call it.

## Architecture Overview

```
Mobile App
  ├─ GET  /api/inbox?limit=&mailbox=          → unread mail, grouped by label
  ├─ GET  /api/inbox/folders?parent=           → list folders
  ├─ POST/PUT/DELETE /api/inbox/folders        → create/rename/delete folders
  ├─ POST /api/inbox/actions                   → read/archive/spam/delete/move
  ├─ POST /api/mail/draft                      → save a draft
  └─ POST /api/mail/send                       → send mail (SMTP) + save to Sent
        (all authenticate with the X-Kypost-Device-Id / X-Kypost-Device-Secret
         headers from pairing — no separate pairing step for mail)
```

All six endpoints are backed by the same per-user encrypted IMAP/SMTP
credential file and the same `imapadapter.Client` the web frontend already
uses (`backend/internal/adapters/imap/`) — there is exactly one mail account
per user, no separate "mobile" vs "web" state.

---

## Part 1: Prerequisite — Device Pairing (unchanged, reused as-is)

Exactly as in `Mobile_Contact_Sync.md` Part 1: if the app already implements
push pairing, reuse the stored `deviceId`/`deviceSecret` — there is nothing
new to build for pairing. The same pair authenticates native push pull,
contact sync, and now mail.

Each request below accepts **either**:
- A web session cookie (`llama_session`) — not applicable to mobile, listed
  for completeness since the same endpoints serve the web frontend.
- The pairing headers — the mobile path:

```
X-Kypost-Device-Id: <deviceId>
X-Kypost-Device-Secret: <deviceSecret>
```

Both values come from the registration response and are stored in a
Keystore-backed `EncryptedSharedPreferences` file. **Every successful
registration mints a new secret and invalidates the previous one**, so the
client must persist the returned value unconditionally. A `401` means the
secret is wrong or the device was revoked; re-pair rather than retrying.

Clients must not follow redirects on these requests. Custom headers are not
stripped by redirect-following the way `Authorization` is, so a compromised
or malicious server could `3xx` a request to an arbitrary host and be handed
the device secret.

---

## Part 2: Endpoint Contracts

### GET /api/inbox — unread mail

```
GET /api/inbox?limit=100&mailbox=INBOX
```

- `limit` — optional, default `500`, max `5000`. **Mobile should pass a
  small value** (e.g. `50`–`100`) — see "Known limitation" below.
- `mailbox` — optional; omit for the default inbox.

Response `200`:

```json
{
  "tabs": ["Work", "Personal", "Uncategorized"],
  "byTab": {
    "Work": [
      {
        "messageId": "<abc123@example.com>",
        "sender": "alice@example.com",
        "sentTo": "me@example.com",
        "cc": "",
        "bcc": "",
        "subject": "Project update",
        "body": "...",
        "label": "Work",
        "status": "unread",
        "atUtc": "2026-07-07T20:43:25Z"
      }
    ],
    "Personal": [],
    "Uncategorized": []
  }
}
```

If the account isn't configured yet (see Part 4), this returns `200` with
an empty tab scaffold rather than an error — the same graceful-degradation
behavior the web frontend relies on.

### GET/POST/PUT/DELETE /api/inbox/folders — folder management

```
GET    /api/inbox/folders?parent=<optional>
POST   /api/inbox/folders        { "parent": "", "name": "Travel" }
PUT    /api/inbox/folders        { "folder": "Travel", "name": "Trips" }
DELETE /api/inbox/folders?folder=Travel
```

`GET` response `200`:

```json
{ "parent": "", "folders": [{ "path": "Work", "deletable": true }] }
```

`POST`/`PUT`/`DELETE` all respond `200` with `{"ok": true, ...}` echoing the
affected folder. Built-in mailboxes (Inbox, Sent, Drafts, Trash, etc.) can't
be renamed or deleted — expect `400` if attempted.

### POST /api/inbox/actions — bulk read/archive/spam/delete/move

```json
{
  "action": "archive",
  "messageIds": ["<abc123@example.com>", "<def456@example.com>"],
  "mailbox": "INBOX",
  "targetMailbox": "Archive"
}
```

- `action` — one of `delete`, `archive`, `spam`, `read`, `move`.
- `targetMailbox` is required only for `action: "move"`.

Response `200`:

```json
{
  "ok": true,
  "action": "archive",
  "processed": 2,
  "failed": [],
  "targetMailbox": ""
}
```

`failed` lists any `messageId`s that errored individually (`{"messageId": "...", "error": "..."}`);
`ok` is `false` if `failed` is non-empty, but successfully processed IDs
still take effect — treat this as a partial-success response, not all-or-nothing.

### POST /api/mail/draft — save a draft

```json
{
  "to": "bob@example.com, carol@example.com",
  "cc": "",
  "bcc": "",
  "subject": "Draft subject",
  "body": "...",
  "mode": "plain"
}
```

- `to`/`cc`/`bcc` are **comma-separated strings**, not arrays.
- `mode` — `"plain"` (default), `"html"`, or `"markup"` (sent as
  `text/markdown`).
- `to` must contain at least one valid recipient or this returns `400`.

Response `200`: `{"ok": true}`.

### POST /api/mail/send — send mail

Same request body shape as draft. Sends via the account's configured SMTP
server, then best-effort saves a copy to Sent.

Response `200`:

```json
{ "ok": true, "sentSaved": true, "warning": "" }
```

If the send succeeds but saving to Sent fails, `sentSaved` is `false` and
`warning` explains why — the send itself still happened; don't treat this as
a failure to the user, just surface the warning.

### Attachments on send/draft (added 2026-07-11)

Both `/api/mail/send` and `/api/mail/draft` accept an optional
`attachments` array alongside the fields above:

```json
{
  "to": "bob@example.com",
  "subject": "Q3 report",
  "body": "See attached.",
  "mode": "plain",
  "attachments": [
    { "name": "report.pdf", "mimeType": "application/pdf", "dataBase64": "JVBERi0..." }
  ]
}
```

- `dataBase64` is standard base64 (RFC 4648, with padding).
- Total **decoded** attachment size is capped at 25 MB per message → `400`
  "attachments too large (max 25 MB total)". Invalid base64 → `400`
  "invalid attachment encoding".
- With attachments the server builds a `multipart/mixed` MIME message
  (text part first, then one base64 part per attachment); without them the
  message stays single-part, exactly as before.

### GET /api/mail/attachments — list a message's attachments (added 2026-07-11)

```
GET /api/mail/attachments?mailbox=INBOX&messageId=42
```

`messageId` is the same IMAP-UID id `/api/inbox` and `/api/inbox/actions`
use. Response `200`:

```json
{
  "ok": true,
  "attachments": [
    { "index": 0, "name": "report.pdf", "mimeType": "application/pdf", "size": 182044 }
  ]
}
```

Attachment metadata is **not** included in `/api/inbox` responses (the mail
cache stays attachment-free); fetch it lazily when a message is opened.

### GET /api/mail/attachment — download one attachment (added 2026-07-11)

```
GET /api/mail/attachment?mailbox=INBOX&messageId=42&index=0
```

Streams the raw bytes with `Content-Type`, `Content-Length`, and
`Content-Disposition: attachment; filename=...` headers. `404` if `index`
doesn't exist on the message; `400` for a missing/invalid `messageId` or
`index`; `502` when the IMAP fetch fails.

---

## Part 3: Error Handling

| Status | Cause | Notes |
|--------|-------|-------|
| `400` | Malformed JSON body, missing/invalid `to` recipient, missing `action`/`messageIds`, or an unsupported `action` value | Body validation failures — fix the request |
| `400` | Account not configured yet — exact body text differs per endpoint: `"imap configuration is required"` (folders, actions), `"imap configuration is required before saving drafts"` (draft), `"imap configuration is required before sending"` (send) | Direct the user to the web UI (see Part 4). Match on the `imap configuration is required` prefix rather than the full string. `GET /api/inbox` degrades to a `200` empty scaffold instead of erroring. |
| `401` | Pairing headers missing, or `X-Kypost-Device-Secret` doesn't match the stored secret for that device id | Re-pair the device (Part 1). A registration that succeeded elsewhere rotates the secret, so this also means "superseded" |
| `401` (unknown device) | `X-Kypost-Device-Id` doesn't map to any registered device — including one revoked from the server's Security page | Device paired against a server that lost or dropped that state; re-pair |
| `503` | Server has no `PAIRING_SECRET` configured | Mail relay (and native push, contact sync) are all unavailable until the self-hoster sets that env var. Only returned when the pairing headers were actually supplied — a plain unauthenticated request without them gets a normal `401`. |
| `502` | Upstream IMAP/SMTP failure (server unreachable, auth rejected by the mail provider, etc.) | Transient — safe to retry with backoff |
| `503` (folders/actions/draft only) | IMAP client not configured/available for another reason | Distinct from the `400` "not configured yet" case — this means configuration exists but the client couldn't be built |

---

## Part 4: Account Setup Is Web-Only

`/api/imap/config` and `/api/imap/test` are **cookie-only** — they are not
reachable with the pairing headers and mobile should never call them. If any mail
endpoint above returns `imap configuration is required`, the correct mobile
UX is a "set up your mail account on the web app first" empty state, not a
form to enter host/username/password in the mobile app itself. This is
deliberate: mail credentials are decrypted only inside the backend process
and are never returned to any client, including mobile.

---

## Part 5: Known Limitation — No Delta/Cursor Sync (v1)

Unlike contact sync (`Mobile_Contact_Sync.md`), `GET /api/inbox` has **no
`since` cursor** — it does a live IMAP fetch of up to `limit` unread
messages, full bodies included, on every call. This is fine for a browser
tab open once; it's not bandwidth/battery-optimal for a mobile app polling
repeatedly.

This is a deliberate v1 simplification, the same way contact sync deferred
push-triggered sync: designing a cursor-based delta mechanism for mail is a
separate, larger effort than wiring up mobile auth. For v1:

- Pass a small `limit` (50–100) rather than the default 500.
- Fetch on app foreground and pull-to-refresh rather than continuous
  background polling.
- Treat this endpoint as "the current unread snapshot," not an
  incrementally-syncable feed.

A future v2 could add a UID- or revision-based cursor (mirroring contacts'
`cursor`/`since` pattern) or lean on push-triggered pulls instead of
polling — **not implemented today**.

---

## Part 6: Deployment Checklist (mobile app repo)

- [ ] Reuse the existing pairing `deviceId`/`deviceSecret` storage (Part 1);
      no new pairing flow needed for mail. Send them as headers, never as
      query parameters, and disable redirect-following on these calls.
- [ ] Never implement an IMAP/SMTP client or store mail credentials
      on-device — every mail operation goes through the six endpoints above.
- [ ] Handle the "not configured yet" state (`400` with
      `imap configuration is required`) by directing the user to set up
      their account on the web app — do not attempt to collect host/
      username/password in the mobile app.
- [ ] Poll `GET /api/inbox` with a bounded `limit` (50–100), on foreground
      and pull-to-refresh only — there is no delta sync in v1 (Part 5).
- [ ] Treat `POST /api/inbox/actions`'s response as partial-success: check
      `failed[]` even when `ok` is `false`, since `processed` IDs still took
      effect.
- [ ] Remember `to`/`cc`/`bcc` are comma-separated strings in requests, not
      JSON arrays (differs from `/api/inbox`'s response shape, which uses
      flat strings too, but from contacts sync's array-of-objects shape).
- [ ] Surface `mail/send`'s `warning` field to the user as a non-blocking
      notice when `sentSaved` is `false` — the send already succeeded.
- [ ] Test against a freshly-paired device with no IMAP account configured
      yet: `GET /api/inbox` should return `200` with an empty tab scaffold;
      the other five endpoints should return `400`.

---

## Operational Notes

- **No mail credentials ever reach mobile.** `/api/imap/config`'s `GET`
  response (web-only) omits the password field even for the web client.
- **Auth reuses pairing, not a new secret.** Losing pairing state means
  re-pairing (Part 1) — there is no separate "mail token" to manage.
- **No delta sync in v1** (Part 5) — poll on foreground/pull-to-refresh with
  a bounded `limit`.

## Summary

Mail relay adds no new backend capability — it reuses the exact endpoints
the web frontend already calls (`/api/inbox`, `/api/inbox/folders`,
`/api/inbox/actions`, `/api/mail/draft`, `/api/mail/send`) and layers in
mobile's existing per-device pairing credential
(`X-Kypost-Device-Id` / `X-Kypost-Device-Secret`) as an alternate to the
session cookie. Account setup (`/api/imap/config`,
`/api/imap/test`) stays cookie-only and web-only by design, so mail
credentials never leave the backend process.
