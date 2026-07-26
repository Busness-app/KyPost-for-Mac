# PGP Message State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS/iOS app tell the truth about every message's OpenPGP state instead of rendering client-protected mail as a blank email and server-decrypted mail silently.

**Architecture:** One new pure-function module (`Domain/Models/PgpMessageState.swift`) owns every decision; views only pick presentation from it. Five relay fields flow DTO → domain → SwiftData entity. `NetworkError.conflict` starts carrying its response body so the relay's 409 `clientSideNeeded` can be told apart from any other conflict.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), no external packages.

**Design spec:** `docs/superpowers/specs/2026-07-25-pgp-message-state-design.md`
**Upstream contract:** `kypost-server/docs/E2E_PGP.md` §"What mobile apps must implement"

## Global Constraints

- **No on-device PGP crypto, ever.** This app holds no private key and gains none. Settled in `kypost-server/docs/E2E_PGP.md`; do not add decryption, signing, or key unwrapping.
- **No new external dependencies.** This repo has zero Swift package dependencies. Keep it that way.
- **The webmail link must never open in an in-app WebView.** Use `@Environment(\.openURL)`. `EmailBodyWebView` is an in-app WebView and must not be used for it. Do not use `NSWorkspace` — it is macOS-only.
- **User-facing copy is ported verbatim** from `kypost-android/app/src/main/res/values/strings.xml`. Exact strings are given in each task. Do not paraphrase, reword, or "improve" them.
- **No SwiftData schema version bump.** New `EmailEntity` properties get defaults and stay inside `AppSchemaV2`, following the existing `sentTo`/`cc` precedent. Do not add an `AppSchemaV3`.
- **`KyPost.xctestplan` keeps `parallelizable: false`** on both test targets. Never change it — see root `AGENTS.md` for the SIGABRT it prevents.
- Test command, from root `AGENTS.md`:
  ```sh
  xcodebuild test -scheme "KyPost" -destination 'platform=macOS'
  ```

## File Structure

| File | Responsibility |
|---|---|
| `KyPost/Domain/Models/PgpMessageState.swift` (new) | Every PGP decision as pure functions. No SwiftUI, no networking. |
| `KyPost Tests/PgpMessageStateTests.swift` (new) | Truth tables for the above. |
| `KyPost/Data/Mail/RelayMailSource.swift` | `RelayEmailDTO` gains 5 fields; `send` maps the 409. |
| `KyPost/Domain/Models/Email.swift` | Domain model gains 5 fields. |
| `KyPost/Data/Database/EmailEntity.swift` | Persistence gains 5 fields + mapping both ways. |
| `KyPost/Data/Networking/HTTPClient.swift` | `NetworkError.conflict` carries its body. |
| `KyPost/Data/Mail/MailSource.swift` | `MailSourceError` and `MailOutcome` gain `clientSideNeeded`. |
| `KyPost/Presentation/Components/EmailListRow.swift` | Row marker. |
| `KyPost/Presentation/Screens/EmailDetailView.swift` | Badges, banner, body suppression. |

Tasks 1–3 are pure logic and fully unit-tested. Tasks 4–5 are SwiftUI; this repo has no snapshot or UI-assertion harness, so they are verified by a clean build plus the already-tested functions they call. That is stated honestly rather than papered over with fake test steps.

---

### Task 1: The pure rule module

**Files:**
- Create: `KyPost/Domain/Models/PgpMessageState.swift`
- Test: `KyPost Tests/PgpMessageStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum PgpMessageState: Equatable, Sendable` with cases `none`, `clientProtected`, `decryptFailed`, `decryptedByServer`
  - `func pgpMessageState(pgpEncrypted: Bool, pgpDecryptError: String, body: String?) -> PgpMessageState`
  - `func pgpRowSymbol(_ state: PgpMessageState) -> String?`
  - `func pgpRowAccessibilityLabel(state: PgpMessageState, subject: String) -> String?`
  - `func showsSignaturePill(state: PgpMessageState, signed: Bool) -> Bool`
  - `func webmailMessageURL(serverUrl: String, mailbox: String, messageId: String) -> URL?`

- [ ] **Step 1: Write the failing tests**

Create `KyPost Tests/PgpMessageStateTests.swift`:

```swift
//
//  PgpMessageStateTests.swift
//  KyPost Tests
//
//  Truth tables for the PGP state rule, row markers, signature-pill
//  visibility, and the webmail deep link.
//

import Foundation
import Testing
@testable import KyPost

@Suite struct PgpMessageStateRuleTests {
    @Test func plainMessageIsNone() {
        #expect(pgpMessageState(pgpEncrypted: false, pgpDecryptError: "", body: "Hello") == .none)
    }

    @Test func notEncryptedWinsEvenWithAnError() {
        // Guards against reordering the guard clause: an error on a
        // non-encrypted message is not a PGP state.
        #expect(pgpMessageState(pgpEncrypted: false, pgpDecryptError: "boom", body: nil) == .none)
    }

    @Test func encryptedWithNoBodyAndNoErrorIsClientProtected() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: nil) == .clientProtected)
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: "") == .clientProtected)
    }

    @Test func encryptedWithErrorIsDecryptFailed() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "no key", body: nil) == .decryptFailed)
    }

    @Test func errorIsCheckedBeforeBody() {
        // The ordering is load-bearing. The server populates the error and
        // leaves the body empty; if a body is somehow present too, the error
        // still wins. Reading this as decryptedByServer would render content
        // while an unreported failure sits beside it.
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "bad mac", body: "partial") == .decryptFailed)
    }

    @Test func encryptedWithBodyIsDecryptedByServer() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: "Secret") == .decryptedByServer)
    }

    @Test func whitespaceOnlyErrorAndBodyCountAsBlank() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "   ", body: " \n ") == .clientProtected)
    }
}

@Suite struct PgpRowMarkerTests {
    @Test func onlyUnreadableStatesAreMarked() {
        #expect(pgpRowSymbol(.clientProtected) == "lock.fill")
        #expect(pgpRowSymbol(.decryptFailed) == "exclamationmark.triangle.fill")
        #expect(pgpRowSymbol(.none) == nil)
        // Deliberately unmarked: the row opens and reads normally, so in a
        // server-mode mailbox this would decorate nearly every row with
        // nothing the user can act on.
        #expect(pgpRowSymbol(.decryptedByServer) == nil)
    }

    @Test func accessibilityLabelsSpellOutTheState() {
        #expect(pgpRowAccessibilityLabel(state: .clientProtected, subject: "Invoice")
            == "Encrypted, can't be read in this app: Invoice")
        #expect(pgpRowAccessibilityLabel(state: .decryptFailed, subject: "Invoice")
            == "Encrypted, couldn't be decrypted: Invoice")
        #expect(pgpRowAccessibilityLabel(state: .none, subject: "Invoice") == nil)
        #expect(pgpRowAccessibilityLabel(state: .decryptedByServer, subject: "Invoice") == nil)
    }
}

@Suite struct PgpSignaturePillTests {
    @Test func shownOnlyWhenTheServerActuallyVerifiedPlaintext() {
        #expect(showsSignaturePill(state: .decryptedByServer, signed: true))
    }

    @Test func hiddenForClientProtectedEvenWhenServerClaimsSigned() {
        // THE rule most likely to be "fixed" by a later well-meaning edit.
        // For a client-protected message the server never saw the plaintext,
        // so pgpSigned/pgpVerified are not a verdict about content anyone
        // verified. Rendering "signature not verified" here would assert
        // something we have no basis for. See the design spec §1.
        #expect(showsSignaturePill(state: .clientProtected, signed: true) == false)
    }

    @Test func hiddenWhenDecryptFailed() {
        #expect(showsSignaturePill(state: .decryptFailed, signed: true) == false)
    }

    @Test func hiddenWhenNotSigned() {
        #expect(showsSignaturePill(state: .decryptedByServer, signed: false) == false)
        #expect(showsSignaturePill(state: .none, signed: false) == false)
    }
}

@Suite struct WebmailMessageURLTests {
    @Test func inboxOmitsTheMailboxParam() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "INBOX",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func inboxMatchIsCaseInsensitive() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "inbox",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func blankMailboxOmitsTheParam() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func nonInboxMailboxIsIncluded() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "Junk",
            messageId: "7"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?mailbox=Junk&message=7")
    }

    @Test func subfolderPathIsPercentEncoded() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "Archive/Receipts",
            messageId: "7"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?mailbox=Archive/Receipts&message=7")
    }

    @Test func trailingSlashOnServerUrlIsNormalized() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com/",
            mailbox: "INBOX",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func blankMessageIdIsRejected() {
        #expect(webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: "") == nil)
    }

    @Test func unusableServerUrlIsRejected() {
        // Callers render "no button" rather than a dead one.
        #expect(webmailMessageURL(serverUrl: "", mailbox: "INBOX", messageId: "42") == nil)
        #expect(webmailMessageURL(serverUrl: "not a url", mailbox: "INBOX", messageId: "42") == nil)
    }
}
```

- [ ] **Step 2: Add the test file to the test target and run it to verify it fails**

Add `KyPost Tests/PgpMessageStateTests.swift` to the *KyPost Tests* target in Xcode (or let the file-system-synchronized group pick it up).

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:"KyPost Tests/PgpMessageStateRuleTests"`
Expected: FAIL — `cannot find 'pgpMessageState' in scope`.

- [ ] **Step 3: Write the implementation**

Create `KyPost/Domain/Models/PgpMessageState.swift`:

```swift
//
//  PgpMessageState.swift
//  KyPost
//
//  What this app can actually do with a message's OpenPGP content.
//
//  Pure functions of the relay's pgp* fields, so the decisions are testable
//  without SwiftUI or a stubbed network and no view re-derives them. Ported
//  from kypost-android's pgp/PgpMessageState.kt and pgp/WebmailDeepLink.kt.
//
//  This app holds no PGP private key and will not gain one — see
//  kypost-server/docs/E2E_PGP.md. Mobile and desktop-native clients implement
//  the degradation, never the crypto.
//

