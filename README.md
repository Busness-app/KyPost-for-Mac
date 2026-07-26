# KyPost

A native SwiftUI mail client for macOS and iOS that connects to a KyPost mail relay. 

The app talks only to the relay backend — there is no direct IMAP/SMTP. You pair a device once (QR code or deep link) and the relay handles mail access, server-side keyword tabs, push notifications, and contact sync.

> **Naming:** the app is branded **KyPost** throughout — Dock/Home Screen label, About screen, permission prompts, the Xcode project/scheme/folders, and the deep-link scheme (`kypost://`). Bundle IDs and the Keychain access group are deliberately unchanged (`com.urlxl.mail`, etc.) — renaming those is a separate, higher-stakes decision (see `Brand_Refresh_KyPost.md`).

## Features

- **Inbox with keyword tabs** — the relay categorizes mail into tabs/labels; tab visibility is configurable in settings.
- **Server folders** — Inbox (plus its subfolders), Drafts, Junk, Sent, Trash, and Archive with subfolders. On macOS these live in the sidebar; on iOS they're in the folder menu on the Inbox screen.
- **HTML email rendering** — themed WebKit reader on both platforms; links open in the default browser. Plain-text messages render natively.
- **macOS niceties** — three-pane split view, pop-out email windows (double-click or right-click a message), a toggleable preview pane, drag-and-drop of emails onto sidebar folders to move them, menu-bar commands (⌘N compose, ⌘R refresh, ⌘⇧S contact sync), and a native Preferences window (⌘,).
- **Compose & send** through the relay.
- **Push notifications** (APNs) for new mail and MFA challenges, with a pull-polling fallback (90 s foreground, background refresh on iOS).
- **MFA approval** — approve login challenges from a notification tap.
- **Contact sync** — two-way sync with the relay, with local-first edits and conflict-safe reconciliation. Contacts carry the full extended schema: groups, photo, IM/social handles, websites, relations, extra dates, phonetic names, department, custom fields, pronouns, and a PGP public key.
- **PGP key exchange via QR** — share your public key in person. *My QR Code* renders a short-lived (2 min) pickup link; *Scan to add contact key* reads someone else's, shows their fingerprint for out-of-band confirmation, and saves the key to a contact. iOS scans with the camera (paste as a fallback); macOS pastes the link (no VisionKit scanner).
- **Encryption state on every message** — messages the server decrypted say so, so you can tell it read your mail; messages your browser alone can open say that too, and link out to webmail. This app holds no PGP private key by design (see the server's `docs/E2E_PGP.md`).
- **Encrypted and signed send** — for accounts whose key the server holds, Encrypt/Sign travel with the message and the relay does the OpenPGP work. When a recipient has no usable key the relay refuses first and asks: confirming mails them a one-time link and stores that message's plaintext on your server for up to 7 days, named recipients and all. Accounts whose key only the browser can unwrap can't encrypt from here at all — the draft is saved server-side and webmail takes over.
- **15 themes** — palettes shared verbatim with the web and Android apps; default is **Patina Ky**.

## Requirements

- Xcode 26 (deployment target macOS/iOS 26.5)
- A running llama-labels backend (the live deployment is behind Cloudflare at `mail.urlxl.com`)
- For push: an APNs key configured on the backend

No external Swift package dependencies — persistence is SwiftData, networking is URLSession, rendering is WebKit.

## Getting started

1. Open `KyPost.xcodeproj` in Xcode.
2. Select the *KyPost* scheme and your destination (My Mac or an iOS device/simulator).
3. Build and run.
4. Pair the device: in the web frontend, open **Notifications → Pair Desktop App** (or scan the mobile pairing QR on iOS). The `kypost://native-pair?...` deep link registers the device and stores credentials in the Keychain.

Until a device is paired, the inbox shows a prompt directing you to Settings → Connection.

## Architecture

The target builds for both platforms from one codebase, laid out in `KyPost/`:

| Layer | Contents |
| --- | --- |
| `App/` | Entry point, scenes, app delegate, DI graph (`SingletonGraph`), polling scheduler, notification dispatcher |
| `Data/` | Relay clients (`RelayMailSource`, sync/push/registration clients), SwiftData DAOs and entities, Keychain and settings stores |
| `Domain/` | Models, repositories (mail, keywords, contacts, push), use cases (send, pairing, MFA) |
| `Presentation/` | Shared SwiftUI screens and view models, macOS-specific root/preferences views, style-guide components |
| `Style/` | Theme palettes and manager (binding contract with web `theme.ts` / Android `AppTheme.kt`) |

Platform split: iOS uses a tab layout (`MainTabView`); macOS uses `NavigationSplitView` (`MacRootView`) plus a per-email `WindowGroup` for pop-out readers.

### Wire contracts

The relay endpoints and payload shapes are defined by the Android reference repo (`llama-mobile`), primarily `Mobile_Mail_Relay.md` and `Mobile_Contact_Sync.md`:

- `GET /api/inbox` — emails grouped by tab (`{tabs, byTab, cursor, delta, removed}`)
- `GET /api/inbox/folders?parent=` — folder listing (full paths, e.g. `INBOX/Receipts`)
- `POST /api/inbox/actions` — bulk read/archive/spam/delete/move
- `POST /api/mail/send` — comma-joined recipient strings
- `POST /api/mail/draft` — save a draft (same body shape as send, no PGP flags)
- `GET /api/pgp/bootstrap` — this account's key custody (`hasIdentity`, `protection`)
- `POST /api/pgp/recipients/check` — contacts-only recipient key preflight (never `/resolve`)
- `GET/POST /api/contacts/sync` — cursor-based contact sync
- `GET /api/pgp/qr/token` — mint a 2-minute PGP key-pickup token/URL (pairing-auth `sub`/`hash`)
- `GET /api/pgp/qr/key?t=` — fetch a scanned public key + fingerprint (token is the credential)
- `POST /api/notifications/native/register` — APNs device registration

When touching any of these, check the Android implementation first rather than guessing.

## Testing

Unit tests use Swift Testing (`@Test`/`#expect`) and live in `KyPost Tests/`; UI test stubs are in `KyPost UITests/`. Run them in Xcode (⌘U) or:

```sh
xcodebuild test -project "KyPost.xcodeproj" -scheme "KyPost"
```

Network-facing tests run against a stubbed `HTTPClient` — no backend needed.

## Known gaps (v2 candidates)

- Attachments (compose and viewing)
- Mail cursor/delta sync — every refresh is a full folder snapshot
- Read/archive/delete actions from the reader (move-via-drag exists on macOS)
- Draft saving from compose — the PGP webmail handoff saves one server-side, but there's no Save Draft button and no auto-save
- Server-side search (search runs against the local cache)
- QR scanning via camera on macOS — pairing and PGP-key links must be pasted (camera scanning works on iOS)

## License

GPL-3.0 — see [LICENSE.txt](LICENSE.txt).
