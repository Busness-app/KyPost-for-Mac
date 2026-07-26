# Client Encrypted Send Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send encrypted and signed mail natively from this paired client for `server`-custody accounts, with an honest opt-in when a recipient has no key and a webmail handoff when the account's key is client-held.

**Architecture:** The relay does all OpenPGP work; this client only decides *what to ask for* and *what to disclose*. Two new `/api/pgp` reads (`bootstrap` for key custody, `recipients/check` for a lower-bound key preflight) live in a `PgpSendClient`, cached for the session by a `PgpSendService`. `OutgoingEmail` grows three flags that `RelaySendRequest` emits only when true, so plaintext sends stay byte-identical to today's. The relay's two 409 shapes are discriminated by field in one pure function and mapped to distinct `MailSourceError`/`MailOutcome` cases; compose confirms the keyless one and re-sends the *retained* request with one flag flipped. The client-custody path saves a server-side draft (a call this repo has never had) and hands off to webmail through `openURL`.

**Tech Stack:** Swift 6 / SwiftUI, `@Observable @MainActor` view models, Swift Testing (`@Test`/`#expect`), `HTTPClient` over `URLSession` with an injectable transport, SwiftData for the local cache (untouched here).

## Global Constraints

- **This client never holds the account's PGP private key.** No OpenPGP implementation, key generation, or key unwrapping. Not negotiable, not revivable without a conversation (`Client_Encrypted_Send.md` Scope).
- **Never call these:** `POST /api/pgp/recipients/resolve` (409s for every non-client-custody account — trap 1), `POST /api/pgp/pickup`, `POST /api/mail/send-pgp`.
- **The server side is not deployed.** Every endpoint here lives on `kypost-server` branch `feat/mobile-encrypted-send`, unmerged and undeployed. All verification in this plan is unit tests against a stubbed `HTTPClient`. A 404 in a live run means the branch hasn't landed, not a client bug.
- **Discriminate the two 409s by field, never by status code alone and never by the error prose.** The prose is user-facing copy and may be reworded; the fields are the contract.
- **The confirmation dialog copy is contract, not a detail.** Reproduce it verbatim from `Client_Encrypted_Send.md` "Confirmation dialog copy", name every address explicitly, never summarize as "some recipients", and default the dialog to Cancel.
- **Every pickup link this client can cause stores the message's plaintext on the server for 7 days.** The sealed browser variant is gated to client-custody accounts, which cannot send from here at all. Say so plainly; softening the copy defeats the opt-in.
- **No remembered "always allow pickup fallback" preference.** Per-message only, reset on every compose. Do not persist it to `UserDefaults`, the keychain, or `ComposeDraft`.
- **`allowPickupFallback` is meaningful only when `encrypt` is true.**
- **The re-send after the keyless 409 must be byte-identical apart from `allowPickupFallback`.** Retain the `OutgoingEmail` that was refused; do not re-run the preflight, rebuild the body, or re-encode attachments.
- **The webmail handoff goes through `@Environment(\.openURL)` only.** Never an in-app `WKWebView` — it shares no session and would put an account-password field inside this app (`kypost-server docs/E2E_PGP.md` requirement 5).
- **Parse permissively.** Unknown JSON fields are ignorable; an unknown `protection` value is "not `server`" — degrade, never guess.
- **New pure value types are declared `nonisolated`.** The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION` to MainActor, which infers isolated conformances that fail off-main casts at runtime, not compile time (`KyPost/Presentation/AGENTS.md`).
- **Tests:** Swift Testing. Relay-layer tests go in `KyPost Tests/MailTests.swift` alongside the existing relay tests; the new PGP-send domain, client, service and compose tests go in `KyPost Tests/PgpSendTests.swift`. `parallelizable: false` in `KyPost.xctestplan` stays off.
- **Test command:** `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`. Narrow while iterating with `-only-testing:'KyPost Tests/PgpSendTests'`.
- **Commit prefix:** `pgp:` for code, `docs:` for documentation, matching git history.

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `KyPost/Domain/Models/PgpKeyCustody.swift` | `PgpKeyCustody` enum + the pure `pgpKeyCustody(hasIdentity:protection:)` degradation rule. |
| `KyPost/Data/Networking/PgpSendClient.swift` | `GET /api/pgp/bootstrap` and `POST /api/pgp/recipients/check`, their DTOs, and the pure `keylessAddresses(in:)`. |
| `KyPost/Domain/UseCases/PgpSendService.swift` | Session cache of key custody + the recipient preflight, `@Observable @MainActor`. |
| `KyPost Tests/PgpSendTests.swift` | Custody rule, client, service, and compose-flow tests. |

**Modify:**

| File | Change |
|---|---|
| `KyPost/Domain/Models/Email.swift:66-78` | `OutgoingEmail` gains `encrypt`, `sign`, `allowPickupFallback`. |
| `KyPost/Domain/Models/PgpMessageState.swift:95-115` | Extract `webmailReadComponents`; add `webmailMailboxURL(serverUrl:mailbox:)`. |
| `KyPost/Data/Mail/MailSource.swift` | `send` returns the relay `warning`; new `saveDraft`; new `MailSourceError.keylessRecipients`; new `MailOutcome.sentWithWarning` / `.keylessRecipients`. |
| `KyPost/Data/Mail/RelayMailSource.swift` | PGP flags on `RelaySendRequest`, `keylessRecipients`/`pickupFallbackAvailable` on `RelayConflictDTO`, `conflictError(body:)` replacing `isClientSideNeeded`, `saveDraft` posting `/api/mail/draft`. |
| `KyPost/Domain/Repositories/MailRepository.swift` | `saveDraft`, `pairedServerUrl`, warning-aware `send`. |
| `KyPost/Domain/UseCases/SendEmailUseCase.swift` | `saveDraft`, `webmailDraftsURL`. |
| `KyPost/App/SingletonGraph.swift` | `pgpSendClient`, `pgpSendService`. |
| `KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift` | Toggles, preflight, keyless confirmation + re-send, webmail handoff, notice surfacing. |
| `KyPost/Presentation/Screens/ComposeView.swift` | PGP controls, inline warning, confirmation dialog, notice banner, handoff `openURL`. |
| `KyPost Tests/MailTests.swift:427-471` | `ClientSideNeededTests` rewritten against `conflictError`; new relay send/draft/409 tests. |
| `KyPost Tests/ComposeRecipientTests.swift:28-63` | `makeEnvironment` passes the new `ComposeViewModel(pgp:)` dependency. |
| `KyPost/Presentation/AGENTS.md` | Compose PGP contracts. |
| `README.md` | Feature bullet, new endpoints, known-gaps and license lines. |
| `Client_Encrypted_Send.md` (untracked → tracked) | Committed as the spec of record, beside `Client_PGP_Update.md`. |

---

### Task 1: Land the spec and the key-custody rule

**Files:**
- Add to git: `Client_Encrypted_Send.md` (currently untracked at the repo root, beside `Client_PGP_Update.md` and `Client_Contact_Update.md`)
- Create: `KyPost/Domain/Models/PgpKeyCustody.swift`
- Create test: `KyPost Tests/PgpSendTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `nonisolated enum PgpKeyCustody: Equatable, Sendable { case noIdentity, serverHeld, clientHeld }` and `nonisolated func pgpKeyCustody(hasIdentity: Bool?, protection: String?) -> PgpKeyCustody`.

- [ ] **Step 1: Write the failing test**

Create `KyPost Tests/PgpSendTests.swift`:

```swift
//
//  PgpSendTests.swift
//  KyPost Tests
//
//  Encrypted send from a paired client (Client_Encrypted_Send.md): the key
//  custody rule, the two /api/pgp preflight calls, and compose's keyless
//  confirmation and webmail handoff. Relay send/draft wire tests live in
//  MailTests.swift with the other relay tests.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Key custody

@Suite struct PgpKeyCustodyTests {
    @Test func serverProtectionIsTheOnlyNativeSendMode() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: "server") == .serverHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: "client") == .clientHeld)
    }

    @Test func noIdentityMeansPlaintextOnly() {
        #expect(pgpKeyCustody(hasIdentity: false, protection: "server") == .noIdentity)
        #expect(pgpKeyCustody(hasIdentity: nil, protection: nil) == .noIdentity)
        // An identity-less account reports protection "" (the spec's table).
        #expect(pgpKeyCustody(hasIdentity: true, protection: "") == .noIdentity)
    }

    /// Degrade, never guess: an unknown mode must not promise an encrypted
    /// send this app cannot deliver.
    @Test func unknownProtectionDegradesToClientHeld() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: "hsm") == .clientHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: nil) == .clientHeld)
    }

    @Test func protectionIsReadTolerantly() {
        #expect(pgpKeyCustody(hasIdentity: true, protection: " Server ") == .serverHeld)
        #expect(pgpKeyCustody(hasIdentity: true, protection: "SERVER") == .serverHeld)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: FAIL — compile error, `cannot find 'pgpKeyCustody' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `KyPost/Domain/Models/PgpKeyCustody.swift`:

```swift
//
//  PgpKeyCustody.swift
//  KyPost
//
//  Who holds the account's PGP private key, and therefore whether this client
//  may ask the relay to sign and encrypt on its behalf
//  (Client_Encrypted_Send.md "two key-custody modes").
//
//  A pure mapping of GET /api/pgp/bootstrap's hasIdentity/protection so the
//  degradation rule is testable without a network. This client never holds the
//  account's private key — see kypost-server/docs/E2E_PGP.md.
//

import Foundation

nonisolated enum PgpKeyCustody: Equatable, Sendable {
    /// No PGP identity. Plaintext send only; compose offers no toggles.
    case noIdentity

    /// The server holds the key, encrypted at rest under its own key, and
    /// signs/encrypts for the account. Native encrypted send works here.
    case serverHeld

    /// Only the user's browser can unwrap the key, from a password-derived key
    /// this client never learns. Encrypted send is impossible here; compose
    /// offers the webmail handoff instead.
    case clientHeld
}

/// Maps a bootstrap response to custody, degrading rather than guessing.
///
/// An unrecognised `protection` maps to `.clientHeld`. A future mode is far
/// more likely to be a stronger client-side one than a server-side one, and
/// reading it as client-held costs only a webmail handoff — reading it as
/// server-held would promise an encrypted send this client cannot deliver.
nonisolated func pgpKeyCustody(hasIdentity: Bool?, protection: String?) -> PgpKeyCustody {
    guard hasIdentity == true else { return .noIdentity }
    switch (protection ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
    case "": .noIdentity
    case "server": .serverHeld
    default: .clientHeld
    }
}
```