import Foundation

enum PgpMessageState: Equatable, Sendable {
    /// No OpenPGP content: render normally.
    case none

    /// Encrypted, and the server deliberately did not decrypt it because the
    /// account's key is end-to-end protected. There is no body and this app
    /// holds no private key, so the only route to the content is webmail.
    case clientProtected

    /// Encrypted, and the server tried to decrypt and failed. There is a real
    /// error to show.
    case decryptFailed

    /// Encrypted, and the server decrypted it for us. Worth surfacing rather
    /// than rendering silently: the user should be able to tell that the
    /// server read their mail.
    case decryptedByServer
}

/// The ordering matters. A non-blank `pgpDecryptError` is checked before the
/// body, because the server populates the error and leaves the body empty —
/// reading that as `.clientProtected` would tell the user to go to webmail for
/// a message that will fail there too, for a reason we were already told.
func pgpMessageState(
    pgpEncrypted: Bool,
    pgpDecryptError: String,
    body: String?
) -> PgpMessageState {
    guard pgpEncrypted else { return .none }
    if !pgpDecryptError.isBlank { return .decryptFailed }
    if let body, !body.isBlank { return .decryptedByServer }
    return .clientProtected
}

/// SF Symbol for an inbox row, or nil for no marker.
///
/// Only the two states that yield no readable content are marked.
/// `.decryptedByServer` is deliberately unmarked: the row opens and reads
/// normally, so a marker there would sit on most rows of a server-mode mailbox
/// carrying nothing the user can act on — and the detail view already discloses
/// that the server decrypted it.
func pgpRowSymbol(_ state: PgpMessageState) -> String? {
    switch state {
    case .clientProtected: "lock.fill"
    case .decryptFailed: "exclamationmark.triangle.fill"
    case .none, .decryptedByServer: nil
    }
}

/// Spelled-out row label for VoiceOver, or nil when the row carries no marker.
func pgpRowAccessibilityLabel(state: PgpMessageState, subject: String) -> String? {
    switch state {
    case .clientProtected: "Encrypted, can't be read in this app: \(subject)"
    case .decryptFailed: "Encrypted, couldn't be decrypted: \(subject)"
    case .none, .decryptedByServer: nil
    }
}

/// Whether to show a signature verdict at all.
///
/// True only for `.decryptedByServer`. For a client-protected message the
/// server never saw the plaintext, so its `pgpSigned`/`pgpVerified` values are
/// not a verdict about content anyone verified — showing "signature not
/// verified" would assert something we have no basis for. The web client can
/// fall back to a local decrypt for this (frontend ReadPage.tsx); this app
/// cannot, and never will.
func showsSignaturePill(state: PgpMessageState, signed: Bool) -> Bool {
    state == .decryptedByServer && signed
}

