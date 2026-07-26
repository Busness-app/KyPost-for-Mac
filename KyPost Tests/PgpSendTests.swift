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
