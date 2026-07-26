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