Add the new files to the Xcode project: `KyPost.xcodeproj` uses file-system synchronized groups, so files dropped in `KyPost/` and `KyPost Tests/` are picked up automatically — no `project.pbxproj` edit. Verify by the build succeeding in Step 4; if the test target reports "cannot find PgpKeyCustody in scope" despite the file existing, open the project in Xcode once and confirm target membership.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Client_Encrypted_Send.md "KyPost/Domain/Models/PgpKeyCustody.swift" "KyPost Tests/PgpSendTests.swift"
git commit -m "pgp: add the encrypted-send spec and the key-custody rule"
```

---

### Task 2: The two `/api/pgp` preflight calls

**Files:**
- Create: `KyPost/Data/Networking/PgpSendClient.swift`
- Test: `KyPost Tests/PgpSendTests.swift` (append)

**Interfaces:**
- Consumes: `HTTPClient`, `RelayAuth`, `NetworkError` (`KyPost/Data/Networking/HTTPClient.swift`); `PgpKeyCustody` from Task 1 (only in tests here).
- Produces:
  - `nonisolated struct PgpBootstrapResponse: Decodable, Equatable, Sendable { var hasIdentity: Bool?; var protection: String? }`
  - `nonisolated struct PgpRecipientCheckDTO: Decodable, Equatable, Sendable { var address: String; var hasKey: Bool?; var revoked: Bool?; var expired: Bool?; var tier: String?; var isUsable: Bool { get } }`
  - `nonisolated func keylessAddresses(in results: [PgpRecipientCheckDTO]) -> [String]`
  - `final class PgpSendClient: Sendable` with `func fetchBootstrap(serverUrl: String, auth: RelayAuth) async throws -> PgpBootstrapResponse` and `func checkRecipients(_ addresses: [String], serverUrl: String, auth: RelayAuth) async throws -> [PgpRecipientCheckDTO]`

- [ ] **Step 1: Write the failing test**

Append to `KyPost Tests/PgpSendTests.swift`:

```swift
// MARK: - PgpSendClient

@Suite struct PgpSendClientTests {
    private let auth = RelayAuth(deviceId: "u1", deviceSecret: "h1")

    @Test func bootstrapReadsOnlyTheTwoFieldsThisClientNeeds() async throws {
        // The real response also carries wrappedPrivateKey, unlockRequired,
        // signerPublicKeys, payloadEndpoint … — all ignorable here.
        let json = """
        {"hasIdentity": true, "protection": "server", "fingerprint": "AB", "keyId": "CD",
         "publicKey": "-----BEGIN PGP PUBLIC KEY BLOCK----- x", "keySource": "generated",
         "wrappedPrivateKey": "zzz", "unlockRequired": true, "signerPublicKeys": ["a"]}
        """
        let client = PgpSendClient(httpClient: stubClient(json: json) { request in
            #expect(request.url!.absoluteString == "\(server)/api/pgp/bootstrap")
            #expect(request.httpMethod == nil || request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        })

        let response = try await client.fetchBootstrap(serverUrl: server, auth: auth)
        #expect(response.hasIdentity == true)
        #expect(response.protection == "server")
        #expect(pgpKeyCustody(
            hasIdentity: response.hasIdentity,
            protection: response.protection
        ) == .serverHeld)
    }

    @Test func bootstrapWithNoFieldsDecodesRatherThanThrowing() async throws {
        let client = PgpSendClient(httpClient: stubClient(json: "{}"))
        let response = try await client.fetchBootstrap(serverUrl: server, auth: auth)
        #expect(response.hasIdentity == nil)
        #expect(pgpKeyCustody(
            hasIdentity: response.hasIdentity,
            protection: response.protection
        ) == .noIdentity)
    }

    @Test func checkPostsEveryAddressToTheCheckEndpoint() async throws {
        let json = """
        {"results": [
          {"address": "alice@example.com", "hasKey": true, "revoked": false, "expired": false, "tier": "contact-verified"},
          {"address": "bob@example.com", "hasKey": false, "revoked": false, "expired": false, "tier": "none"}
        ]}
        """
        let client = PgpSendClient(httpClient: stubClient(json: json) { request in
            // Never /resolve: it hands over recipients' keys and 409s for any
            // account that is not client-protected (trap 1).
            #expect(request.url!.absoluteString == "\(server)/api/pgp/recipients/check")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""addresses":["alice@example.com","bob@example.com"]"#))
        })

        let results = try await client.checkRecipients(
            ["alice@example.com", "bob@example.com"],
            serverUrl: server,
            auth: auth
        )
        #expect(results.count == 2)
        #expect(keylessAddresses(in: results) == ["bob@example.com"])
    }

    @Test func missingResultsIsAnEmptyListNotAFailure() async throws {
        let client = PgpSendClient(httpClient: stubClient(json: "{}"))
        let results = try await client.checkRecipients(["a@x.com"], serverUrl: server, auth: auth)
        #expect(results.isEmpty)
        #expect(keylessAddresses(in: results).isEmpty)
    }

    /// "revoked but present" is never sendable, whatever `hasKey` claims.
    @Test func revokedOrExpiredKeysAreNotUsable() {
        let revoked = PgpRecipientCheckDTO(
            address: "r@x.com", hasKey: true, revoked: true, expired: false, tier: "contact"
        )
        let expired = PgpRecipientCheckDTO(
            address: "e@x.com", hasKey: true, revoked: false, expired: true, tier: "contact"
        )
        let good = PgpRecipientCheckDTO(
            address: "g@x.com", hasKey: true, revoked: nil, expired: nil, tier: "contact"
        )
        #expect(keylessAddresses(in: [revoked, expired, good]) == ["r@x.com", "e@x.com"])
    }

    @Test func aBadServerUrlFailsBeforeAnyRequest() async {
        let client = PgpSendClient(httpClient: stubClient())
        await #expect(throws: NetworkError.invalidURL) {
            try await client.fetchBootstrap(serverUrl: "", auth: auth)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: FAIL — `cannot find 'PgpSendClient' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `KyPost/Data/Networking/PgpSendClient.swift`:

```swift
//
//  PgpSendClient.swift
//  KyPost
//
//  The two /api/pgp reads the send path needs (Client_Encrypted_Send.md):
//    GET  /api/pgp/bootstrap          — this account's key custody
//    POST /api/pgp/recipients/check   — contacts-only recipient key preflight
//
//  Both are withMailAuth, so pairing headers (RelayAuth.headerFields) are
//  first-class credentials — this client has no web session cookie.
//
//  Never POST /api/pgp/recipients/resolve. It returns recipients' actual public
//  keys so a client-custody *browser* can encrypt locally, and it 409s for any
//  account that is not client-protected: a server-custody client asking it
//  "does this recipient have a key" is refused every time.
//

import Foundation

/// GET /api/pgp/bootstrap. The full response also carries the browser's key
/// material (`wrappedPrivateKey`, `unlockRequired`, `signerPublicKeys`,
/// `payloadEndpoint`, …); this client needs only these two fields and ignores
/// the rest by not declaring them.
nonisolated struct PgpBootstrapResponse: Decodable, Equatable, Sendable {
    var hasIdentity: Bool?
    /// "server", "client", or "" — read through `pgpKeyCustody`, which treats
    /// anything unrecognised as "not server".
    var protection: String?
}

nonisolated struct PgpRecipientCheckRequest: Encodable, Equatable, Sendable {
    var addresses: [String]
}

/// One entry of POST /api/pgp/recipients/check.
nonisolated struct PgpRecipientCheckDTO: Decodable, Equatable, Sendable {
    var address: String
    /// True only when a key exists *and* is usable. `revoked`/`expired` explain
    /// why a key is unusable; they are not a second chance at sending.
    var hasKey: Bool?
    var revoked: Bool?
    var expired: Bool?
    var tier: String?

    /// The conjunction is belt and braces: `hasKey` is already meant to be
    /// false for a revoked or expired key, and a server that ever reported
    /// "revoked but present" must not read as sendable.
    var isUsable: Bool {
        hasKey == true && revoked != true && expired != true
    }
}

nonisolated struct PgpRecipientCheckResponse: Decodable, Sendable {
    var results: [PgpRecipientCheckDTO]?
}

/// Addresses the preflight found no usable key for.
///
/// A lower bound, never a promise: `check` looks only in the user's contacts,
/// while the send path additionally runs the discovery ladder (WKD, keyservers,
/// subject to the user's discovery settings). An address listed here may still
/// be encrypted to successfully — warn early, and let the relay's 409 drive the
/// confirmation.
nonisolated func keylessAddresses(in results: [PgpRecipientCheckDTO]) -> [String] {
    results.filter { !$0.isUsable }.map(\.address)
}

final class PgpSendClient: Sendable {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    /// GET {srv}/api/pgp/bootstrap — the account's key custody. Called once
    /// per session; `PgpSendService` owns the caching.
    ///
    /// Errors: 401 credentials rejected, 503 pairing secret unset server-side.
    func fetchBootstrap(serverUrl: String, auth: RelayAuth) async throws -> PgpBootstrapResponse {
        guard let base = URL(string: serverUrl), base.host != nil else {
            throw NetworkError.invalidURL
        }
        return try await httpClient.get(
            PgpBootstrapResponse.self,
            url: base.appending(path: "api/pgp/bootstrap"),
            headers: auth.headerFields
        )
    }

    /// POST {srv}/api/pgp/recipients/check — which of these addresses have a
    /// usable key *in the user's contacts*.
    ///
    /// Errors: 401 credentials rejected, 400 malformed address list.
    func checkRecipients(
        _ addresses: [String],
        serverUrl: String,
        auth: RelayAuth
    ) async throws -> [PgpRecipientCheckDTO] {
        guard let base = URL(string: serverUrl), base.host != nil else {
            throw NetworkError.invalidURL
        }
        let response = try await httpClient.post(
            PgpRecipientCheckResponse.self,
            url: base.appending(path: "api/pgp/recipients/check"),
            headers: auth.headerFields,
            jsonBody: PgpRecipientCheckRequest(addresses: addresses)
        )
        return response.results ?? []
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Data/Networking/PgpSendClient.swift" "KyPost Tests/PgpSendTests.swift"
git commit -m "pgp: add the bootstrap and recipient-check preflight client"
```

---

### Task 3: PGP flags on the send body, and the relay's `warning`

**Files:**
- Modify: `KyPost/Domain/Models/Email.swift:66-78` (`OutgoingEmail`)
- Modify: `KyPost/Data/Mail/RelayMailSource.swift:218-239` (`RelaySendRequest`), `:363-374` (`send`)
- Modify: `KyPost/Data/Mail/MailSource.swift:33` (protocol `send`), `:56-81` (`MailOutcome`)
- Modify: `KyPost/Domain/Repositories/MailRepository.swift:101-108` (`send`)
- Test: `KyPost Tests/MailTests.swift` (append to `RelayMailSourceTests` and add a suite)

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces:
  - `OutgoingEmail.encrypt: Bool`, `.sign: Bool`, `.allowPickupFallback: Bool` (all default `false`)
  - `RelaySendRequest.init(from: OutgoingEmail, pgpFlags: Bool = true)` with `encrypt`/`sign`/`allowPickupFallback` as `Bool?`, emitted only when true
  - `@discardableResult func send(email: OutgoingEmail) async throws -> String` on `MailSource` (returns the relay `warning`, `""` when absent)
  - `MailOutcome.sentWithWarning(String)`

- [ ] **Step 1: Write the failing test**

Append to `@Suite struct RelayMailSourceTests` in `KyPost Tests/MailTests.swift` (after `sendEncodesModeAndBase64Attachments`, around line 274):

```swift
    @Test func plaintextSendOmitsThePgpFlagsEntirely() throws {
        let data = try JSONEncoder().encode(RelaySendRequest(from: makeOutgoing()))
        let body = String(decoding: data, as: UTF8.self)
        // A plaintext send must look exactly as it did before encryption
        // existed; the relay defaults all three to false.
        #expect(!body.contains("encrypt"))
        #expect(!body.contains("sign"))
        #expect(!body.contains("allowPickupFallback"))
    }

    @Test func encryptedSendCarriesTheFlagsItWasGiven() throws {
        var email = makeOutgoing()
        email.encrypt = true
        email.sign = true
        let object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(RelaySendRequest(from: email))
        ) as? [String: Any])
        #expect(object["encrypt"] as? Bool == true)
        #expect(object["sign"] as? Bool == true)
        // Not consented to yet: the first send always asks without it.
        #expect(object["allowPickupFallback"] == nil)
    }

    /// allowPickupFallback is meaningful only with encrypt, so it never travels
    /// on a plaintext send even if something set it.
    @Test func pickupFallbackNeedsEncrypt() throws {
        var email = makeOutgoing()
        email.allowPickupFallback = true
        let plain = String(decoding: try JSONEncoder().encode(RelaySendRequest(from: email)), as: UTF8.self)
        #expect(!plain.contains("allowPickupFallback"))

        email.encrypt = true
        let encrypted = String(decoding: try JSONEncoder().encode(RelaySendRequest(from: email)), as: UTF8.self)
        #expect(encrypted.contains(#""allowPickupFallback":true"#))
    }

    @Test func sendReturnsTheRelayWarning() async throws {
        let json = #"{"ok": true, "sentSaved": false, "warning": "failed to deliver a pickup link to 1 of 3 recipient(s)"}"#
        let source = RelayMailSource(httpClient: stubClient(json: json), serverUrl: server, auth: auth)
        let warning = try await source.send(email: makeOutgoing())
        #expect(warning == "failed to deliver a pickup link to 1 of 3 recipient(s)")
    }

    @Test func aCleanSendHasNoWarning() async throws {
        let source = RelayMailSource(
            httpClient: stubClient(json: #"{"ok": true, "sentSaved": true, "warning": ""}"#),
            serverUrl: server,
            auth: auth
        )
        #expect(try await source.send(email: makeOutgoing()) == "")
        // Absent, not just empty.
        let terse = RelayMailSource(
            httpClient: stubClient(json: #"{"ok": true}"#),
            serverUrl: server,
            auth: auth
        )
        #expect(try await terse.send(email: makeOutgoing()) == "")
    }
```

Then append a new suite at the end of `KyPost Tests/MailTests.swift`:

```swift
// MARK: - Partial-success warnings

@Suite struct SendWarningTests {
    /// A warning means the message *was* sent. It must never look like a
    /// failure, and must never offer a retry that would duplicate it.
    @Test func aWarningIsSuccessNotFailure() async throws {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let json = #"{"ok": true, "sentSaved": false, "warning": "sent copy not saved"}"#
        let repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: json)
        )

        let outcome = await repository.send(makeOutgoing())
        #expect(outcome == .sentWithWarning("sent copy not saved"))
    }

    @Test func noWarningIsPlainSuccess() async throws {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: #"{"ok": true, "sentSaved": true, "warning": ""}"#)
        )
        #expect(await repository.send(makeOutgoing()) == .success)
    }
}
```

`makeOutgoing()` and `auth` already exist in `MailTests.swift`; confirm `makeOutgoing` is reachable from the new suite (it is file-scope) before adding.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/MailTests'`
Expected: FAIL — `value of type 'OutgoingEmail' has no member 'encrypt'`, and `type 'MailOutcome' has no member 'sentWithWarning'`.

