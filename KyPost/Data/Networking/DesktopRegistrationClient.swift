//
//  DesktopRegistrationClient.swift
//  KyPost
//
//  Exchanges a one-time desktop pairing code for a session token
//  (Desktop Pairing guide, Step 3: POST /api/notifications/desktop/register).
//

import Foundation

struct DesktopRegistrationResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var sessionToken: String
    /// Token lifetime in seconds.
    var expiresIn: Int
    var userId: String?
    var userEmail: String?
}

/// Registration result mapped to the guide's response codes.
enum DesktopRegistrationOutcome: Equatable, Sendable {
    case success(DesktopRegistrationResponse)
    /// 401 — invalid or expired pairing code (codes live 5 minutes).
    case invalidOrExpiredCode
    /// 409 — pairing code already consumed (codes are single-use).
    case codeAlreadyConsumed
    /// 429 — too many failed attempts; the user must wait up to an hour.
    case rateLimited
    case failure(String)
}

final class DesktopRegistrationClient: Sendable {
    private struct RegisterRequest: Encodable {
        var pairingCode: String
        var appName: String
        var appVersion: String
        var platformInfo: String
    }

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    /// Sends the pairing code with app metadata; no session auth required.
    func register(params: DesktopPairingParams) async -> DesktopRegistrationOutcome {
        guard let endpoint = params.registerEndpoint else {
            return .failure("Invalid registration URL")
        }
        do {
            let response = try await httpClient.post(
                DesktopRegistrationResponse.self,
                url: endpoint,
                jsonBody: RegisterRequest(
                    pairingCode: params.code,
                    appName: Self.appName,
                    appVersion: Self.appVersion,
                    platformInfo: Self.platformInfo
                )
            )
            return .success(response)
        } catch NetworkError.unauthorized {
            return .invalidOrExpiredCode
        } catch NetworkError.conflict(_) {
            return .codeAlreadyConsumed
        } catch NetworkError.rateLimited {
            return .rateLimited
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

    // MARK: - App identity sent with the register request

    private static var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "KyPost"
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// e.g. "Yoshi's MacBook Pro (macOS/arm64)" — the user-assigned device
    /// name leads so the server's paired-device list shows something
    /// recognizable, with platform/arch kept as a suffix.
    private static var platformInfo: String {
#if os(macOS)
        let os = "macOS"
#else
        let os = "iOS"
#endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let platform = "\(os)/\(machine.isEmpty ? "unknown" : machine)"
#if os(macOS)
        if let deviceName = Host.current().localizedName, !deviceName.isEmpty {
            return "\(deviceName) (\(platform))"
        }
#endif
        return platform
    }
}
