//
//  RecipientResolveClient.swift
//  KyPost
//
//  POST {srv}/api/pgp/recipients/resolve — recipient public keys for the
//  client-encrypted send path. Swift port of kypost-android's
//  pgp/RecipientResolveClient.kt.
//
//  **This is the only path that may call `/resolve`.** The server-custody send
//  path uses `/check`, which answers "does a usable key exist" without handing
//  back key material; that rule still holds everywhere else. `/resolve` returns
//  the keys themselves because this device is the one doing the encrypting.
//
//  The two endpoints also differ in their error shapes: on `/resolve`, 200,
//  409 and 413 are JSON while 400 and 500 are plain text. Anything reading a
//  JSON body out of a 400 here will get nothing.
//

import Foundation

private struct ResolveRequest: Encodable {
    var addresses: [String]
}

private struct ResolveDTO: Decodable {
    var address: String = ""
    var publicKey: String = ""
    /// True only when a key exists *and* is usable.
    var usable: Bool = false
    /// `key_changed` means discovery found a key whose fingerprint does not
    /// match the pinned one.
    var tier: String = ""
}

private struct ResolveResponse: Decodable {
    var results: [ResolveDTO] = []
}

final class RecipientResolveClient: RecipientKeyResolving {
    private let httpClient: HTTPClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(httpClient: HTTPClient, serverUrl: String, auth: RelayAuth) {
        self.httpClient = httpClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    func resolve(addresses: [String]) async -> ResolveResult {
        guard let base = URL(string: serverUrl) else {
            return .failed("the server address is not a valid URL")
        }
        // An empty request is not worth a round trip, and the server answers
        // 400 for it.
        guard !addresses.isEmpty else { return .success([]) }

        do {
            let response = try await httpClient.post(
                ResolveResponse.self,
                url: base.appending(path: "api/pgp/recipients/resolve"),
                headers: auth.headerFields,
                jsonBody: ResolveRequest(addresses: addresses)
            )
            return .success(response.results.map {
                ResolvedRecipientKey(
                    address: $0.address,
                    publicKey: $0.publicKey,
                    usable: $0.usable,
                    tier: $0.tier
                )
            })
        } catch NetworkError.conflict {
            return .notClientProtected
        } catch NetworkError.server(statusCode: 413) {
            return .tooMany("too many recipients for one message")
        } catch NetworkError.responseTooLarge {
            return .tooMany("too many recipients for one message")
        } catch NetworkError.unauthorized {
            return .failed("this device is no longer paired")
        } catch let NetworkError.badRequest(body) {
            // Plain text on this endpoint, not JSON.
            return .failed(body.isEmpty ? "the server refused these recipients" : body)
        } catch let NetworkError.transport(description) {
            return .failed(description)
        } catch {
            return .failed("recipient keys could not be looked up")
        }
    }
}
