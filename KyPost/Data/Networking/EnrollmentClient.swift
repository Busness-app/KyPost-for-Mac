//
//  EnrollmentClient.swift
//  KyPost
//
//  The three device-authenticated enrollment calls. Swift port of
//  kypost-android's pgp/EnrollmentClients.kt.
//

import Foundation
import os

private struct PublishEnrollmentKeyRequest: Encodable {
    var publicKey: String
}

private struct EnrollmentStateRequest: Encodable {
    var encryptionEnrolled: Bool
}

private struct DeviceEnvelopeResponse: Decodable {
    var envelope: String?
}

/// Talks to `/api/pgp/device/{enrollment-key,envelope,enrollment-state}`.
///
/// Every URL is built from the **paired origin**, never from a server-supplied
/// one — the same rule the PGP QR path follows, and for the same reason: a
/// tampered response must not be able to point an authenticated call at another
/// host, outside the TLS pin.
struct EnrollmentClient: EnrollmentTransport {
    private let httpClient: HTTPClient
    private let bootstrapClient: PgpSendClient
    private let serverUrl: String
    private let auth: RelayAuth

    init(
        httpClient: HTTPClient,
        bootstrapClient: PgpSendClient,
        serverUrl: String,
        auth: RelayAuth
    ) {
        self.httpClient = httpClient
        self.bootstrapClient = bootstrapClient
        self.serverUrl = serverUrl
        self.auth = auth
    }

    /// The account's fingerprint, computed locally from bootstrap's public key
    /// bytes.
    ///
    /// **Hashed here rather than read from the response's `fingerprint`
    /// field**, which is a claim beside the key with no cryptographic tie to
    /// it. The same rule the QR exchange follows: a fingerprint that binds an
    /// envelope must describe the key material actually in hand.
    func identityFingerprint() async -> String? {
        guard let response = try? await bootstrapClient.fetchBootstrap(
            serverUrl: serverUrl,
            auth: auth
        ) else { return nil }
        guard response.hasIdentity == true,
              let publicKey = response.publicKey, !publicKey.isEmpty
        else { return nil }
        return PgpFingerprint.compute(fromArmored: publicKey)
    }

    func publish(publicKey: Data) async -> EnrollmentPublishResult {
        do {
            _ = try await httpClient.post(
                RelayActionResponse.self,
                url: try endpoint("api/pgp/device/enrollment-key"),
                headers: auth.headerFields,
                jsonBody: PublishEnrollmentKeyRequest(
                    publicKey: publicKey.base64EncodedString()
                )
            )
            return .ok
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.badRequest(let body) {
            return .rejected(body.isEmpty ? "The server refused this device's key." : body)
        } catch NetworkError.conflict(let body) {
            return .rejected(body.isEmpty ? "This device is already enrolled." : body)
        } catch {
            return .failed(MailOutcome.message(for: networkError(error)))
        }
    }

    /// No slot parameter: the server builds it from the verified credential.
    func fetchEnvelope() async -> EnrollmentEnvelopeResult {
        do {
            let response = try await httpClient.get(
                DeviceEnvelopeResponse.self,
                url: try endpoint("api/pgp/device/envelope"),
                headers: auth.headerFields
            )
            guard let envelope = response.envelope, !envelope.isEmpty else {
                return .failed("The server sent an envelope this app couldn't read.")
            }
            return .sealed(envelope)
        } catch NetworkError.unauthorized {
            return .unauthorized
        } catch NetworkError.server(statusCode: 404) {
            // 404 covers "never sealed" and "expired" alike — indistinguishable
            // by design, and both mean keep waiting or re-run.
            return .notSealed
        } catch {
            return .failed(MailOutcome.message(for: networkError(error)))
        }
    }

    /// Always written explicitly: this route requires the field, so an absent
    /// value is a 400 rather than "no opinion".
    func reportEnrolled(_ enrolled: Bool) async {
        do {
            _ = try await httpClient.post(
                RelayActionResponse.self,
                url: try endpoint("api/pgp/device/enrollment-state"),
                headers: auth.headerFields,
                jsonBody: EnrollmentStateRequest(encryptionEnrolled: enrolled)
            )
        } catch {
            // Best-effort: the envelope is already open and stored, so failing
            // to tell the server changes nothing this device can do. The next
            // ceremony reports it again.
            Log.app.error("Reporting enrollment state failed: \(error.localizedDescription)")
        }
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: serverUrl) else {
            throw MailSourceError.invalidServerURL
        }
        return url.appending(path: path)
    }

    private func networkError(_ error: Error) -> NetworkError {
        (error as? NetworkError) ?? .transport(description: error.localizedDescription)
    }
}