/// Builds the webmail URL that opens one specific message — the same `/read`
/// route a web push click uses, so no server change backs it.
///
/// INBOX is sent as an absent `mailbox` param rather than the literal string,
/// matching the links the web app builds for itself. Returns nil when
/// `serverUrl` isn't a usable absolute URL, which callers render as "no button"
/// rather than a dead one.
func webmailMessageURL(serverUrl: String, mailbox: String, messageId: String) -> URL? {
    guard !messageId.isBlank else { return nil }
    let trimmed = serverUrl.trimmingCharacters(in: .whitespaces)
    let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    guard var components = URLComponents(string: base),
          components.scheme != nil,
          components.host != nil
    else { return nil }

    components.path += "/read"

    var items: [URLQueryItem] = []
    let mailbox = mailbox.trimmingCharacters(in: .whitespaces)
    if !mailbox.isEmpty, mailbox.caseInsensitiveCompare(StandardFolder.inbox) != .orderedSame {
        items.append(URLQueryItem(name: "mailbox", value: mailbox))
    }
    items.append(URLQueryItem(name: "message", value: messageId))
    components.queryItems = items

    return components.url
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS — all four new suites green, existing suites unchanged.

If `subfolderPathIsPercentEncoded` fails on the `/` in `Archive/Receipts`, `URLComponents` has percent-encoded it to `%2F`. That is also a correct URL; update the expectation to match what `URLComponents` produces rather than hand-rolling the query string.

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Domain/Models/PgpMessageState.swift" "KyPost Tests/PgpMessageStateTests.swift"
git commit -m "pgp: add pure message-state rule, row markers, and webmail link"
```

---

### Task 2: Carry the five relay fields through DTO, domain, and persistence

**Files:**
- Modify: `KyPost/Data/Mail/RelayMailSource.swift:43-77` (`RelayEmailDTO` and `toDomain`)
- Modify: `KyPost/Domain/Models/Email.swift:10-29`
- Modify: `KyPost/Data/Database/EmailEntity.swift` (whole file — properties, `init`, both mappers)
- Test: `KyPost Tests/MailTests.swift` (append a suite)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Email.pgpEncrypted: Bool`, `Email.pgpSigned: Bool`, `Email.pgpVerified: Bool`, `Email.pgpSignerFingerprint: String`, `Email.pgpDecryptError: String` — all defaulted, all readable from `EmailEntity.toDomain`. Tasks 4 and 5 read these.

All five are added even though `pgpSignerFingerprint` renders nowhere yet: a second migration later is strictly worse than one now.

- [ ] **Step 1: Write the failing test**

Append to `KyPost Tests/MailTests.swift`:

```swift
// MARK: - PGP field wire contract

@Suite struct RelayEmailPgpFieldTests {
    /// The server marks all five pgp* fields omitempty, so absent means "no
    /// OpenPGP content" — the decoded defaults ARE the contract, not an
    /// unknown state.
    @Test func absentPgpFieldsDecodeToFalseAndEmpty() throws {
        let json = """
        {"messageId":"1","sender":"a@x.com","subject":"Hi","body":"Hello"}
        """
        let dto = try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
        let email = dto.toDomain(folder: "INBOX", tab: "")

        #expect(email.pgpEncrypted == false)
        #expect(email.pgpSigned == false)
        #expect(email.pgpVerified == false)
        #expect(email.pgpSignerFingerprint == "")
        #expect(email.pgpDecryptError == "")
    }

    @Test func presentPgpFieldsAreCarriedIntoTheDomainModel() throws {
        let json = """
        {"messageId":"2","subject":"Secret","body":"",
         "pgpEncrypted":true,"pgpSigned":true,"pgpVerified":false,
         "pgpSignerFingerprint":"ABCD1234","pgpDecryptError":"no key"}
        """
        let dto = try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
        let email = dto.toDomain(folder: "INBOX", tab: "")

        #expect(email.pgpEncrypted)
        #expect(email.pgpSigned)
        #expect(email.pgpVerified == false)
        #expect(email.pgpSignerFingerprint == "ABCD1234")
        #expect(email.pgpDecryptError == "no key")
    }

    @Test func pgpFieldsSurviveTheRoundTripThroughPersistence() {
        let email = Email(
            serverId: "3",
            folder: "INBOX",
            senderName: "S",
            senderEmail: "s@example.com",
            subject: "Subject",
            body: "",
            keywords: [],
            receivedAt: Date(),
            read: false,
            starred: false,
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true,
            pgpSignerFingerprint: "FEED",
            pgpDecryptError: ""
        )
        let restored = EmailEntity(from: email).toDomain

        #expect(restored.pgpEncrypted)
        #expect(restored.pgpSigned)
        #expect(restored.pgpVerified)
        #expect(restored.pgpSignerFingerprint == "FEED")
        #expect(restored.pgpDecryptError == "")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:"KyPost Tests/RelayEmailPgpFieldTests"`
Expected: FAIL — `value of type 'Email' has no member 'pgpEncrypted'`.

- [ ] **Step 3: Add the fields to `RelayEmailDTO`**

In `KyPost/Data/Mail/RelayMailSource.swift`, after the `changeType` property (line 59):

```swift
    /// OpenPGP state, all omitempty server-side — absent means "no OpenPGP
    /// content", so these defaults are the contract, not an unknown state.
    /// See kypost-server/docs/E2E_PGP.md.
    var pgpEncrypted: Bool?
    var pgpSigned: Bool?
    var pgpVerified: Bool?
    var pgpSignerFingerprint: String?
    var pgpDecryptError: String?
```

And in `toDomain`, add these arguments to the `Email(...)` call after `starred: false`:

```swift
            pgpEncrypted: pgpEncrypted ?? false,
            pgpSigned: pgpSigned ?? false,
            pgpVerified: pgpVerified ?? false,
            pgpSignerFingerprint: pgpSignerFingerprint ?? "",
            pgpDecryptError: pgpDecryptError ?? ""
```

- [ ] **Step 4: Add the fields to `Email`**

In `KyPost/Domain/Models/Email.swift`, after `var starred: Bool` (line 26):

```swift
    /// Relay OpenPGP state. Defaults are the wire contract for a message with
    /// no OpenPGP content — see PgpMessageState.swift for what they mean
    /// together.
    var pgpEncrypted: Bool = false
    var pgpSigned: Bool = false
    var pgpVerified: Bool = false
    /// Stored but not rendered — displaying it usefully means comparing it
    /// against a contact's saved key, which belongs with the contacts work.
    var pgpSignerFingerprint: String = ""
    var pgpDecryptError: String = ""
```

Defaulted properties keep the memberwise initializer source-compatible, so no existing `Email(...)` call site changes.

- [ ] **Step 5: Add the fields to `EmailEntity`**

In `KyPost/Data/Database/EmailEntity.swift`, add after `var starred: Bool`:

```swift
    /// Relay OpenPGP state; defaults keep stores created before these columns
    /// migrating cleanly (same lightweight pattern as sentTo/cc above).
    var pgpEncrypted: Bool = false
    var pgpSigned: Bool = false
    var pgpVerified: Bool = false
    var pgpSignerFingerprint: String = ""
    var pgpDecryptError: String = ""
```

Add to the initializer's parameter list, after `starred: Bool`:

```swift
        pgpEncrypted: Bool = false,
        pgpSigned: Bool = false,
        pgpVerified: Bool = false,
        pgpSignerFingerprint: String = "",
        pgpDecryptError: String = "",
```

and to its body, after `self.starred = starred`:

```swift
        self.pgpEncrypted = pgpEncrypted
        self.pgpSigned = pgpSigned
        self.pgpVerified = pgpVerified
        self.pgpSignerFingerprint = pgpSignerFingerprint
        self.pgpDecryptError = pgpDecryptError
```

In `convenience init(from email: Email)`, after `starred: email.starred`:

```swift
            pgpEncrypted: email.pgpEncrypted,
            pgpSigned: email.pgpSigned,
            pgpVerified: email.pgpVerified,
            pgpSignerFingerprint: email.pgpSignerFingerprint,
            pgpDecryptError: email.pgpDecryptError
```

In `var toDomain: Email`, after `starred: starred`:

```swift
            pgpEncrypted: pgpEncrypted,
            pgpSigned: pgpSigned,
            pgpVerified: pgpVerified,
            pgpSignerFingerprint: pgpSignerFingerprint,
            pgpDecryptError: pgpDecryptError
```

**Do not touch `AppSchemaVersions.swift`.** `AppSchemaV2` already lists `EmailEntity.self`, and default-valued property additions are lightweight-migration compatible.

- [ ] **Step 6: Run the full suite**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS. The whole suite must be green, not just the new tests — this task touches the persisted schema, and an existing store failing to open shows up here.

- [ ] **Step 7: Commit**

```bash
git add "KyPost/Data/Mail/RelayMailSource.swift" "KyPost/Domain/Models/Email.swift" "KyPost/Data/Database/EmailEntity.swift" "KyPost Tests/MailTests.swift"
git commit -m "pgp: carry the five relay pgp fields through DTO, domain, and persistence"
```

---

### Task 3: Distinguish the relay's 409 clientSideNeeded from any other conflict

**Files:**
- Modify: `KyPost/Data/Networking/HTTPClient.swift:18,26-36,142-144`
- Modify: `KyPost/Data/Networking/DesktopRegistrationClient.swift:65`
- Modify: `KyPost/Data/Networking/MfaResponseClient.swift:58`
- Modify: `KyPost/Data/Mail/MailSource.swift` (`MailSourceError`, `MailOutcome`, `MailOutcome.from`)
- Modify: `KyPost/Data/Mail/RelayMailSource.swift:340-347` (`send`)
- Modify: `KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift:337-348`
- Test: `KyPost Tests/NetworkingTests.swift:155`, `KyPost Tests/MailTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces: `MailOutcome.clientSideNeeded`, `MailSourceError.clientSideNeeded`, `RelayMailSource.isClientSideNeeded(conflictBody:) -> Bool`, `NetworkError.conflict(body: String)`.

**Context:** `HTTPClient` currently throws away response bodies on non-2xx, so `clientSideNeeded` is indistinguishable from any other 409. This is a defensive mapping — neither this app's `RelaySendRequest` nor Android's sends `sign`/`encrypt` flags, so it cannot fire today. It is built because `E2E_PGP.md` requirement 4 specifies it, and because the failure it guards against (a user who asked for signing silently getting an unsigned message) is the one outcome the server comment says must never happen.

- [ ] **Step 1: Write the failing tests**

In `KyPost Tests/NetworkingTests.swift`, change line 155 from `#expect(NetworkError.from(statusCode: 409) == .conflict)` to:

```swift
        #expect(NetworkError.from(statusCode: 409) == .conflict(body: ""))
        #expect(
            NetworkError.from(statusCode: 409, body: Data(#"{"clientSideNeeded":true}"#.utf8))
                == .conflict(body: #"{"clientSideNeeded":true}"#)
        )
```

Append to `KyPost Tests/MailTests.swift`:

```swift
// MARK: - Client-side-needed send refusal

@Suite struct ClientSideNeededTests {
    @Test func recognizesTheRelaysClientSideNeededConflict() {
        #expect(RelayMailSource.isClientSideNeeded(
            conflictBody: #"{"error":"end-to-end protected","clientSideNeeded":true}"#
        ))
    }

    @Test func otherConflictsAreNotClientSideNeeded() {
        #expect(RelayMailSource.isClientSideNeeded(conflictBody: #"{"error":"duplicate"}"#) == false)
        #expect(RelayMailSource.isClientSideNeeded(conflictBody: #"{"clientSideNeeded":false}"#) == false)
        #expect(RelayMailSource.isClientSideNeeded(conflictBody: "") == false)
        #expect(RelayMailSource.isClientSideNeeded(conflictBody: "not json") == false)
    }

    @Test func sendMapsTheConflictToItsOwnOutcome() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"clientSideNeeded":true}"#),
            serverUrl: "https://relay.example.com",
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .clientSideNeeded)
    }

    @Test func anUnrelatedConflictStaysAGenericFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"error":"duplicate"}"#),
            serverUrl: "https://relay.example.com",
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome != .clientSideNeeded)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:"KyPost Tests/ClientSideNeededTests"`
Expected: FAIL — `type 'RelayMailSource' has no member 'isClientSideNeeded'`.

- [ ] **Step 3: Make `NetworkError.conflict` carry its body**

In `KyPost/Data/Networking/HTTPClient.swift`, change line 18:

```swift
    case conflict(body: String)
```

Change `from(statusCode:)` to take the body, keeping the parameter defaulted so existing call sites compile:

```swift
    /// Maps a non-2xx HTTP status to its error. 2xx returns nil. `body` is
    /// retained only for 409, where the relay distinguishes a client-protected
    /// send refusal from an ordinary conflict by its payload.
    static func from(statusCode: Int, body: Data = Data()) -> NetworkError? {
        switch statusCode {
        case 200..<300: nil
        case 401, 403: .unauthorized
        case 409: .conflict(body: String(decoding: body, as: UTF8.self))
        case 429: .rateLimited
        case 503: .serviceUnavailable
        default: .server(statusCode: statusCode)
        }
    }
```

At line 142, pass the body through:

```swift
        if let error = NetworkError.from(statusCode: http.statusCode, body: data) {
            throw error
        }
```

- [ ] **Step 4: Fix the two catch sites the enum change breaks**

`KyPost/Data/Networking/DesktopRegistrationClient.swift:65` — change `} catch NetworkError.conflict {` to:

```swift
        } catch NetworkError.conflict(_) {
```

`KyPost/Data/Networking/MfaResponseClient.swift:58` — change `} catch NetworkError.unauthorized, NetworkError.conflict {` to:

```swift
        } catch NetworkError.unauthorized, NetworkError.conflict(_) {
```

- [ ] **Step 5: Add the outcome and the error case**

In `KyPost/Data/Mail/MailSource.swift`, add to `MailSourceError`:

```swift
    /// Relay 409 + clientSideNeeded: a client-protected account asked the
    /// server to sign or encrypt and it refused rather than silently sending
    /// in the clear.
    case clientSideNeeded
```

Add to `MailOutcome`:

```swift
    /// The account's PGP key is end-to-end protected; the server will not sign
    /// or encrypt on its behalf and this app holds no private key.
    case clientSideNeeded
```

Add to `MailOutcome.from(_:)`, before `default`:

```swift
        case MailSourceError.clientSideNeeded:
            .clientSideNeeded
```

- [ ] **Step 6: Map the conflict in `RelayMailSource`**

Replace `send(email:)` (line 340) in `KyPost/Data/Mail/RelayMailSource.swift`:

```swift
    func send(email: OutgoingEmail) async throws {
        do {
            _ = try await httpClient.post(
                RelaySendResponse.self,
                url: try endpoint("api/mail/send"),
                headers: auth.headerFields,
                jsonBody: RelaySendRequest(from: email)
            )
        } catch NetworkError.conflict(let body) where Self.isClientSideNeeded(conflictBody: body) {
            throw MailSourceError.clientSideNeeded
        }
    }

    /// Whether a relay 409 body is the client-protected send refusal rather
    /// than an ordinary conflict. Pure so it is testable without a transport;
    /// the relay-specific knowledge stays here rather than in HTTPClient.
    static func isClientSideNeeded(conflictBody: String) -> Bool {
        struct ConflictDTO: Decodable { var clientSideNeeded: Bool? }
        guard let data = conflictBody.data(using: .utf8),
              let dto = try? JSONDecoder().decode(ConflictDTO.self, from: data)
        else { return false }
        return dto.clientSideNeeded == true
    }
```

- [ ] **Step 7: Handle the new outcome in the compose UI**

`MailOutcome` is switched exhaustively in `KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift:337`. Add a case after `case .notPaired:`, with the message ported verbatim from Android's `mail/MailSource.kt:51`:

```swift
        case .clientSideNeeded:
            errorMessage = "This account's PGP key is end-to-end protected, so signing and encryption aren't available on mobile. Send without them, or use webmail."
```

Build after this step; if any other exhaustive `switch` over `MailOutcome` exists, the compiler will name it. Add the same message there.

- [ ] **Step 8: Run the full suite**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add KyPost/Data KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift "KyPost Tests"
git commit -m "pgp: map relay 409 clientSideNeeded to its own send outcome"
```

---

### Task 4: Mark unreadable rows in the inbox list

**Files:**
- Modify: `KyPost/Presentation/Components/EmailListRow.swift:29-32`

**Interfaces:**
- Consumes: `pgpMessageState`, `pgpRowSymbol`, `pgpRowAccessibilityLabel` (Task 1); `Email.pgpEncrypted`, `Email.pgpDecryptError` (Task 2).
- Produces: nothing.

Android used emoji with a `contentDescription` because screen readers announce emoji inconsistently in a `TextView`. SF Symbols are the native idiom here and take theme tint and weight for free. The *logic* is the parity contract, not the glyphs.

- [ ] **Step 1: Add the marker**

Replace the subject `Text` (lines 29-32) with:

```swift
                HStack(spacing: 5) {
                    if let symbol = pgpRowSymbol(rowPgpState) {
                        Image(systemName: symbol)
                            .font(AppFont.ui(12))
                            .foregroundStyle(theme.ink.opacity(0.8))
                    }
                    Text(email.subject)
                        .font(AppFont.ui(14, weight: email.read ? .regular : .medium))
                        .foregroundStyle(email.read ? theme.ink : theme.inkStrong)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    pgpRowAccessibilityLabel(state: rowPgpState, subject: email.subject) ?? email.subject
                )
```

Add this computed property to the struct, below `let email: Email`:

```swift
    private var rowPgpState: PgpMessageState {
        pgpMessageState(
            pgpEncrypted: email.pgpEncrypted,
            pgpDecryptError: email.pgpDecryptError,
            body: email.body
        )
    }
```

- [ ] **Step 2: Build and confirm the suite still passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS. This repo has no snapshot harness, so this step verifies compilation and no regressions; the marker logic itself is covered by `PgpRowMarkerTests` from Task 1.

- [ ] **Step 3: Commit**

```bash
git add KyPost/Presentation/Components/EmailListRow.swift
git commit -m "pgp: mark client-protected and decrypt-failed rows in the inbox"
```

---

### Task 5: Badges, banner, and body suppression in the reader

**Files:**
- Modify: `KyPost/Presentation/Screens/EmailDetailView.swift:17-62` (state, body), plus new private views

**Interfaces:**
- Consumes: `pgpMessageState`, `showsSignaturePill`, `webmailMessageURL` (Task 1); all five `Email.pgp*` fields (Task 2); existing `StatusBadgeView(label:isActive:)`.
- Produces: nothing.

This covers all three reader surfaces at once — iOS navigation (`InboxView:84`), the macOS split detail pane (`MacRootView:348`), and the macOS pop-out window (`MacRootView:485`) all render through `EmailDetailView`.

- [ ] **Step 1: Add the environment value and computed state**

In `KyPost/Presentation/Screens/EmailDetailView.swift`, add to the existing `@Environment` block near line 22:

```swift
    @Environment(\.openURL) private var openURL
```

Add these computed properties alongside the existing `bodyLooksLikeHTML`:

```swift
    private var pgpState: PgpMessageState {
        pgpMessageState(
            pgpEncrypted: email.pgpEncrypted,
            pgpDecryptError: email.pgpDecryptError,
            body: email.body
        )
    }

    /// Neither unreadable state has content to render; showing an empty
    /// WebView for them is the defect this change fixes.
    private var suppressesBody: Bool {
        pgpState == .clientProtected || pgpState == .decryptFailed
    }
```

Add a `@State` for the webmail link alongside the existing `@State` properties near line 29:

```swift
    /// Resolved once in `.task` rather than computed in `body` — building it
    /// reads the pairing out of the Keychain, and SwiftUI re-evaluates `body`
    /// far too often for that.
    @State private var webmailURL: URL?
```

And a resolver method next to the other private helpers:

```swift
    private func resolveWebmailURL() {
        guard pgpState == .clientProtected,
              let pairing = try? SingletonGraph.shared.securePairingStore.loadPairing()
        else {
            webmailURL = nil
            return
        }
        webmailURL = webmailMessageURL(
            serverUrl: pairing.srv,
            mailbox: email.folder,
            messageId: email.serverId
        )
    }
```

- [ ] **Step 2: Insert the badges and banner, gate the body, and resolve the link**

Attach the resolver to the view. `EmailDetailView` already has a `.task` or `.onAppear` for attachment loading — add the call there; if it has neither, add:

```swift
        .task(id: email.serverId) { resolveWebmailURL() }
```

In `var body`, insert the badge row and banner after the `header` block and before the `attachmentBar` check, then wrap the body branches:

```swift
            if pgpState != .none {
                pgpBadges
                    .padding(.horizontal)
                    .padding(.top, 10)
                pgpBanner
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if !attachments.isEmpty {
                attachmentBar
            }

            if suppressesBody {
                Spacer(minLength: 0)
            } else if bodyLooksLikeHTML {
                EmailBodyWebView(html: themedHTML(email.body))
                    .padding()
            } else {
                ScrollView {
                    Text(email.body)
                        .font(AppFont.mono(14))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
```

- [ ] **Step 3: Add the two private views**

Add near `remoteContentBanner`, which they deliberately mirror:

```swift
    /// Mirrors the web reader's two security badges (frontend ReadPage.tsx).
    @ViewBuilder
    private var pgpBadges: some View {
        HStack(spacing: 6) {
            StatusBadgeView(
                label: pgpState == .decryptFailed ? "PGP: could not decrypt" : "PGP: encrypted",
                isActive: pgpState != .decryptFailed
            )
            if showsSignaturePill(state: pgpState, signed: email.pgpSigned) {
                StatusBadgeView(
                    label: email.pgpVerified ? "signature verified" : "signature not verified",
                    isActive: email.pgpVerified
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// Same shape as remoteContentBanner below. Copy is ported verbatim from
    /// kypost-android's strings.xml — do not reword.
    @ViewBuilder
    private var pgpBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: pgpState == .decryptFailed ? "exclamationmark.triangle.fill" : "lock.fill")
                .foregroundStyle(theme.ink.opacity(0.7))
            Text(pgpBannerText)
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let webmailURL {
                Button("Open in webmail") { openURL(webmailURL) }
                    .font(AppFont.ui(12, weight: .medium))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
    }

    private var pgpBannerText: String {
        switch pgpState {
        case .clientProtected:
            webmailURL == nil
                ? "This message is end-to-end encrypted. Only your browser holds the key, so it can't be read here.\nCouldn't work out this server's web address — open this message in your browser."
                : "This message is end-to-end encrypted. Only your browser holds the key, so it can't be read here."
        case .decryptFailed:
            "This message is encrypted and couldn't be decrypted: \(email.pgpDecryptError)"
        case .decryptedByServer:
            "This message was encrypted. The server decrypted it to show it here."
        case .none:
            ""
        }
    }
```

**Do not route the webmail URL through `EmailBodyWebView` or any other in-app WebView** — `E2E_PGP.md` requirement 5 forbids it, because an in-app WebView shares no session and would put an account-password field inside this app. `openURL` hands off to the default browser on both platforms.

- [ ] **Step 4: Build and confirm the suite still passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS. Badge and banner selection logic is covered by Task 1's suites.

- [ ] **Step 5: Manual check on macOS**

Run the app against a paired account. Confirm on a plain message that no badge or banner appears and the body renders as before. This is the only regression the unit tests cannot see.

- [ ] **Step 6: Commit**

```bash
git add KyPost/Presentation/Screens/EmailDetailView.swift
git commit -m "pgp: disclose encryption state and suppress unreadable bodies in the reader"
```

---

### Task 6: Documentation

**Files:**
- Modify: `KyPost/Presentation/AGENTS.md`
- Modify: `README.md` (Features section)

- [ ] **Step 1: Record the presentation contracts**

Add to `KyPost/Presentation/AGENTS.md` under its Local Contracts section:

```markdown
- PGP message state is decided in `Domain/Models/PgpMessageState.swift` and
  never re-derived in a view. `EmailListRow` marks only the two unreadable
  states (`lock.fill` / `exclamationmark.triangle.fill`); a server-decrypted
  row is deliberately unmarked. `EmailDetailView` shows the signature badge
  **only** for `.decryptedByServer` — for a client-protected message the
  server never saw the plaintext, so `pgpSigned`/`pgpVerified` are not a
  verdict about anything. The "Open in webmail" link goes through
  `@Environment(\.openURL)` and must never be routed into an in-app WebView
  (kypost-server `docs/E2E_PGP.md` requirement 5).
```

- [ ] **Step 2: Update the feature list**

Add to `README.md`'s Features list, after the PGP QR bullet:

```markdown
- **Encryption state on every message** — messages the server decrypted say so, so you can tell it read your mail; messages your browser alone can open say that too, and link out to webmail. This app holds no PGP private key by design (see the server's `docs/E2E_PGP.md`).
```

- [ ] **Step 3: Commit**

```bash
git add KyPost/Presentation/AGENTS.md README.md
git commit -m "docs: record the PGP message-state contracts"
```

---

## Self-Review

**Spec coverage** — every requirement maps to a task:

| Spec requirement | Task |
|---|---|
| §1 `pgpMessageState` + ordering rule | 1 |
| §1 `pgpRowSymbol`, `showsSignaturePill`, `webmailMessageURL` | 1 |
| §2 five fields through DTO/domain/entity, no version bump | 2 |
| §3 row marker with accessibility label | 4 |
| §3 badges via `StatusBadgeView`, banner, body suppression | 5 |
| §3 `openURL`, never an in-app WebView | 5 (Step 3 note) + Global Constraints |
| §4 409 `clientSideNeeded` → own outcome | 3 |
| §Testing all truth tables incl. clientProtected+signed → no pill | 1 |
| §Testing DTO decode defaults | 2 |
| §Testing 409 body mapping | 3 |
| §DOX `Presentation/AGENTS.md` + README | 6 |

**Type consistency** — `PgpMessageState` case names (`none`/`clientProtected`/`decryptFailed`/`decryptedByServer`) are identical in Tasks 1, 4, and 5. `pgpRowSymbol` is used with that exact name in Task 4. `showsSignaturePill(state:signed:)` keeps its argument labels in Task 5. `webmailMessageURL(serverUrl:mailbox:messageId:)` keeps its labels in Task 5. `MailOutcome.clientSideNeeded` and `MailSourceError.clientSideNeeded` are distinct types used correctly in Task 3 Steps 5–7.

**Known ordering constraint:** Task 4 and Task 5 both depend on Tasks 1 and 2. Task 3 is independent of 1, 2, 4, and 5 and can run in parallel or be skipped without blocking the rest.