- [ ] **Step 3: Write minimal implementation**

In `KyPost/Domain/Models/Email.swift`, add to `OutgoingEmail` after `attachments` and before `tab` (every new property is defaulted, so the existing labelled call sites keep compiling):

```swift
    /// Ask the relay to encrypt this message to its recipients. The server
    /// holds the key and does the OpenPGP work; this client never does
    /// (Client_Encrypted_Send.md).
    var encrypt = false
    /// Ask the relay to sign with the account's key.
    var sign = false
    /// Consent to the relay mailing a one-time pickup link to recipients with
    /// no usable key, which stores this message's plaintext on the server for
    /// 7 days. Meaningful only with `encrypt`. Per-message by design — never
    /// remembered, never persisted.
    var allowPickupFallback = false
```

In `KyPost/Data/Mail/RelayMailSource.swift`, replace `RelaySendRequest`:

```swift
/// Send body with comma-joined recipients (Mobile_Mail_Relay.md Part 6) —
/// differs from contact sync's array-of-objects shape. POST /api/mail/draft
/// takes the same shape minus the PGP flags.
struct RelaySendRequest: Encodable, Equatable, Sendable {
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var mode: String
    /// Omitted from the JSON entirely when there are no attachments.
    var attachments: [RelaySendAttachmentDTO]?
    /// PGP flags, omitted when false so a plaintext send is byte-identical to
    /// what this client sent before encryption existed; the relay defaults all
    /// three to false. `allowPickupFallback` is meaningful only with `encrypt`.
    var encrypt: Bool?
    var sign: Bool?
    var allowPickupFallback: Bool?

    /// `pgpFlags: false` builds the draft-save body, which carries no PGP
    /// fields at all.
    init(from email: OutgoingEmail, pgpFlags: Bool = true) {
        to = email.to.joined(separator: ", ")
        cc = email.cc.joined(separator: ", ")
        bcc = email.bcc.joined(separator: ", ")
        subject = email.subject
        body = email.body
        mode = email.mode
        attachments = email.attachments.isEmpty
            ? nil
            : email.attachments.map(RelaySendAttachmentDTO.init)
        let pgp = pgpFlags
        encrypt = pgp && email.encrypt ? true : nil
        sign = pgp && email.sign ? true : nil
        allowPickupFallback = pgp && email.encrypt && email.allowPickupFallback ? true : nil
    }
}
```

Replace `RelayMailSource.send`:

```swift
    @discardableResult
    func send(email: OutgoingEmail) async throws -> String {
        do {
            let response = try await httpClient.post(
                RelaySendResponse.self,
                url: try endpoint("api/mail/send"),
                headers: auth.headerFields,
                jsonBody: RelaySendRequest(from: email)
            )
            return response.warning ?? ""
        } catch NetworkError.conflict(let body) where Self.isClientSideNeeded(conflictBody: body) {
            throw MailSourceError.clientSideNeeded
        }
    }
```

In `KyPost/Data/Mail/MailSource.swift`, replace the protocol requirement:

```swift
    /// Sends a message and returns the relay's `warning` — empty on a clean
    /// send, non-empty on a *partial* problem (the Sent copy failed to save,
    /// and/or some pickup links failed to deliver). A warning still means the
    /// message went out: never retry on one, it would duplicate.
    @discardableResult
    func send(email: OutgoingEmail) async throws -> String
```

Add to `MailOutcome`:

```swift
    /// Sent, but with a partial problem worth showing (Sent copy not saved,
    /// some pickup links undelivered). Not a failure; offering a retry here
    /// would duplicate the message. Treat the text as opaque human-readable
    /// prose — never pattern-match its wording.
    case sentWithWarning(String)
```

In `KyPost/Domain/Repositories/MailRepository.swift`, replace `send`:

```swift
    func send(_ email: OutgoingEmail) async -> MailOutcome {
        do {
            let warning = try await makeSource().send(email: email)
            return warning.isEmpty ? .success : .sentWithWarning(warning)
        } catch {
            return MailOutcome.from(error)
        }
    }
```

Also update the file-header endpoint list in `RelayMailSource.swift` (lines 5-14) to mention `encrypt`/`sign`/`allowPickupFallback` on `POST /api/mail/send`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/MailTests'`
Expected: PASS. If `ComposeViewModel.swift` fails to compile on the now-non-exhaustive `switch outcome`, add a temporary `case .sentWithWarning(let warning): errorMessage = warning` — Task 7 replaces it properly.

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Domain/Models/Email.swift" "KyPost/Data/Mail/RelayMailSource.swift" \
        "KyPost/Data/Mail/MailSource.swift" "KyPost/Domain/Repositories/MailRepository.swift" \
        "KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift" "KyPost Tests/MailTests.swift"
git commit -m "pgp: carry encrypt/sign/allowPickupFallback and the send warning"
```

---

### Task 4: The keyless-recipients 409

**Files:**
- Modify: `KyPost/Data/Mail/RelayMailSource.swift:162-166` (`RelayConflictDTO`), `:363-384` (`send`, `isClientSideNeeded`)
- Modify: `KyPost/Data/Mail/MailSource.swift:44-54` (`MailSourceError`), `:56-81` (`MailOutcome`)
- Test: `KyPost Tests/MailTests.swift:427-471` (rewrite `ClientSideNeededTests`)

**Interfaces:**
- Consumes: `MailOutcome.sentWithWarning` and the `send` signature from Task 3.
- Produces:
  - `MailSourceError.keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)`
  - `MailOutcome.keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)`
  - `static func conflictError(body: String) -> MailSourceError?` on `RelayMailSource` (replaces `isClientSideNeeded(conflictBody:)`)

- [ ] **Step 1: Write the failing test**

Replace `@Suite struct ClientSideNeededTests` in `KyPost Tests/MailTests.swift` (lines 427-471) with:

```swift
// MARK: - The relay's two PGP 409s

