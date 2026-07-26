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
