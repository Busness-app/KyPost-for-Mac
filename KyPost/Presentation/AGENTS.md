# Presentation DOX

## Purpose

SwiftUI views, view models, and reusable components for macOS and iOS from one
target. Screens compose Components; view models hold state and talk to
Domain.

## Ownership

- `Screens/` — full surfaces (compose, inbox, contacts, PGP)
- `Components/` — reusable views with no screen-specific knowledge
- `Shared/ViewModels/` — `@Observable @MainActor` state, injected from `SingletonGraph`
- `macOS/` — macOS-only shells (`MacRootView`)

## Local Contracts

- **Sheets do not inherit `\.theme`.** Every `.sheet` re-injects
  `.environment(\.theme, theme)`. A sheet that skips it renders unthemed.
- **Fonts carry meaning**: `AppFont.ui` for names and prose, `AppFont.mono`
  for email addresses and other machine text. A bare address rendered in mono
  is the signal a recipient isn't in the address book.
- **Only four font weights ship.** Space Grotesk and IBM Plex Mono are bundled
  from `Resources/Fonts` in regular, medium, semibold, and bold only. Any other
  `AppFont` weight silently resolves to the nearest bundled face — add the TTF
  and list it in `UIAppFonts` before using one. The bundle is flat, so
  `ATSApplicationFontsPath` is `.` and `UIAppFonts` carries bare filenames.
- **New pure value types must be declared `nonisolated`.** The target defaults
  to MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`), which infers
  isolated conformances; SwiftData casts codable composites off the main actor
  and an isolated conformance fails that cast at runtime, not compile time.
  See `Domain/Models/Contact.swift`.
- **Contacts are searched in memory, not in the store.** `Contact.emails` is an
  encoded blob `#Predicate` cannot see into, so both compose autocomplete and
  the address book run `ContactSearch` over `ContactsViewModel.searchIndex`,
  rebuilt in `load()`. Do not add a second contact cache.
- **Compose recipients are `[RecipientToken]`; `ComposeDraft` stays strings.**
  `ComposeDraft` is a `WindowGroup` scene value, so its `Codable` shape is a
  serialization contract — decode every key with `decodeIfPresent` or an
  archive from an older build throws and the window restores blank. Tokens are
  live editing state and are deliberately not `Codable`.
- **Uncommitted recipient text lives on the view model**, not in view `@State`,
  so `send()` can flush it. Typing an address and pressing ⌘↩ must still mail
  it.
- **Floating overlays anchor from the top of the view tree.** Compose's
  dropdown uses `anchorPreference` + `.overlayPreferenceValue` at the content
  level. `.popover` steals key-window focus on macOS; `.overlay` on a field
  inside the header `Grid` draws under the AppKit-hosted `TextEditor`.
- **Rows in a focus-sensitive overlay must not be `Button`s.** A `Button`
  takes first responder, dropping the field's focus and tearing the overlay
  down before the action runs. Use `.contentShape` + `.onTapGesture`.
- **`.toast(message:)` is a pure renderer** — the caller owns dismissal.
  `ContactsViewModel.statusMessage` persists by design; compose expires its own
  toast on a timer. A toast bound to a window renders *behind* any sheet over
  it, so a sheet that raises toasts binds `.toast` itself.
- **`SecondaryButtonStyle` stretches to `maxWidth: .infinity`** (built for
  sheet footers). Constrain it with `.frame(width:)` inside an `HStack`.
- **Aligning columns across separate rows takes fixed widths**, not `Grid`:
  each `Grid` sizes its columns independently, so a header `Grid` drifts out
  of line with row `Grid`s. See `AddressBookView.Column`.