@Suite struct RelayConflictTests {
    /// Discrimination is by field. The prose is user-facing copy and may be
    /// reworded at any time.
    @Test func clientSideNeededIsRecognisedByItsField() {
        #expect(RelayMailSource.conflictError(
            body: #"{"error":"end-to-end protected","clientSideNeeded":true}"#
        ) == .clientSideNeeded)
    }

    @Test func keylessRecipientsCarriesTheAddressesAndTheFallbackFlag() {
        let body = """
        {"error": "some recipients have no usable PGP key; sending them a one-time link stores this message's plaintext on the server for 7 days",
         "keylessRecipients": ["bob@example.com", "carol@example.com"],
         "pickupFallbackAvailable": true}
        """
        #expect(RelayMailSource.conflictError(body: body) == .keylessRecipients(
            addresses: ["bob@example.com", "carol@example.com"],
            pickupFallbackAvailable: true
        ))
    }

    /// A server with pickup links turned off refuses and offers nothing.
    @Test func aKeylessConflictWithoutTheFallbackFlagIsNotOfferable() {
        let body = #"{"keylessRecipients":["bob@example.com"]}"#
        #expect(RelayMailSource.conflictError(body: body) == .keylessRecipients(
            addresses: ["bob@example.com"],
            pickupFallbackAvailable: false
        ))
    }

    /// A 409 carrying neither field must not inherit PGP wording.
    @Test func anOrdinaryConflictMapsToNoPgpError() {
        #expect(RelayMailSource.conflictError(body: #"{"error":"duplicate"}"#) == nil)
        #expect(RelayMailSource.conflictError(body: #"{"clientSideNeeded":false}"#) == nil)
        #expect(RelayMailSource.conflictError(body: #"{"keylessRecipients":[]}"#) == nil)
    }

    /// Every non-409 error body is plain text, and a 409 body may still be
    /// malformed. Decoding must never trap.
    @Test func aMalformedConflictBodyDoesNotCrash() {
        #expect(RelayMailSource.conflictError(body: "") == nil)
        #expect(RelayMailSource.conflictError(body: "failed to send email: dial tcp") == nil)
        #expect(RelayMailSource.conflictError(body: #"{"keylessRecipients":"bob@example.com"}"#) == nil)
        #expect(RelayMailSource.conflictError(body: "[1,2,3]") == nil)
    }

    @Test func sendMapsTheClientSideConflictToItsOwnOutcome() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"clientSideNeeded":true}"#),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .clientSideNeeded)
    }

    @Test func sendMapsTheKeylessConflictToItsOwnOutcome() async {
        let json = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: json),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .keylessRecipients(
            addresses: ["bob@example.com"],
            pickupFallbackAvailable: true
        ))
    }

    @Test func anUnrelatedConflictStaysAGenericFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"error":"duplicate"}"#),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .clientSideNeeded          // must be overwritten
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should still throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        if case .failure = outcome {} else {
            Issue.record("an ordinary 409 should be a generic failure, got \(outcome)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/MailTests'`
Expected: FAIL — `type 'RelayMailSource' has no member 'conflictError'`.

- [ ] **Step 3: Write minimal implementation**

In `KyPost/Data/Mail/RelayMailSource.swift`, replace `RelayConflictDTO`:

```swift
/// Shape of a relay 409 body. Both PGP refusals are told apart from an
/// ordinary conflict — and from each other — by which of these fields is
/// present, never by the error prose (see `RelayMailSource.conflictError`).
/// Every field is optional because a 409 body may be neither shape, and
/// because non-409 errors return plain text.
struct RelayConflictDTO: Decodable, Sendable {
    var clientSideNeeded: Bool?
    /// Recipients with no usable PGP key. Nothing was delivered — the refusal
    /// happens before any SMTP, so re-sending with `allowPickupFallback` cannot
    /// duplicate the message.
    var keylessRecipients: [String]?
    /// Whether re-sending with `allowPickupFallback: true` is available at all.
    var pickupFallbackAvailable: Bool?
}
```

Replace `send` and `isClientSideNeeded`:

```swift
    @discardableResult
    func send(email: OutgoingEmail) async throws -> String {
        do {
            let response = try await httpClient.post(
                RelaySendResponse.self,
                url: try endpoint("api/mail/send"),
                headers: auth.headerFields,
                jsonBody: RelaySendRequest(from: email)
            )
            return response.warning ?? ""
        } catch NetworkError.conflict(let body) {
            throw Self.conflictError(body: body) ?? NetworkError.conflict(body: body)
        }
    }

    /// Which PGP refusal a relay 409 body represents, or nil for an ordinary
    /// conflict the caller should surface generically.
    ///
    /// Pure so it is testable without a transport, and so the relay-specific
    /// knowledge stays here rather than in HTTPClient. Discriminates by field:
    /// the error strings are user-facing copy and may be reworded.
    static func conflictError(body: String) -> MailSourceError? {
        guard let data = body.data(using: .utf8),
              let dto = try? JSONDecoder().decode(RelayConflictDTO.self, from: data)
        else { return nil }
        if dto.clientSideNeeded == true {
            return .clientSideNeeded
        }
        if let addresses = dto.keylessRecipients, !addresses.isEmpty {
            return .keylessRecipients(
                addresses: addresses,
                pickupFallbackAvailable: dto.pickupFallbackAvailable ?? false
            )
        }
        return nil
    }
```

In `KyPost/Data/Mail/MailSource.swift`, add to `MailSourceError`:

```swift
    /// Relay 409 + keylessRecipients: at least one recipient has no usable
    /// key. **Nothing was delivered** — the refusal happens before any SMTP.
    /// Re-sending the identical request with `allowPickupFallback: true` is
    /// safe and cannot duplicate. `pickupFallbackAvailable` is false when the
    /// server has one-time links turned off, in which case there is nothing to
    /// offer the user.
    case keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)
```

Add to `MailOutcome`:

```swift
    /// Some recipients have no usable key and nothing was sent. Confirming
    /// mails them a one-time link and stores this message's plaintext on the
    /// server for 7 days.
    case keylessRecipients(addresses: [String], pickupFallbackAvailable: Bool)
```

and to `MailOutcome.from`, before `default`:

```swift
        case MailSourceError.keylessRecipients(let addresses, let pickupFallbackAvailable):
            .keylessRecipients(
                addresses: addresses,
                pickupFallbackAvailable: pickupFallbackAvailable
            )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/MailTests'`
Expected: PASS. `ComposeViewModel`'s `switch outcome` needs a temporary `case .keylessRecipients: errorMessage = "…"` arm to compile; Task 7 replaces it.

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Data/Mail/RelayMailSource.swift" "KyPost/Data/Mail/MailSource.swift" \
        "KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift" "KyPost Tests/MailTests.swift"
git commit -m "pgp: map the keyless-recipients 409 to its own send outcome"
```

---

### Task 5: Draft save and the webmail Drafts link

**Files:**
- Modify: `KyPost/Data/Mail/MailSource.swift` (protocol), `KyPost/Data/Mail/RelayMailSource.swift` (implementation + header comment at `:203`)
- Modify: `KyPost/Domain/Models/PgpMessageState.swift:95-115`
- Modify: `KyPost/Domain/Repositories/MailRepository.swift`
- Modify: `KyPost/Domain/UseCases/SendEmailUseCase.swift`
- Test: `KyPost Tests/MailTests.swift`, `KyPost Tests/PgpMessageStateTests.swift`

**Interfaces:**
- Consumes: `RelaySendRequest.init(from:pgpFlags:)` from Task 3.
- Produces:
  - `func saveDraft(email: OutgoingEmail) async throws` on `MailSource`
  - `func saveDraft(_ email: OutgoingEmail) async -> MailOutcome` and `var pairedServerUrl: String? { get }` on `MailRepository`
  - `func saveDraft(_ email: OutgoingEmail) async -> MailOutcome` and `var webmailDraftsURL: URL? { get }` on `SendEmailUseCase`
  - `nonisolated func webmailMailboxURL(serverUrl: String, mailbox: String) -> URL?`

- [ ] **Step 1: Write the failing test**

Append to `@Suite struct RelayMailSourceTests` in `KyPost Tests/MailTests.swift`:

```swift
    @Test func saveDraftPostsTheSendShapeWithoutPgpFields() async throws {
        var email = makeOutgoing()
        email.encrypt = true
        email.sign = true
        email.allowPickupFallback = true
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/mail/draft")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""to":"a@x.com, b@x.com""#))
            #expect(body.contains(#""mode":"plain""#))
            // A draft has no PGP semantics; the server would ignore them and
            // sending them invites confusion.
            #expect(!body.contains("encrypt"))
            #expect(!body.contains("sign"))
            #expect(!body.contains("allowPickupFallback"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.saveDraft(email: email)
    }

    @Test func saveDraftSurfacesAPlainTextFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 500, json: "could not save draft"),
            serverUrl: server,
            auth: auth
        )
        await #expect(throws: NetworkError.server(statusCode: 500)) {
            try await source.saveDraft(email: makeOutgoing())
        }
    }
```

Append to `@Suite struct MailRepositoryTests`:

```swift
    @Test func saveDraftIsSuccessAndNeedsAPairing() async throws {
        let paired = try makeRepository(client: stubClient(json: #"{"ok": true}"#), paired: true)
        #expect(await paired.saveDraft(makeOutgoing()) == .success)
        #expect(paired.pairedServerUrl == server)

        let unpaired = try makeRepository(client: stubClient(), paired: false)
        #expect(await unpaired.saveDraft(makeOutgoing()) == .notPaired)
        #expect(unpaired.pairedServerUrl == nil)
    }
```

Append to `KyPost Tests/PgpMessageStateTests.swift`:

```swift
// MARK: - Webmail mailbox links (compose handoff)

@Suite struct WebmailMailboxURLTests {
    @Test func draftsGetsAnExplicitMailboxParam() {
        #expect(
            webmailMailboxURL(serverUrl: "https://mail.example.com", mailbox: StandardFolder.drafts)?
                .absoluteString == "https://mail.example.com/read?mailbox=Drafts"
        )
    }

    @Test func inboxIsSentAsAnAbsentMailboxParam() {
        #expect(
            webmailMailboxURL(serverUrl: "https://mail.example.com/", mailbox: "INBOX")?
                .absoluteString == "https://mail.example.com/read"
        )
    }

    @Test func aServerUrlThatIsNotAbsoluteHasNoLink() {
        #expect(webmailMailboxURL(serverUrl: "", mailbox: "Drafts") == nil)
        #expect(webmailMailboxURL(serverUrl: "not a url", mailbox: "Drafts") == nil)
    }

    /// The message link keeps working exactly as it did — mailbox first, then
    /// message — now that both share one components builder.
    @Test func messageLinksAreUnchanged() {
        #expect(
            webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "Archive", messageId: "42")?
                .absoluteString == "https://mail.example.com/read?mailbox=Archive&message=42"
        )
        #expect(
            webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: "42")?
                .absoluteString == "https://mail.example.com/read?message=42"
        )
        #expect(webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: " ") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/MailTests' -only-testing:'KyPost Tests/PgpMessageStateTests'`
Expected: FAIL — `value of type 'RelayMailSource' has no member 'saveDraft'`, `cannot find 'webmailMailboxURL' in scope`.

- [ ] **Step 3: Write minimal implementation**

In `KyPost/Data/Mail/MailSource.swift`, add to the protocol after `send`:

```swift
    /// Saves a draft server-side (POST /api/mail/draft). Same body shape as
    /// `send` minus the PGP flags; the response is `{"ok": true}` and every
    /// failure is a plain-text error. The client-custody webmail handoff
    /// depends on this call.
    func saveDraft(email: OutgoingEmail) async throws
```

In `KyPost/Data/Mail/RelayMailSource.swift`, add after `send` (and drop the stale "only mentions the endpoint in a comment" note near `RelaySendAttachmentDTO` if it now reads as wrong):

```swift
    func saveDraft(email: OutgoingEmail) async throws {
        // {"ok": true} — same shape as the bulk-action reply, so no extra DTO.
        _ = try await httpClient.post(
            RelayActionResponse.self,
            url: try endpoint("api/mail/draft"),
            headers: auth.headerFields,
            jsonBody: RelaySendRequest(from: email, pgpFlags: false)
        )
    }
```

Add `POST /api/mail/draft` to the file-header endpoint list (lines 9-11).

In `KyPost/Domain/Models/PgpMessageState.swift`, replace `webmailMessageURL` (lines 88-115) with:

```swift
/// `/read` URL components for the paired server, or nil when `serverUrl` isn't
/// a usable absolute URL — callers render "no button" rather than a dead one.
///
/// INBOX is sent as an absent `mailbox` param rather than the literal string,
/// matching the links the web app builds for itself.
private nonisolated func webmailReadComponents(
    serverUrl: String,
    mailbox: String
) -> URLComponents? {
    let trimmed = serverUrl.trimmingCharacters(in: .whitespaces)
    let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    guard var components = URLComponents(string: base),
          components.scheme != nil,
          components.host != nil
    else { return nil }

    components.path += "/read"

    let mailbox = mailbox.trimmingCharacters(in: .whitespaces)
    if !mailbox.isEmpty, mailbox.caseInsensitiveCompare(StandardFolder.inbox) != .orderedSame {
        components.queryItems = [URLQueryItem(name: "mailbox", value: mailbox)]
    }
    return components.url == nil ? nil : components
}

/// Builds the webmail URL that opens one mailbox — the compose handoff opens
/// Drafts after saving, because a client-protected key exists only in the
/// browser.
nonisolated func webmailMailboxURL(serverUrl: String, mailbox: String) -> URL? {
    webmailReadComponents(serverUrl: serverUrl, mailbox: mailbox)?.url
}

/// Builds the webmail URL that opens one specific message — the same `/read`
/// route a web push click uses, so no server change backs it.
nonisolated func webmailMessageURL(serverUrl: String, mailbox: String, messageId: String) -> URL? {
    guard !messageId.isBlank,
          var components = webmailReadComponents(serverUrl: serverUrl, mailbox: mailbox)
    else { return nil }
    components.queryItems = (components.queryItems ?? [])
        + [URLQueryItem(name: "message", value: messageId)]
    return components.url
}
```

In `KyPost/Domain/Repositories/MailRepository.swift`, add after `send`:

```swift
    /// Saves a draft on the server so the webmail handoff has something to
    /// open. Same failure mapping as `send`.
    func saveDraft(_ email: OutgoingEmail) async -> MailOutcome {
        do {
            try await makeSource().saveDraft(email: email)
            return .success
        } catch {
            return MailOutcome.from(error)
        }
    }

    /// The paired server's base URL, for building webmail links. Nil when
    /// unpaired, so callers show no link rather than a dead one.
    var pairedServerUrl: String? {
        guard let pairing = try? securePairingStore.loadPairing(),
              !pairing.srv.isEmpty
        else { return nil }
        return pairing.srv
    }
```

In `KyPost/Domain/UseCases/SendEmailUseCase.swift`, add after `callAsFunction`:

```swift
    /// Saves the composed message as a server-side draft, for the
    /// client-custody webmail handoff. No recipient requirement: a draft is
    /// allowed to be incomplete.
    func saveDraft(_ email: OutgoingEmail) async -> MailOutcome {
        await repository.saveDraft(email)
    }

    /// Webmail's Drafts view on the paired server, or nil when there is no
    /// usable pairing URL — compose then explains instead of linking.
    var webmailDraftsURL: URL? {
        repository.pairedServerUrl.flatMap {
            webmailMailboxURL(serverUrl: $0, mailbox: StandardFolder.drafts)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/MailTests' -only-testing:'KyPost Tests/PgpMessageStateTests'`
Expected: PASS, including the pre-existing `webmailMessageURL` tests in `PgpMessageStateTests` (the refactor must not change them).

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Data/Mail/MailSource.swift" "KyPost/Data/Mail/RelayMailSource.swift" \
        "KyPost/Domain/Models/PgpMessageState.swift" "KyPost/Domain/Repositories/MailRepository.swift" \
        "KyPost/Domain/UseCases/SendEmailUseCase.swift" \
        "KyPost Tests/MailTests.swift" "KyPost Tests/PgpMessageStateTests.swift"
git commit -m "pgp: add server-side draft save and the webmail Drafts link"
```

---

### Task 6: `PgpSendService` — session custody cache and preflight

**Files:**
- Create: `KyPost/Domain/UseCases/PgpSendService.swift`
- Modify: `KyPost/App/SingletonGraph.swift:47-57` (networking clients), `:58-112` (services)
- Test: `KyPost Tests/PgpSendTests.swift` (append)

**Interfaces:**
- Consumes: `PgpSendClient`, `PgpBootstrapResponse`, `PgpRecipientCheckDTO`, `keylessAddresses(in:)` (Task 2); `PgpKeyCustody`, `pgpKeyCustody(hasIdentity:protection:)` (Task 1); `SecurePairingStore`, `RelayAuth`.
- Produces: `@Observable @MainActor final class PgpSendService` with
  - `private(set) var custody: PgpKeyCustody?`
  - `func loadIfNeeded() async`
  - `func keylessRecipients(among addresses: [String]) async -> [String]`
  - `SingletonGraph.pgpSendClient`, `SingletonGraph.pgpSendService`

- [ ] **Step 1: Write the failing test**

Append to `KyPost Tests/PgpSendTests.swift`:

```swift
// MARK: - PgpSendService

@Suite @MainActor struct PgpSendServiceTests {
    private func makeService(
        paired: Bool = true,
        status: Int = 200,
        json: String = #"{"hasIdentity":true,"protection":"server"}"#,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) throws -> PgpSendService {
        PgpSendService(
            client: PgpSendClient(httpClient: stubClient(status: status, json: json, onRequest: onRequest)),
            securePairingStore: try makePairedStore(paired: paired)
        )
    }

    @Test func loadCachesCustodyForTheSession() async throws {
        let calls = Box(0)
        let service = try makeService { _ in calls.mutate { $0 += 1 } }

        #expect(service.custody == nil)
        await service.loadIfNeeded()
        #expect(service.custody == .serverHeld)

        // The mode is chosen at key creation and has no downgrade path, so one
        // fetch per session is the contract, not an optimisation.
        await service.loadIfNeeded()
        #expect(calls.value == 1)
    }

    /// An unreachable bootstrap must never block a plaintext send: custody
    /// stays nil and compose simply offers no PGP toggles.
    @Test func aFailedBootstrapLeavesCustodyUnknown() async throws {
        let service = try makeService(status: 503, json: "pairing secret unset")
        await service.loadIfNeeded()
        #expect(service.custody == nil)
    }

    @Test func withoutAPairingNothingIsFetched() async throws {
        let calls = Box(0)
        let service = try makeService(paired: false) { _ in calls.mutate { $0 += 1 } }
        await service.loadIfNeeded()
        #expect(service.custody == nil)
        #expect(calls.value == 0)
    }

    @Test func preflightReturnsTheAddressesWithNoUsableKey() async throws {
        let json = """
        {"results": [
          {"address": "alice@example.com", "hasKey": true},
          {"address": "bob@example.com", "hasKey": false}
        ]}
        """
        let service = try makeService(json: json)
        let keyless = await service.keylessRecipients(
            among: ["alice@example.com", "bob@example.com"]
        )
        #expect(keyless == ["bob@example.com"])
    }

    /// The preflight is advisory. A failure warns about nothing rather than
    /// blocking the send — the relay's 409 is the real gate.
    @Test func aFailedPreflightWarnsAboutNothing() async throws {
        let service = try makeService(status: 500, json: "boom")
        #expect(await service.keylessRecipients(among: ["bob@example.com"]).isEmpty)
    }

