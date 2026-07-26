//
//  MfaResponseClient.swift
//  KyPost
//
//  Sends MFA approve/deny responses (spec §5).
//  POST {srv}/api/mfa/push/respond
//  Binding contract (backend handlePushRespond in push_mfa_handlers.go):
//  the device authenticates via X-Kypost-Device-Id/X-Kypost-Device-Secret
//  headers (RelayAuth), same as every other authenticated Relay endpoint;
//  the body carries only challengeId and approve.
//

import Foundation

/// Result mapped to the spec §5 handling rules.
enum MfaResponseOutcome: Equatable, Sendable {
    /// 200 — close the notification.
    case success
    /// 403/409 — backend rejection; show a toast explaining why.
    case rejected
    /// Network error — offer retry.
    case failure(String)
}

final class MfaResponseClient: Sendable {
    private struct RespondRequest: Encodable {
        var challengeId: String
        var approve: Bool
    }

    private struct RespondResponse: Decodable {
        var ok: Bool?
    }

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func respond(
        serverUrl: String,
        auth: RelayAuth,
        challengeId: String,
        approved: Bool
    ) async -> MfaResponseOutcome {
        guard let endpoint = URL(string: serverUrl)?.appending(path: "api/mfa/push/respond") else {
            return .failure("Invalid server URL")
        }
        do {
            _ = try await httpClient.post(
                RespondResponse.self,
                url: endpoint,
                headers: auth.headerFields,
                jsonBody: RespondRequest(challengeId: challengeId, approve: approved)
            )
            return .success
        } catch NetworkError.unauthorized, NetworkError.conflict(_) {
            return .rejected
        } catch {
            return .failure("\(error)")
        }
    }
}
