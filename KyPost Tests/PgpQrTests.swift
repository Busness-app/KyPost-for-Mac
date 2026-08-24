//
//  PgpQrTests.swift
//  KyPost Tests
//
//  Phase C tests: the PGP QR key-exchange client, payload validation, QR
//  rendering, and the two ViewModels' per-endpoint error mapping
//  (Client_PGP_Update.md).
//

import CoreGraphics
import Foundation
import Testing
@testable import KyPost

// MARK: - Helpers


private nonisolated let tokenJSON = #"""
{
  "token": "tok-abc",
  "expiresAt": "2026-07-15T10:02:00Z",
  "url": "https://mail.example.com/api/pgp/qr/key?t=tok-abc"
}
"""#

/// A structurally valid synthetic v4 key (13-byte public-key packet) whose
/// fingerprint field matches the locally computed value — the scan flow
/// verifies that since the fingerprint hardening (see PgpFingerprintTests
/// for the packet layout).
let syntheticArmoredKey = """
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: KyPostTest

xg0EYAAAAAEACQEjAAID
=ABCD
-----END PGP PUBLIC KEY BLOCK-----
"""
let syntheticKeyFingerprint = "6853864FF482DCF29CD0CB0E56CD3B5CB8625680"

private nonisolated let keyJSON = #"""
{
  "name": "Ada Lovelace",
  "fingerprint": "6853864FF482DCF29CD0CB0E56CD3B5CB8625680",
  "publicKey": "-----BEGIN PGP PUBLIC KEY BLOCK-----\nVersion: KyPostTest\n\nxg0EYAAAAAEACQEjAAID\n=ABCD\n-----END PGP PUBLIC KEY BLOCK-----"
}
"""#

// MARK: - Client

@Suite struct PgpQrClientTests {
    @Test func fetchTokenSendsPairingAuthToTheTokenEndpoint() async throws {
        let capture = Box<URLRequest?>(nil)
        let client = PgpQrClient(httpClient: stubClient(json: tokenJSON) { capture.value = $0 })

        _ = try await client.fetchToken(
            serverUrl: "https://mail.example.com",
            auth: RelayAuth(deviceId: "u1", deviceSecret: "h1")
        )

        let request = try #require(capture.value)
        // Pairing auth now travels as headers, not query params (server prefers
        // headers; the app has no web session cookie either way).
        #expect(request.url?.absoluteString == "https://mail.example.com/api/pgp/qr/token")
        #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
        #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        #expect(request.httpMethod == "GET")
    }

    @Test func fetchTokenDecodesTheMintedCode() async throws {
        let client = PgpQrClient(httpClient: stubClient(json: tokenJSON))
        let response = try await client.fetchToken(
            serverUrl: "https://mail.example.com",
            auth: RelayAuth(deviceId: "u1", deviceSecret: "h1")
        )

        #expect(response.token == "tok-abc")
        #expect(response.url == "https://mail.example.com/api/pgp/qr/key?t=tok-abc")
        // Go formats with time.RFC3339 — no fractional seconds.
        #expect(response.expiresAtDate == Date(timeIntervalSince1970: 1_784_109_720))
    }

    @Test func expiresAtDateToleratesFractionalSecondsAndRejectsGarbage() {
        let fractional = PgpQrTokenResponse(
            token: "t", expiresAt: "2026-07-15T10:02:00.500Z", url: "u"
        )
        #expect(fractional.expiresAtDate != nil)

        let garbage = PgpQrTokenResponse(token: "t", expiresAt: "not a date", url: "u")
        #expect(garbage.expiresAtDate == nil)
    }

    @Test func fetchKeyHitsTheScannedURLVerbatimWithNoAuth() async throws {
        let capture = Box<URLRequest?>(nil)
        let client = PgpQrClient(httpClient: stubClient(json: keyJSON) { capture.value = $0 })
        let scanned = try #require(URL(string: "https://mail.example.com/api/pgp/qr/key?t=tok-abc"))

        let key = try await client.fetchKey(from: scanned)

        let request = try #require(capture.value)
        #expect(request.url == scanned)
        // The ?t= token is the only credential; attaching pairing auth here
        // would leak this device's credentials to someone else's server.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(key.name == "Ada Lovelace")
        #expect(key.fingerprint == syntheticKeyFingerprint)
        #expect(key.publicKey.hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))
    }
}

// MARK: - Scanned payload validation

@Suite struct PgpQrPayloadTests {
    @Test func acceptsAWellFormedKeyURL() throws {
        let url = try #require(
            PgpQrClient.keyURL(fromScannedPayload: "https://mail.example.com/api/pgp/qr/key?t=abc")
        )
        #expect(url.absoluteString == "https://mail.example.com/api/pgp/qr/key?t=abc")
    }

    @Test func acceptsAServerHostedUnderASubpath() throws {
        let url = try #require(
            PgpQrClient.keyURL(fromScannedPayload: "https://ex.com/llama/api/pgp/qr/key?t=abc")
        )
        #expect(url.path == "/llama/api/pgp/qr/key")
    }

    @Test func toleratesSurroundingWhitespaceFromAPastedLink() {
        #expect(
            PgpQrClient.keyURL(
                fromScannedPayload: "  https://ex.com/api/pgp/qr/key?t=abc\n"
            ) != nil
        )
    }

    @Test(arguments: [
        // http: the token is a bearer credential in the query string.
        "http://mail.example.com/api/pgp/qr/key?t=abc",
        // Right shape, wrong endpoint.
        "https://mail.example.com/api/pgp/qr/token?t=abc",
        // Missing / empty token.
        "https://mail.example.com/api/pgp/qr/key",
        "https://mail.example.com/api/pgp/qr/key?t=",
        // Another app's QR code entirely.
        "kypost://native-pair?sub=1&hash=2",
        "https://example.com",
        "not a url at all",
        "",
    ])
    func rejectsAnythingElse(payload: String) {
        #expect(PgpQrClient.keyURL(fromScannedPayload: payload) == nil)
    }
}

// MARK: - QR rendering

@Suite struct QRCodeGeneratorTests {
    @Test func rendersASquareImageForAURL() throws {
        let image = try #require(
            QRCodeGenerator.cgImage(for: "https://mail.example.com/api/pgp/qr/key?t=abc")
        )
        #expect(image.width == image.height)
        #expect(image.width > 0)
    }

    @Test func scalesDeterministically() throws {
        let payload = "https://mail.example.com/api/pgp/qr/key?t=abc"
        let small = try #require(QRCodeGenerator.cgImage(for: payload, scale: 1))
        let large = try #require(QRCodeGenerator.cgImage(for: payload, scale: 10))
        #expect(large.width == small.width * 10)
        // Same input, same output — the countdown re-renders constantly.
        let again = try #require(QRCodeGenerator.cgImage(for: payload, scale: 10))
        #expect(again.width == large.width)
    }

    @Test func rendersEvenAnEmptyString() {
        #expect(QRCodeGenerator.cgImage(for: "") != nil)
    }
}

// MARK: - My QR Code view model

@Suite @MainActor struct MyPgpQrViewModelTests {
    private func makeViewModel(
        status: Int = 200,
        json: String = tokenJSON,
        paired: Bool = true
    ) throws -> MyPgpQrViewModel {
        MyPgpQrViewModel(
            client: PgpQrClient(httpClient: stubClient(status: status, json: json)),
            pairingStore: try makePairedStore(paired: paired)
        )
    }

    @Test func showsTheCodeOnSuccess() async throws {
        let viewModel = try makeViewModel()
        await viewModel.refresh()

        guard case .showing(let urlString, let expiresAt) = viewModel.state else {
            Issue.record("Expected .showing, got \(viewModel.state)")
            return
        }
        #expect(urlString == "https://mail.example.com/api/pgp/qr/key?t=tok-abc")
        #expect(expiresAt == Date(timeIntervalSince1970: 1_784_109_720))
    }

    @Test func withoutAPairingItAsksForPairingAndNeverCallsTheServer() async throws {
        let capture = Box<URLRequest?>(nil)
        let viewModel = MyPgpQrViewModel(
            client: PgpQrClient(httpClient: stubClient(json: tokenJSON) { capture.value = $0 }),
            pairingStore: try makePairedStore(paired: false)
        )

        await viewModel.refresh()

        #expect(viewModel.state == .needsPairing)
        #expect(capture.value == nil)
    }

    // Each status is unambiguous on /token even though NetworkError is lossy:
    // 401 is the only status it collapses, since /token cannot return 403.
    @Test func mapsRejectedCredentialsToPairingRejected() async throws {
        let viewModel = try makeViewModel(status: 401)
        await viewModel.refresh()
        #expect(viewModel.state == .pairingRejected)
    }

    @Test func mapsMissingPgpIdentityToItsOwnState() async throws {
        let viewModel = try makeViewModel(status: 400)
        await viewModel.refresh()
        #expect(viewModel.state == .noPgpIdentity)
    }

    @Test func mapsServiceUnavailableToUnavailable() async throws {
        let viewModel = try makeViewModel(status: 503)
        await viewModel.refresh()
        #expect(viewModel.state == .unavailable)
    }

    @Test func anUnreadableExpiryFailsRatherThanShowingACodeThatNeverExpires() async throws {
        let viewModel = try makeViewModel(
            json: #"{"token": "t", "expiresAt": "whenever", "url": "https://x/api/pgp/qr/key?t=t"}"#
        )
        await viewModel.refresh()

        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }
    }

    @Test func countdownCountsDownAndOnlyExistsWhileACodeIsShown() async throws {
        let viewModel = try makeViewModel()
        #expect(viewModel.secondsRemaining == nil)

        await viewModel.refresh()
        // The stub's expiry is a fixed past date, so it floors at zero rather
        // than going negative.
        #expect(viewModel.secondsRemaining == 0)
    }
}

// MARK: - Scan view model

@Suite @MainActor struct ScanPgpKeyViewModelTests {
    private struct Environment {
        let viewModel: ScanPgpKeyViewModel
        let repository: ContactSyncRepository
        let dao: ContactDAO
        let database: AppDatabase
    }

    private func makeEnvironment(
        status: Int = 200,
        json: String = keyJSON,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) throws -> Environment {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let dao = ContactDAO(modelContainer: db.container)
        let http = stubClient(status: status, json: json, onRequest: onRequest)
        let repository = ContactSyncRepository(
            client: ContactSyncClient(httpClient: http),
            contactDAO: dao,
            cursorStore: ContactCursorStore(defaults: defaults),
            pendingDeletesStore: ContactPendingDeletesStore(defaults: defaults),
            securePairingStore: pairingStore
        )
        return Environment(
            viewModel: ScanPgpKeyViewModel(
                client: PgpQrClient(httpClient: http),
                repository: repository
            ),
            repository: repository,
            dao: dao,
            database: db
        )
    }

    @Test func aValidCodeFetchesTheKeyAndAsksForFingerprintConfirmation() async throws {
        let env = try makeEnvironment()
        await env.viewModel.handleScannedPayload(
            "https://mail.example.com/api/pgp/qr/key?t=abc"
        )

        guard case .confirming(let key) = env.viewModel.state else {
            Issue.record("Expected .confirming, got \(env.viewModel.state)")
            return
        }
        #expect(key.name == "Ada Lovelace")
        // The displayed fingerprint is the locally computed one.
        #expect(key.fingerprint == syntheticKeyFingerprint)
    }

    /// A relay pairing a real key with an unrelated fingerprint string is
    /// exactly the attack the local computation exists to catch — refuse,
    /// never fall back to displaying the claim.
    @Test func aFingerprintClaimMismatchRefusesTheKey() async throws {
        let lying = keyJSON.replacingOccurrences(
            of: syntheticKeyFingerprint,
            with: "AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555"
        )
        let env = try makeEnvironment(json: lying)

        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")

        guard case .failed(let message, _) = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
        #expect(message.contains("doesn't match"))
    }

    @Test func anUnparseableKeyIsRefused() async throws {
        let garbage = #"{"name": "Ada", "fingerprint": "", "publicKey": "not armored"}"#
        let env = try makeEnvironment(json: garbage)

        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")

        guard case .failed = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
    }

    @Test func aNonKeyQRCodeFailsWithoutTouchingTheNetwork() async throws {
        let capture = Box<URLRequest?>(nil)
        let env = try makeEnvironment { capture.value = $0 }

        await env.viewModel.handleScannedPayload("https://example.com/something-else")

        guard case .failed(_, let canRescan) = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
        #expect(canRescan)
        #expect(capture.value == nil)
    }

    // /key has no auth middleware, so .unauthorized here can only be its 403.
    @Test func mapsAnExpiredTokenToARescannableFailure() async throws {
        let env = try makeEnvironment(status: 403)
        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")

        guard case .failed(let message, let canRescan) = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
        #expect(message.contains("expired"))
        #expect(canRescan)
    }

    @Test func mapsAKeylessAccountTo404() async throws {
        let env = try makeEnvironment(status: 404)
        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")

        guard case .failed(let message, let canRescan) = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
        #expect(message.contains("haven't set up"))
        #expect(canRescan)
    }

    @Test func serviceUnavailableOffersNoRescanBecauseRescanningCannotFixIt() async throws {
        let env = try makeEnvironment(status: 503)
        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")

        guard case .failed(_, let canRescan) = env.viewModel.state else {
            Issue.record("Expected .failed, got \(env.viewModel.state)")
            return
        }
        #expect(!canRescan)
    }

    @Test func attachingToAnExistingContactSetsThePgpKeyAndQueuesItForSync() async throws {
        let env = try makeEnvironment()
        var ada = Contact(name: "Ada Lovelace", createdAt: Date(), updatedAt: Date())
        ada.emails = [ContactLabeledValue(label: nil, value: "ada@example.com")]
        try await env.repository.saveContact(ada)

        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")
        guard case .confirming(let key) = env.viewModel.state else {
            Issue.record("Expected .confirming, got \(env.viewModel.state)")
            return
        }
        await env.viewModel.attach(to: ada, key: key)

        #expect(env.viewModel.state == .saved("Ada Lovelace"))
        let pending = try await env.dao.listPendingSync()
        let saved = try #require(pending.first { $0.name == "Ada Lovelace" })
        #expect(saved.pgpKey == key.publicKey)
        #expect(saved.needsSync)
    }

    @Test func attachingWithNoContactCreatesOneNamedAfterTheKeysOwner() async throws {
        let env = try makeEnvironment()
        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")
        guard case .confirming(let key) = env.viewModel.state else {
            Issue.record("Expected .confirming, got \(env.viewModel.state)")
            return
        }

        await env.viewModel.attach(to: nil, key: key)

        #expect(env.viewModel.state == .saved("Ada Lovelace"))
        let pending = try await env.dao.listPendingSync()
        let created = try #require(pending.first { $0.name == "Ada Lovelace" })
        #expect(created.pgpKey == key.publicKey)
        #expect(created.uid == nil)
    }

    @Test func theAttachedKeyReachesTheServerOnTheNextPush() async throws {
        let capture = Box<URLRequest?>(nil)
        let env = try makeEnvironment(json: keyJSON) { request in
            if request.httpMethod == "POST" { capture.value = request }
        }
        await env.viewModel.handleScannedPayload("https://mail.example.com/api/pgp/qr/key?t=abc")
        guard case .confirming(let key) = env.viewModel.state else {
            Issue.record("Expected .confirming, got \(env.viewModel.state)")
            return
        }
        await env.viewModel.attach(to: nil, key: key)

        // The sync response decodes as an empty delta; we only care about the
        // body that went up.
        _ = try? await env.repository.sync()

        let body = try #require(capture.value?.httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains("\"pgpKey\""))
        #expect(json.contains("BEGIN PGP PUBLIC KEY BLOCK"))
    }

    @Test func rescanClearsThePastedLinkSoTheOldOneIsNotResubmitted() async throws {
        let env = try makeEnvironment(status: 403)
        env.viewModel.pastedLink = "https://mail.example.com/api/pgp/qr/key?t=stale"
        await env.viewModel.submitPastedLink()

        env.viewModel.rescan()

        #expect(env.viewModel.state == .scanning)
        #expect(env.viewModel.pastedLink.isEmpty)
    }
}

// MARK: - Fingerprint formatting

@Suite struct FingerprintFormattingTests {
    @Test func groupsIntoFoursForReadingAloud() {
        #expect(
            ScanPgpKeyView.groupedFingerprint("ABCD1234EF567890")
                == "ABCD 1234 EF56 7890"
        )
    }

    @Test func regroupsAnAlreadySpacedFingerprint() {
        #expect(ScanPgpKeyView.groupedFingerprint("AB CD12 34") == "ABCD 1234")
    }

    @Test func handlesARaggedTailAndEmptyInput() {
        #expect(ScanPgpKeyView.groupedFingerprint("ABCDE") == "ABCD E")
        #expect(ScanPgpKeyView.groupedFingerprint("") == "")
    }
}
