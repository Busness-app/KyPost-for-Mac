//
//  PgpPayloadClient.swift
//  KyPost
//
//  GET {srv}/api/mail/pgp-payload — one client-protected message's OpenPGP
//  material. Swift port of kypost-android's pgp/PgpPayloadClient.kt.
//
//  The three specific status codes map to distinct results rather than one
//  failure, because each is a different row of the reader's exit table and a
//  different sentence to the user. Collapsing them would tell someone whose
//  message is merely too large that the server could not be reached.
//

import Foundation

/// Wire shape. Every field defaults, and the defaults **are** the contract for
/// an older server: each is `omitempty` server-side.
private struct PgpPayloadDTO: Decodable {
    var encryptedPayload: String = ""
    var signaturePayload: String = ""
    var body: String = ""
    var signerKeys: [SignerKeyDTO] = []
    var sender: String = ""
    var resolvedSender: String = ""
}

private struct SignerKeyDTO: Decodable {
    var addresses: [String] = []
    var publicKey: String = ""
    /// `false` is the safe direction for both of these: it weakens a claim
    /// rather than inventing one. A missing `verified` must never read as
    /// "the user confirmed this key".
    var verified: Bool = false
    var source: String = ""
    var conflict: Bool = false
}

final class PgpPayloadClient: PgpPayloadSource {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    /// - Returns: a result for every documented outcome. Only an undocumented
    ///   status or a transport error becomes `.failed`.
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult {
        guard var components = URLComponents(string: serverUrl) else {
            return .failed("the server address is not a valid URL")
        }
        components.path = (components.path as NSString)
            .appendingPathComponent("api/mail/pgp-payload")
        components.queryItems = [
            URLQueryItem(name: "mailbox", value: mailbox),
            URLQueryItem(name: "message", value: messageId),
        ]
        guard let url = components.url else {
            return .failed("the server address is not a valid URL")
        }

        do {
            let dto = try await httpClient.get(
                PgpPayloadDTO.self,
                url: url,
                headers: auth.headerFields
            )
            return .success(PgpPayload(
                encryptedPayload: dto.encryptedPayload,
                signaturePayload: dto.signaturePayload,
                body: dto.body,
                signerKeys: dto.signerKeys.map {
                    SignerKey(
                        addresses: $0.addresses,
                        publicKey: $0.publicKey,
                        verified: $0.verified,
                        source: $0.source,
                        conflict: $0.conflict
                    )
                },
                resolvedSender: dto.resolvedSender,
                rawSender: dto.sender
            ))
        } catch {
            return Self.result(for: error)
        }
    }

    /// Maps transport failures onto the exit table.
    ///
    /// `.conflict` (409) means this account's key is not client-protected —
    /// reaching here at all is a bug, but it gets its own row rather than a
    /// generic failure so the bug is legible when it happens.
    static func result(for error: Error) -> PgpPayloadResult {
        switch error {
        case NetworkError.server(statusCode: 404):
            .noPayload
        case NetworkError.conflict:
            .notClientProtected
        case NetworkError.server(statusCode: 413), NetworkError.responseTooLarge:
            .tooLarge
        case NetworkError.unauthorized:
            .failed("this device is no longer paired")
        case NetworkError.serviceUnavailable:
            .failed("the server is unavailable")
        case let NetworkError.transport(description):
            .failed(description)
        default:
            .failed("this message could not be fetched")
        }
    }
}