    @Test func anEmptyAddressListSkipsTheCallEntirely() async throws {
        let calls = Box(0)
        let service = try makeService { _ in calls.mutate { $0 += 1 } }
        #expect(await service.keylessRecipients(among: []).isEmpty)
        #expect(calls.value == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: FAIL — `cannot find 'PgpSendService' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `KyPost/Domain/UseCases/PgpSendService.swift`:

```swift
//
//  PgpSendService.swift
//  KyPost
//
//  What compose needs to know before offering encryption
//  (Client_Encrypted_Send.md "Required behavior" 1 and 3):
//    - the account's key custody, fetched once per session from
//      GET /api/pgp/bootstrap. The mode is chosen at key creation and has no
//      downgrade path, so it cannot change behind a session's back.
//    - the recipient key preflight, POST /api/pgp/recipients/check.
//
//  Both degrade quietly. A bootstrap failure leaves custody unknown and
//  compose offers no PGP toggles; a preflight failure warns about nothing. The
//  relay's 409 is the real gate either way.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class PgpSendService {
    private let client: PgpSendClient
    private let securePairingStore: SecurePairingStore

    /// Nil until a successful load: unknown, not "no identity". Compose shows
    /// no toggle while it is nil — better no toggle than one that lies.
    private(set) var custody: PgpKeyCustody?

    init(client: PgpSendClient, securePairingStore: SecurePairingStore) {
        self.client = client
        self.securePairingStore = securePairingStore
    }

    /// Loads key custody once per session. Cheap to call from every compose
    /// window's `.task`.
    func loadIfNeeded() async {
        guard custody == nil, let credentials = pairingCredentials else { return }
        do {
            let response = try await client.fetchBootstrap(
                serverUrl: credentials.serverUrl,
                auth: credentials.auth
            )
            custody = pgpKeyCustody(
                hasIdentity: response.hasIdentity,
                protection: response.protection
            )
        } catch {
            Log.mail.debug("PGP bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Addresses among `addresses` with no usable key **in the user's
    /// contacts**.
    ///
    /// A lower bound, never a promise: the send path also runs WKD and
    /// keyserver discovery, so an address returned here may still be encrypted
    /// to successfully. Word the warning as "no key on file", never as "this
    /// will be sent as a plaintext link".
    func keylessRecipients(among addresses: [String]) async -> [String] {
        guard !addresses.isEmpty, let credentials = pairingCredentials else { return [] }
        do {
            let results = try await client.checkRecipients(
                addresses,
                serverUrl: credentials.serverUrl,
                auth: credentials.auth
            )
            return keylessAddresses(in: results)
        } catch {
            Log.mail.debug("PGP recipient preflight failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private var pairingCredentials: (serverUrl: String, auth: RelayAuth)? {
        guard let pairing = try? securePairingStore.loadPairing(), !pairing.srv.isEmpty else {
            return nil
        }
        return (pairing.srv, RelayAuth(pairing: pairing))
    }
}
```

In `KyPost/App/SingletonGraph.swift`, add to the Networking section after `pgpQrClient`:

```swift
    lazy var pgpSendClient = PgpSendClient(httpClient: httpClient)
```

and to the Repositories & Use Cases section after `sendEmailUseCase`:

```swift
    lazy var pgpSendService = PgpSendService(
        client: pgpSendClient,
        securePairingStore: securePairingStore
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Domain/UseCases/PgpSendService.swift" "KyPost/App/SingletonGraph.swift" \
        "KyPost Tests/PgpSendTests.swift"
git commit -m "pgp: cache key custody per session and run the recipient preflight"
```

---

### Task 7: ComposeViewModel — toggles, confirmation, re-send, handoff

**Files:**
- Modify: `KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift:37-86` (state + init), `:311-352` (`send`)
- Modify: `KyPost Tests/ComposeRecipientTests.swift:28-63` (`makeEnvironment` gains the new dependency)
- Test: `KyPost Tests/PgpSendTests.swift` (append)

**Interfaces:**
- Consumes: `PgpSendService.custody` / `.loadIfNeeded()` / `.keylessRecipients(among:)` (Task 6); `MailOutcome.sentWithWarning` (Task 3); `MailOutcome.keylessRecipients` (Task 4); `SendEmailUseCase.saveDraft(_:)` / `.webmailDraftsURL` (Task 5); `OutgoingEmail.encrypt/.sign/.allowPickupFallback` (Task 3).
- Produces, on `ComposeViewModel`:
  - `init(sendEmail:contacts:pgp:draft:debounceInterval:)` — `pgp: PgpSendService` is required and unlabelled-position after `contacts`
  - `var encrypt: Bool`, `var sign: Bool`
  - `var pgpCustody: PgpKeyCustody?`
  - `private(set) var keylessWarning: [String]`, `var keylessWarningText: String?`
  - `private(set) var pendingPickup: PendingPickup?`, `var pickupConfirmationMessage: String`
  - `private(set) var noticeMessage: String?`, `private(set) var isSent: Bool`, `private(set) var webmailHandoffURL: URL?`
  - `func loadPgpIdentityIfNeeded() async`, `func confirmPickupFallback() async`, `func cancelPickupFallback()`, `func handOffToWebmail(fontTraits:) async`, `func didOpenWebmail()`
  - `struct PendingPickup: Identifiable` (`id`, `addresses`, `email`)

- [ ] **Step 1: Write the failing test**

Append to `KyPost Tests/PgpSendTests.swift`:

```swift
// MARK: - Compose: encrypted send flow

/// Answers by URL path, so one stub can serve a compose flow that hits
/// bootstrap, the preflight, and two sends. `sends` and `drafts` record every
/// body posted to /api/mail/send and /api/mail/draft in order.
@MainActor
private final class ComposeStub {
    let sends = Box<[String]>([])
    let drafts = Box<[String]>([])
    private let bootstrap: String
    private let check: String
    private let sendResponses: [(status: Int, json: String)]
    private let sendIndex = Box(0)

    init(
        bootstrap: String = #"{"hasIdentity":true,"protection":"server"}"#,
        check: String = #"{"results":[]}"#,
        sendResponses: [(status: Int, json: String)] = [(200, #"{"ok":true,"sentSaved":true}"#)]
    ) {
        self.bootstrap = bootstrap
        self.check = check
        self.sendResponses = sendResponses
    }

    func makeClient() -> HTTPClient {
        let sends = sends
        let drafts = drafts
        let sendIndex = sendIndex
        let bootstrap = bootstrap
        let check = check
        let sendResponses = sendResponses
        return HTTPClient { request in
            let path = request.url?.path ?? ""
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            var status = 200
            var json = "{}"
            switch path {
            case "/api/pgp/bootstrap":
                json = bootstrap
            case "/api/pgp/recipients/check":
                json = check
            case "/api/mail/draft":
                drafts.mutate { $0.append(body) }
                json = #"{"ok":true}"#
            case "/api/mail/send":
                sends.mutate { $0.append(body) }
                var current = 0
                sendIndex.mutate {
                    current = min($0, sendResponses.count - 1)
                    $0 = current + 1
                }
                status = sendResponses[current].status
                json = sendResponses[current].json
            default:
                json = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
    }
}

@MainActor
private func makeCompose(
    stub: ComposeStub,
    paired: Bool = true
) throws -> ComposeViewModel {
    let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let pairingStore = try makePairedStore(paired: paired)
    let db = try AppDatabase(inMemory: true)
    let client = stub.makeClient()
    let contacts = ContactsViewModel(repository: ContactSyncRepository(
        client: ContactSyncClient(httpClient: client),
        contactDAO: ContactDAO(modelContainer: db.container),
        cursorStore: ContactCursorStore(defaults: defaults),
        pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
        securePairingStore: pairingStore
    ))
    let mailRepository = MailRepository(
        securePairingStore: pairingStore,
        emailDAO: EmailDAO(modelContainer: db.container),
        httpClient: client
    )
    return ComposeViewModel(
        sendEmail: SendEmailUseCase(repository: mailRepository),
        contacts: contacts,
        pgp: PgpSendService(
            client: PgpSendClient(httpClient: client),
            securePairingStore: pairingStore
        ),
        debounceInterval: .zero
    )
}

private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }

@Suite @MainActor struct ComposeEncryptedSendTests {
    @Test func encryptAndSignTravelOnTheSendBody() async throws {
        let stub = ComposeStub()
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"
        compose.encrypt = true
        compose.sign = true

        await compose.send(fontTraits: noTraits)

        #expect(compose.didSend)
        #expect(stub.sends.value.count == 1)
        #expect(stub.sends.value[0].contains(#""encrypt":true"#))
        #expect(stub.sends.value[0].contains(#""sign":true"#))
        // The first send never volunteers consent.
        #expect(!stub.sends.value[0].contains("allowPickupFallback"))
    }

    @Test func theKeylessPreflightWarnsWithoutBlocking() async throws {
        let stub = ComposeStub(
            check: #"{"results":[{"address":"bob@example.com","hasKey":false}]}"#
        )
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        #expect(compose.keylessWarning == ["bob@example.com"])
        // Warned, and sent anyway: the preflight is contacts-only, so the send
        // path's WKD/keyserver discovery may still find a key.
        #expect(stub.sends.value.count == 1)
        #expect(compose.didSend)
    }

    @Test func noPreflightWhenEncryptIsOff() async throws {
        let stub = ComposeStub(
            check: #"{"results":[{"address":"bob@example.com","hasKey":false}]}"#
        )
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"

        await compose.send(fontTraits: noTraits)

        #expect(compose.keylessWarning.isEmpty)
        #expect(compose.didSend)
    }

    @Test func theKeylessConflictAsksBeforeSendingAnyLink() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [(409, conflict)])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        // Nothing was delivered and nothing was auto-confirmed.
        #expect(!compose.didSend)
        #expect(compose.pendingPickup?.addresses == ["bob@example.com"])
        #expect(compose.errorMessage == nil)
        let message = compose.pickupConfirmationMessage
        #expect(message.contains("bob@example.com"))
        #expect(message.contains("one-time link"))
        #expect(message.contains("unencrypted"))
        #expect(message.contains("7 days"))
        #expect(!message.contains("some recipients"))
    }

    @Test func cancellingSendsNothingMore() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [(409, conflict)])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true
        await compose.send(fontTraits: noTraits)

        compose.cancelPickupFallback()

        #expect(compose.pendingPickup == nil)
        #expect(stub.sends.value.count == 1)
        #expect(!compose.didSend)
    }

    /// The re-send must be the refused request with one flag flipped — not a
    /// rebuild, which risks a subtly different message.
    @Test func confirmingResendsTheIdenticalBodyPlusTheFlag() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let stub = ComposeStub(sendResponses: [
            (409, conflict),
            (200, #"{"ok":true,"sentSaved":true}"#),
        ])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.subject = "Quarterly"
        compose.body = AttributedString("plain words")
        compose.encrypt = true
        compose.sign = true
        await compose.send(fontTraits: noTraits)

        await compose.confirmPickupFallback()

        #expect(stub.sends.value.count == 2)
        let first = stub.sends.value[0]
        let second = stub.sends.value[1]
        #expect(second.contains(#""allowPickupFallback":true"#))
        // Identical apart from the flag.
        #expect(second.replacingOccurrences(of: #","allowPickupFallback":true"#, with: "") == first)
        #expect(compose.didSend)
        #expect(compose.pendingPickup == nil)
    }

    @Test func aServerWithPickupLinksOffExplainsInsteadOfAsking() async throws {
        let conflict = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":false}"#
        let stub = ComposeStub(sendResponses: [(409, conflict)])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "bob@example.com"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        #expect(compose.pendingPickup == nil)
        #expect(compose.errorMessage?.contains("bob@example.com") == true)
        #expect(!compose.didSend)
    }

    @Test func aWarningIsShownWithoutOfferingARetry() async throws {
        let stub = ComposeStub(sendResponses: [
            (200, #"{"ok":true,"sentSaved":false,"warning":"sent copy not saved"}"#),
        ])
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"

        await compose.send(fontTraits: noTraits)

        #expect(compose.noticeMessage == "sent copy not saved")
        #expect(compose.errorMessage == nil)
        // Sent: the window must not offer a send that would duplicate it, and
        // must not slam shut over the notice.
        #expect(compose.isSent)
        #expect(!compose.didSend)

        await compose.send(fontTraits: noTraits)
        #expect(stub.sends.value.count == 1)
    }

    @Test func theClientSideConflictSavesADraftAndHandsOffToWebmail() async throws {
        let stub = ComposeStub(
            bootstrap: #"{"hasIdentity":true,"protection":"client"}"#,
            sendResponses: [(409, #"{"clientSideNeeded":true}"#)]
        )
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"
        compose.subject = "Quarterly"
        compose.encrypt = true

        await compose.send(fontTraits: noTraits)

        #expect(stub.drafts.value.count == 1)
        #expect(stub.drafts.value[0].contains(#""subject":"Quarterly""#))
        // A draft carries no PGP flags.
        #expect(!stub.drafts.value[0].contains("encrypt"))
        #expect(compose.webmailHandoffURL?.absoluteString == "\(server)/read?mailbox=Drafts")
        #expect(compose.noticeMessage?.isEmpty == false)
        #expect(compose.isSent)
    }

    @Test func custodyDrivesWhetherTogglesAreOfferedAtAll() async throws {
        let serverHeld = try makeCompose(stub: ComposeStub())
        await serverHeld.loadPgpIdentityIfNeeded()
        #expect(serverHeld.pgpCustody == .serverHeld)

        let clientHeld = try makeCompose(stub: ComposeStub(
            bootstrap: #"{"hasIdentity":true,"protection":"client"}"#
        ))
        await clientHeld.loadPgpIdentityIfNeeded()
        #expect(clientHeld.pgpCustody == .clientHeld)

        let none = try makeCompose(stub: ComposeStub(bootstrap: #"{"hasIdentity":false}"#))
        await none.loadPgpIdentityIfNeeded()
        #expect(none.pgpCustody == .noIdentity)
    }

    /// The opt-in is per message. A fresh compose never starts consented.
    @Test func consentIsNeverRemembered() async throws {
        let compose = try makeCompose(stub: ComposeStub())
        #expect(!compose.encrypt)
        #expect(!compose.sign)
        #expect(compose.pendingPickup == nil)
    }

    @Test func theHandoffButtonSavesADraftAndOpensDrafts() async throws {
        let stub = ComposeStub(bootstrap: #"{"hasIdentity":true,"protection":"client"}"#)
        let compose = try makeCompose(stub: stub)
        compose.toInput = "alice@example.com"

        await compose.handOffToWebmail(fontTraits: noTraits)

        #expect(stub.drafts.value.count == 1)
        #expect(stub.sends.value.isEmpty)
        #expect(compose.webmailHandoffURL?.absoluteString == "\(server)/read?mailbox=Drafts")

        // The view clears it after opening, so it can't reopen on redraw.
        compose.didOpenWebmail()
        #expect(compose.webmailHandoffURL == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests'`
Expected: FAIL — `extra argument 'pgp' in call`, `value of type 'ComposeViewModel' has no member 'pendingPickup'`.

- [ ] **Step 3: Write minimal implementation**

In `KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift`, add above the class:

```swift
/// A send the relay refused because some recipients have no usable key.
///
/// Holds the exact `OutgoingEmail` that was refused: the re-send must be
/// byte-identical apart from `allowPickupFallback`, so nothing is rebuilt from
/// live compose state (Client_Encrypted_Send.md "Required behavior" 5).
struct PendingPickup: Identifiable {
    let id = UUID()
    var addresses: [String]
    var email: OutgoingEmail
}
```

Add the dependency and state to the class:

```swift
    private let pgp: PgpSendService
```

```swift
    /// PGP send flags. Fresh per compose window, and `allowPickupFallback` is
    /// never stored anywhere: the one-time-link opt-in is per message by
    /// design, and a remembered "always allow" was a specific review finding.
    var encrypt = false
    var sign = false

    /// Addresses the contacts-only preflight found no key for. A warning, not
    /// a prediction — the send path also runs WKD/keyserver discovery.
    private(set) var keylessWarning: [String] = []
    /// Set when the relay refused a send for keyless recipients; drives the
    /// confirmation dialog.
    private(set) var pendingPickup: PendingPickup?
    /// A non-failure notice: the relay's partial-success `warning`, or the
    /// webmail-handoff explanation.
    private(set) var noticeMessage: String?
    /// The message went out (or was handed off). Send stays disabled — a retry
    /// would duplicate it — but the window stays open so the notice is readable.
    private(set) var isSent = false
    /// Webmail URL for the view to open through `@Environment(\.openURL)`.
    /// Never route this into a WKWebView: it shares no session and would put
    /// an account-password field inside this app.
    private(set) var webmailHandoffURL: URL?
```

Extend `init` (add `pgp` after `contacts`, keeping the rest):

```swift
    init(
        sendEmail: SendEmailUseCase,
        contacts: ContactsViewModel,
        pgp: PgpSendService,
        draft: ComposeDraft? = nil,
        debounceInterval: Duration = .milliseconds(150)
    ) {
        self.sendEmail = sendEmail
        self.contacts = contacts
        self.pgp = pgp
        self.debounceInterval = debounceInterval
        if let draft { … unchanged … }
    }
```

Add a PGP section (place it after `loadContactsIfNeeded`):

```swift
    // MARK: - PGP

    /// Nil means "not known yet": compose offers no PGP controls rather than
    /// one that might lie.
    var pgpCustody: PgpKeyCustody? { pgp.custody }

    func loadPgpIdentityIfNeeded() async {
        await pgp.loadIfNeeded()
    }

    /// Inline, non-blocking warning text, worded as "no key on file" — never as
    /// a promise that a plaintext link will be sent, because the send path's
    /// discovery ladder may still find a key.
    var keylessWarningText: String? {
        guard !keylessWarning.isEmpty else { return nil }
        let names = keylessWarning.joined(separator: ", ")
        return "We don't have a PGP key on file for \(names). We'll still look one up when sending."
    }

    /// Verbatim from Client_Encrypted_Send.md — the wording carries the
    /// security property. Names every address; never "some recipients".
    var pickupConfirmationMessage: String {
        let names = (pendingPickup?.addresses ?? []).joined(separator: ", ")
        return """
        We don't have a PGP key for \(names). They'll get an email with a one-time link instead.

        To make that work, this message's contents are stored on your KyPost server — unencrypted — for up to 7 days or until the link is opened. Everyone else on this message still gets it encrypted.
        """
    }

    /// Confirmed the one-time-link fallback: re-sends the refused request,
    /// byte-identical apart from the flag. No preflight, no rebuild.
    func confirmPickupFallback() async {
        guard var email = pendingPickup?.email else { return }
        pendingPickup = nil
        email.allowPickupFallback = true
        await deliver(email)
    }

    func cancelPickupFallback() {
        pendingPickup = nil
    }

    /// Client-custody account: the key exists only in the user's browser, so
    /// save the composed message as a server-side draft and send them there.
    func handOffToWebmail(fontTraits: @escaping RichTextHTML.FontTraits) async {
        guard !isSending, !isSent else { return }
        for field in RecipientField.allCases where !commitPendingInput(for: field) {
            return
        }
        await handOff(draft: outgoingEmail(fontTraits: fontTraits))
    }

    /// Called by the view once it has opened `webmailHandoffURL`, so a redraw
    /// can't reopen the browser.
    func didOpenWebmail() {
        webmailHandoffURL = nil
    }
```

Replace `send(fontTraits:)` with:

```swift
    /// Sends the draft. `fontTraits` resolves bold/italic on body runs (from
    /// the view's font resolution context) so formatted text goes out as HTML.
    func send(fontTraits: @escaping RichTextHTML.FontTraits) async {
        guard !isSending, !isSent else { return }
        // A recipient typed but not committed is still a recipient the user
        // means to mail. Bail on invalid text rather than dropping it.
        for field in RecipientField.allCases where !commitPendingInput(for: field) {
            return
        }
        let email = outgoingEmail(fontTraits: fontTraits)
        if encrypt {
            keylessWarning = await pgp.keylessRecipients(
                among: email.to + email.cc + email.bcc
            )
        }
        await deliver(email)
    }

    /// Builds the request once. `send` and the pickup re-send share the same
    /// value: rebuilding risks a subtly different message.
    private func outgoingEmail(
        fontTraits: @escaping RichTextHTML.FontTraits
    ) -> OutgoingEmail {
        let isHTML = RichTextHTML.hasFormatting(body, fontTraits: fontTraits)
        return OutgoingEmail(
            to: to.map(\.address),
            cc: cc.map(\.address),
            bcc: bcc.map(\.address),
            subject: subject,
            body: isHTML
                ? RichTextHTML.htmlDocument(from: body, fontTraits: fontTraits)
                : String(body.characters),
            mode: isHTML ? "html" : "plain",
            attachments: attachments.map {
                OutgoingAttachment(name: $0.name, mimeType: $0.mimeType, data: $0.data)
            },
            encrypt: encrypt,
            sign: sign
        )
    }

    private func deliver(_ email: OutgoingEmail) async {
        isSending = true
        defer { isSending = false }

        switch await sendEmail(email) {
        case .success:
            didSend = true
            errorMessage = nil
        case .sentWithWarning(let warning):
            // Sent. Keep the window open so the notice is readable, and leave
            // Send disabled: a retry would duplicate the message.
            isSent = true
            errorMessage = nil
            noticeMessage = warning
        case .keylessRecipients(let addresses, let pickupFallbackAvailable):
            guard pickupFallbackAvailable else {
                errorMessage = """
                No usable PGP key for \(addresses.joined(separator: ", ")), and this server \
                doesn't offer one-time links. Remove them, or turn Encrypt off to send in the clear.
                """
                return
            }
            pendingPickup = PendingPickup(addresses: addresses, email: email)
            errorMessage = nil
        case .clientSideNeeded:
            // The account's key is held only by the browser. Nothing this
            // client retries can fix it, so hand off.
            await handOff(draft: email)
        case .invalid(let message):
            errorMessage = message
        case .unauthorized:
            errorMessage = "Not authorized — re-pair the device or check credentials."
        case .notPaired:
            errorMessage = "Pair this device before sending."
        case .failure(let message):
            errorMessage = message
        }
    }

    /// Saves the message as a server-side draft and points the view at
    /// webmail's Drafts view, where the browser holds the key.
    private func handOff(draft: OutgoingEmail) async {
        var draft = draft
        // A draft has no PGP semantics; RelaySendRequest drops the flags, but
        // keep the value honest for anything that inspects it later.
        draft.encrypt = false
        draft.sign = false
        draft.allowPickupFallback = false

        switch await sendEmail.saveDraft(draft) {
        case .success, .sentWithWarning:
            isSent = true
            errorMessage = nil
            guard let url = sendEmail.webmailDraftsURL else {
                noticeMessage = """
                This account's PGP key is held only by your browser, so it has to sign and \
                encrypt there. We saved this message to Drafts — couldn't work out this \
                server's web address, so open Drafts in your browser to finish sending it.
                """
                return
            }
            noticeMessage = """
            This account's PGP key is held only by your browser, so it has to sign and encrypt \
            there. We saved this message to Drafts and opened webmail to finish sending it.
            """
            webmailHandoffURL = url
        case .unauthorized:
            errorMessage = "Not authorized — re-pair the device or check credentials."
        case .notPaired:
            errorMessage = "Pair this device before sending."
        case .invalid(let message), .failure(let message):
            errorMessage = "Couldn't save this as a draft: \(message)"
        case .clientSideNeeded, .keylessRecipients:
            // A draft carries no PGP flags, so neither refusal is reachable.
            errorMessage = "Couldn't save this as a draft."
        }
    }
```

In `KyPost Tests/ComposeRecipientTests.swift`, extend `makeEnvironment` so it still compiles — build the service on the same stub client and pass it:

```swift
    let sendClient = stubClient(json: #"{"ok": true}"#, onRequest: onSend)
    let sendEmail = SendEmailUseCase(repository: MailRepository(
        securePairingStore: pairingStore,
        emailDAO: EmailDAO(modelContainer: db.container),
        httpClient: sendClient
    ))
    return Environment(
        viewModel: ComposeViewModel(
            sendEmail: sendEmail,
            contacts: contactsViewModel,
            pgp: PgpSendService(
                client: PgpSendClient(httpClient: sendClient),
                securePairingStore: pairingStore
            ),
            draft: draft,
            debounceInterval: .zero
        ),
        contacts: contactsViewModel
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS' -only-testing:'KyPost Tests/PgpSendTests' -only-testing:'KyPost Tests/ComposeRecipientTests'`
Expected: PASS. `ComposeView.swift` will fail to compile until Task 8 passes `pgp:` into the initializer — add `pgp: SingletonGraph.shared.pgpSendService` to `ComposeView.init` now so the target builds.

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Presentation/Shared/ViewModels/ComposeViewModel.swift" \
        "KyPost/Presentation/Screens/ComposeView.swift" \
        "KyPost Tests/ComposeRecipientTests.swift" "KyPost Tests/PgpSendTests.swift"
git commit -m "pgp: confirm keyless sends and hand client-held keys to webmail"
```

---

### Task 8: ComposeView — controls, warning, dialog, handoff

**Files:**
- Modify: `KyPost/Presentation/Screens/ComposeView.swift:29-51` (init), `:64-151` (`content`), `:153-172` (`headerFields`)

**Interfaces:**
- Consumes: every `ComposeViewModel` member from Task 7; `PgpKeyCustody` (Task 1).
- Produces: no new API. UI only.

- [ ] **Step 1: Write the failing test**

There is no snapshot harness in this repo and focus/overlay behavior is not unit-testable (`KyPost/Presentation/AGENTS.md` Verification). The logic this task renders — dialog copy, warning text, custody gating, notice — is covered by `ComposeEncryptedSendTests` from Task 7. So the check here is that the full suite still passes and the app runs.

Run the full suite first to establish the baseline:

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS (this is the pre-change baseline, not a failing test).

- [ ] **Step 2: Add the PGP controls**

In `ComposeView.init`, pass the service (if Task 7 didn't already):

```swift
    init(draft: ComposeDraft? = nil) {
        _viewModel = State(initialValue: ComposeViewModel(
            sendEmail: SingletonGraph.shared.sendEmailUseCase,
            contacts: SingletonGraph.shared.contactsViewModel,
            pgp: SingletonGraph.shared.pgpSendService,
            draft: draft
        ))
    }
```

Add to `content`, between `headerFields` and the `Divider`:

```swift
            pgpControls
                .padding(.horizontal)
                .padding(.bottom, 8)
```

and add the view:

```swift
    // MARK: - PGP

    /// Toggles only for a server-custody account. A client-custody account
    /// gets the webmail handoff instead — this app holds no private key and
    /// must never let the user believe an encrypted send succeeded from here.
    @ViewBuilder
    private var pgpControls: some View {
        switch viewModel.pgpCustody {
        case .serverHeld:
            HStack(spacing: 16) {
                Toggle("Encrypt", isOn: $viewModel.encrypt)
                Toggle("Sign", isOn: $viewModel.sign)
                Spacer(minLength: 0)
            }
            .font(AppFont.ui(12, weight: .medium))
            .foregroundStyle(theme.ink)
        case .clientHeld:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(theme.ink.opacity(0.7))
                Text("This account's PGP key is held only by your browser, so signing and encryption happen there.")
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Encrypt in webmail…") {
                    Task { await viewModel.handOffToWebmail(fontTraits: fontTraits) }
                }
                .font(AppFont.ui(12, weight: .medium))
                .buttonStyle(.borderless)
                .disabled(viewModel.isSending || viewModel.isSent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
        case .noIdentity, .none:
            EmptyView()
        }
    }
```

- [ ] **Step 3: Add the warning, the notice, and the confirmation dialog**

In `content`, replace the trailing `errorMessage` block with the three messages, error last:

```swift
            if let warning = viewModel.keylessWarningText {
                messageLine(warning, color: theme.ink)
            }

            if let notice = viewModel.noticeMessage {
                messageLine(notice, color: theme.ink)
            }

            if let message = viewModel.errorMessage {
                messageLine(message, color: SemanticColors.danger)
            }
```

and add:

```swift
    private func messageLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppFont.ui(13))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }
