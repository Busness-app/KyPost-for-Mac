//
//  DeregisterClient.swift
//  KyPost
//
//  Removes this device from the account's paired-devices list (spec §1
//  successor). POST {srv}/api/notifications/native/deregister.
//  Binding contract (backend handleNotificationNativeDeregister in
//  server.go, device_auth.go): the device authenticates via
//  X-Kypost-Device-Id/X-Kypost-Device-Secret headers (RelayAuth), same as
//  every other authenticated Relay endpoint; the body is empty.
//

import Foundation

/// Result mapped to how DeregisterDeviceUseCase treats a deregister attempt.
enum DeregisterOutcome: Equatable, Sendable {
    /// 200 — the server confirmed removal.
    case success
    /// 401 — credentials already invalid (e.g. already removed elsewhere).
    case unauthorized
    /// Network error — best-effort caller proceeds with local cleanup anyway.
    case failure(String)
}

final class DeregisterClient: Sendable {
    private struct EmptyBody: Encodable {}

    private struct DeregisterResponse: Decodable {
        var ok: Bool?
    }

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func deregister(serverUrl: String, auth: RelayAuth) async -> DeregisterOutcome {
        guard let endpoint = URL(string: serverUrl)?.appending(path: "api/notifications/native/deregister") else {
            return .failure("Invalid server URL")
        }
        do {
            _ = try await httpClient.post(
                DeregisterResponse.self,
                url: endpoint,
                headers: auth.headerFields,
                jsonBody: EmptyBody()
            )
            return .success
        } catch NetworkError.unauthorized {
            return .unauthorized
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
