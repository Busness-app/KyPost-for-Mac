//
//  MfaResponseClient.swift
//  KyPost
//
//  Sends MFA approve/deny responses (spec §5).
//  POST {srv}/api/mfa/push/respond
//  Binding contract (backend handlePushRespond in push_mfa_handlers.go):
//  the device authenticates via X-Kypost-Device-Id/X-Kypost-Device-Secret
//  headers (RelayAuth), same as every other authenticated Relay endpoint;
//  the body carries challengeId, approve and matchDigits.
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
        /// The number the user picked off the approval screen. The backend
        /// verifies it (`Store.ResolvePushWithMatch`) and refuses an approval
        /// that does not carry it — this endpoint is reachable by anyone
        /// holding device credentials, so an on-device comparison alone would
        /// be decoration. Always encoded, including as "" on a deny, which the
        /// backend ignores.
        var matchDigits: String
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
        approved: Bool,
        matchDigits: String = ""
    ) async -> MfaResponseOutcome {
        guard let endpoint = URL(string: serverUrl)?.appending(path: "api/mfa/push/respond") else {
            return .failure("Invalid server URL")
        }
        do {
            _ = try await httpClient.post(
                RespondResponse.self,
                url: endpoint,
                headers: auth.headerFields,
                jsonBody: RespondRequest(
                    challengeId: challengeId,
                    approve: approved,
                    // Never on a deny: the safe answer must not depend on
                    // reading a number off another screen.
                    matchDigits: approved ? matchDigits : ""
                )
            )
            return .success
        } catch NetworkError.unauthorized, NetworkError.conflict(_) {
            return .rejected
        } catch NetworkError.badRequest {
            // The number was wrong, but the credentials were fine and the
            // challenge is still live — a re-prompt, not a re-pair. When no
            // number was sent at all the server rejects for a different reason,
            // and telling the user they mistyped a number they were never shown
            // sent them round a loop with no exit.
            return .failure(
                approved && matchDigits.isEmpty
                    ? "This sign-in request can't be approved from this device — deny it and sign in again"
                    : "That is not the number shown in the browser"
            )
        } catch NetworkError.rateLimited {
            // The attempt budget is spent; the challenge will not be approved
            // now even with the right number.
            return .failure("Too many incorrect attempts — start the sign-in again")
        } catch let error as NetworkError {
            // "\(error)" resolves through String(describing:), which never
            // consults LocalizedError — so certificateMismatch printed as the
            // bare case name and its "the connection may be intercepted"
            // warning never reached the user.
            return .failure(MailOutcome.message(for: error))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