```

Add the dialog and the handoff to `content`'s modifier chain (next to the existing `.sheet`):

```swift
        // Copy is verbatim from Client_Encrypted_Send.md — the wording carries
        // the security property. Cancel is the default action; the confirm
        // button is destructive because it puts plaintext on the server.
        .confirmationDialog(
            "Send an unencrypted link?",
            isPresented: Binding(
                get: { viewModel.pendingPickup != nil },
                set: { if !$0 { viewModel.cancelPickupFallback() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Send link anyway", role: .destructive) {
                Task { await viewModel.confirmPickupFallback() }
            }
            Button("Cancel", role: .cancel) { viewModel.cancelPickupFallback() }
        } message: {
            Text(viewModel.pickupConfirmationMessage)
        }
        // The handoff opens the user's browser, never an in-app web view: it
        // shares no session and would put an account-password field in here
        // (kypost-server docs/E2E_PGP.md requirement 5).
        .onChange(of: viewModel.webmailHandoffURL) {
            if let url = viewModel.webmailHandoffURL {
                openURL(url)
                viewModel.didOpenWebmail()
            }
        }
        .task { await viewModel.loadPgpIdentityIfNeeded() }
```

Add the environment value at the top of the struct, beside the others:

```swift
    @Environment(\.openURL) private var openURL
```

Disable Send once the message is out, in `toolbarContent`'s confirmation action:

```swift
            .disabled(viewModel.isSending || viewModel.isSent)
```

- [ ] **Step 4: Run the suite and the app**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS, whole suite.

Then drive the real window (`⌘N` → *New Email*) and confirm by looking at it:
- a server-custody account shows Encrypt/Sign; a client-custody one shows the handoff row and no toggles; an account with no identity shows neither
- the confirmation dialog opens with the exact copy, names the address, and Cancel is the default
- after a warning send, the window stays open with the notice and Send is disabled

Note the toggles will only render once the server branch is deployed — until `feat/mobile-encrypted-send` lands, `/api/pgp/bootstrap` 404s, custody stays nil, and the row is correctly empty. To see the UI before then, temporarily hard-code `custody = .serverHeld` in `PgpSendService.init` and revert before committing.

- [ ] **Step 5: Commit**

```bash
git add "KyPost/Presentation/Screens/ComposeView.swift"
git commit -m "pgp: surface encrypt/sign, the keyless confirmation, and the handoff in compose"
```

---

### Task 9: Documentation

**Files:**
- Modify: `KyPost/Presentation/AGENTS.md` (Local Contracts)
- Modify: `README.md:14-20` (features), `:58-65` (wire contracts), `:79-86` (known gaps), `:88-90` (license)

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Record the compose contracts**

Append to the Local Contracts list in `KyPost/Presentation/AGENTS.md`, after the existing PGP bullet:

```markdown
- Encrypted send is decided by key custody, not by hope.
  `Domain/Models/PgpKeyCustody.swift` maps `/api/pgp/bootstrap` to
  `serverHeld` / `clientHeld` / `noIdentity`, and anything unrecognised
  degrades to `clientHeld`. Compose shows Encrypt/Sign **only** for
  `serverHeld`; `clientHeld` gets the webmail handoff (save a draft, then
  `openURL` — never a `WKWebView`), and a nil custody shows nothing at all.
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
```

- [ ] **Step 2: Update the README**

Add a feature bullet after the encryption-state bullet (line 20):

```markdown
- **Encrypted and signed send** — for accounts whose key the server holds, Encrypt/Sign travel with the message and the relay does the OpenPGP work. When a recipient has no usable key the relay refuses first and asks: confirming mails them a one-time link and stores that message's plaintext on your server for up to 7 days, named recipients and all. Accounts whose key only the browser can unwrap can't encrypt from here at all — the draft is saved server-side and webmail takes over.
```

Add to the wire-contracts list after `POST /api/mail/send` (line 61):

```markdown
- `POST /api/mail/draft` — save a draft (same body shape as send, no PGP flags)
- `GET /api/pgp/bootstrap` — this account's key custody (`hasIdentity`, `protection`)
- `POST /api/pgp/recipients/check` — contacts-only recipient key preflight (never `/resolve`)
```

Replace the "Drafts saved to the server" known gap (line 84) with:

```markdown
- Drafts UI — drafts can be saved to the server (the encrypted-send handoff does), but there's no drafts folder or auto-save
```

Fix the license line (line 90), stale since the GPL v3 relicense:

```markdown
GPL-3.0 — see [LICENSE.txt](LICENSE.txt).
```

- [ ] **Step 3: Verify**

Run: `xcodebuild test -scheme "KyPost" -destination 'platform=macOS'`
Expected: PASS, whole suite (docs-only change; this confirms nothing regressed across the branch).

- [ ] **Step 4: Commit**

```bash
git add "KyPost/Presentation/AGENTS.md" README.md
git commit -m "docs: record the encrypted-send contracts"
```

---

## Self-Review

**1. Spec coverage** — every section of `Client_Encrypted_Send.md` maps to a task:

| Spec | Task |
|---|---|
| Prerequisite: server not deployed | Global Constraints; Task 8 Step 4 note |
| Scope / never hold a private key | Global Constraints; Task 1 comments |
| Two key-custody modes | Task 1 |
| `GET /api/pgp/bootstrap`, ignore extra fields | Task 2, Task 6 |
| `POST /api/pgp/recipients/check` | Task 2, Task 6 |
| `POST /api/mail/send` + three flags | Task 3 |
| 200 `warning` | Task 3 (transport), Task 7 (`noticeMessage`), Task 8 (render) |
| 409 `clientSideNeeded` | Task 4 (mapping), Task 7 (`handOff`) |
| 409 `keylessRecipients` + `pickupFallbackAvailable` | Task 4, Task 7 |
| 502 / 400 / 503 / 401 / 429 | Unchanged `NetworkError.from` → `MailOutcome.failure`/`.unauthorized`; Task 4 test `anUnrelatedConflictStaysAGenericFailure` and Task 5 `saveDraftSurfacesAPlainTextFailure` pin the plain-text paths |
| Trap 1: never `/resolve` | Global Constraints; Task 2 header comment + test comment |
| Trap 2: `check` is a lower bound | Task 2 `keylessAddresses` doc, Task 6 doc, Task 7 `keylessWarningText`, Task 9 |
| Trap 3: pickup stores plaintext 7 days | Task 7 `pickupConfirmationMessage`, Task 8 dialog, Task 9 |
| Behavior 1 (bootstrap on launch) | Task 6 + Task 8 `.task`. **Deliberate deviation:** the fetch is lazy-once from compose's `.task` rather than app launch. Same "once per session, before any toggle is offered" guarantee, one call site, no launch-order coupling. |
| Behavior 2 (toggles / hide for client) | Task 8 `pgpControls` |
| Behavior 3 (preflight, inline warning) | Task 7 `send`, Task 8 warning line |
| Behavior 4 (send with flags, fallback false) | Task 3 + Task 7 |
| Behavior 5 (confirm, default cancel, byte-identical re-send) | Task 7 + Task 8 |
| Behavior 6 (draft + webmail, build `/api/mail/draft`) | Task 5 + Task 7 |
| Behavior 7 (200 warning notice) | Task 7 + Task 8 |
| Behavior 8 (discriminate by field) | Task 4 `conflictError` |
| Confirmation dialog copy | Task 7 `pickupConfirmationMessage` (verbatim), Task 8 title/buttons |
| Do not build (OpenPGP, `/pgp/pickup`, `/send-pgp`, remembered preference) | Global Constraints; Task 7 comments; test `consentIsNeverRemembered` |
| Required test coverage list | Task 4 (both 409 shapes, neither-field fallback, malformed body), Task 7 (re-send flag + identical body, warning is success) |

**2. Placeholder scan** — no TBD/TODO, no "add error handling", no "similar to Task N". Every code step carries the actual code; every test step carries the actual test. The one step without a code block is Task 8 Step 1, which explains *why* (no snapshot harness) and names the tests that cover the logic instead.

**3. Type consistency** — `PgpKeyCustody` cases (`noIdentity`/`serverHeld`/`clientHeld`) are spelled identically in Tasks 1, 6, 7, 8, 9. `pgpKeyCustody(hasIdentity:protection:)`, `keylessAddresses(in:)`, `webmailMailboxURL(serverUrl:mailbox:)`, `conflictError(body:)`, `saveDraft(email:)` (source) vs `saveDraft(_:)` (repository/use case), `keylessRecipients(among:)` (service) vs `MailOutcome.keylessRecipients(addresses:pickupFallbackAvailable:)` keep their exact labels across tasks. `PendingPickup` is `Identifiable` and deliberately **not** `Equatable` (`OutgoingEmail` isn't), so tests compare `pendingPickup?.addresses` rather than the whole value. `MailSource.send` returns `String` with `@discardableResult` on both the protocol requirement and the `RelayMailSource` implementation, so the existing statement-position calls in `MailTests.swift` keep compiling.

**Known ordering constraint:** Tasks 3 → 4 → 5 all edit `RelayMailSource.swift` and `MailSource.swift` and must run in order. Tasks 3 and 4 each leave `ComposeViewModel`'s `switch` non-exhaustive; both steps say to add a temporary arm so the target builds, and Task 7 replaces it. Task 7 breaks `ComposeView`'s initializer until Task 8's first edit, which is why Task 7 Step 4 adds the `pgp:` argument early. Tasks 1, 2 and 6 are independent of 3–5 and could run in parallel with them; 7 needs all of 1–6.