- PGP message state is decided in `Domain/Models/PgpMessageState.swift` and
  never re-derived in a view. `EmailListRow` marks only the two unreadable
  states (`lock.fill` / `exclamationmark.triangle.fill`); a server-decrypted
  row is deliberately unmarked. `EmailDetailView` shows the signature badge
  **only** for `.decryptedByServer` — for a client-protected message the
  server never saw the plaintext, so `pgpSigned`/`pgpVerified` are not a
  verdict about anything. The "Open in webmail" link goes through
  `@Environment(\.openURL)` and must never be routed into an in-app WebView
  (kypost-server `docs/E2E_PGP.md` requirement 5).
- Encrypted send is decided by key custody, not by hope.
  `Domain/Models/PgpKeyCustody.swift` maps `/api/pgp/bootstrap` to
  `serverHeld` / `clientHeld` / `noIdentity`, and anything unrecognised
  degrades to `clientHeld`. Compose shows Encrypt/Sign **only** for
  `serverHeld`; `clientHeld` gets the webmail handoff (save a draft, then
  `openURL` — same rule as the reader's webmail link, above, never an in-app
  WebView), and `.noIdentity` or a nil custody shows nothing at all.
- **The keyless-recipient confirmation copy is contract.** It lives in
  `ComposeViewModel.pickupConfirmationMessage`, verbatim from
  `Client_Encrypted_Send.md`, and must name every address, say the plaintext
  sits on the server for up to 7 days, and default to Cancel. Every pickup
  link this app can cause is the server-readable kind; softening the wording
  defeats the opt-in.
- **The pickup opt-in is per message and never remembered.** `encrypt`, `sign`
  and `allowPickupFallback` live on the view model and die with the window.
  Do not persist them to `ComposeDraft`, `UserDefaults`, or the keychain.
- **A keyless 409 re-send must reuse the refused `OutgoingEmail`**
  (`PendingPickup.email`), flipping only `allowPickupFallback`. Rebuilding from
  live compose state risks a subtly different message; re-running the preflight
  wastes a round trip on a question the 409 already answered.
- **The preflight is a lower bound.** `/api/pgp/recipients/check` searches only
  the user's contacts, while the send path also runs WKD and keyserver
  discovery. Word it "no key on file", never "this will be sent in the clear".
- **A relay `warning` on a 200 means the message was sent.** Show it as a
  notice, keep the window open, and leave Send disabled (`isSent`) — a retry
  duplicates the message. Never pattern-match the warning's wording.

## Work Guidance

- Reuse `ContactSearch` for any contact matching; don't hand-roll a filter.
  `localizedCaseInsensitiveContains` over every contact per keystroke routes
  through ICU collation — prefer the prebuilt folded index.
- Never map a range found in a folded string onto the original: folding isn't
  length-preserving ("ß"→"ss"), so indices misalign or trap. Fold to filter;
  match the original to highlight.
- Validate addresses with `EmailAddress.isValid` (HTML5 grammar, not RFC 5322).

## Platform deviations (compose recipients)

Recorded so they aren't re-litigated as bugs:

- **No arrow-key/Escape navigation on iOS.** `onKeyPress` needs a hardware
  keyboard; the soft keyboard has no arrows. iOS is tap-driven.
- **No backspace-deletes-last-token.** AppKit's field editor consumes
  backspace before `onKeyPress` sees it at any level of the focus chain, even
  with the field empty. The only workaround is a zero-width sentinel in the
  text, which corrupts paste. Tokens come off via their X button. Tab, Return,
  Escape and the arrows *do* arrive.
- **The dropdown highlights nothing by default.** Preselecting row 0 would
  make Return on a fully-typed address insert a different contact.

## Verification

- Unit: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
  (Swift Testing; `ContactSearchTests`, `ComposeRecipientTests`).
- Pass `debounceInterval: .zero` to `ComposeViewModel` in tests, and poll for
  the result rather than sleeping a fixed span — the search lands a scheduling
  hop later even at zero, so a fixed sleep goes flaky under load.
- Focus, key routing, overlay z-order, and `FlowLayout` wrapping are not
  unit-testable — drive the app (XCUITest against the `New Email` window
  reaches them) and look at the result.

## Child DOX Index

None.
