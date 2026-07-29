//
//  ApproveMfaChallengeUseCase.swift
//  KyPost
//
//  Responds to an MFA push challenge (spec §5). Used by both the notification
//  action buttons and the in-app MfaApprovalView fallback.
//

import Foundation

struct ApproveMfaChallengeUseCase {
    private let client: MfaResponseClient
    private let securePairingStore: SecurePairingStore

    init(client: MfaResponseClient, securePairingStore: SecurePairingStore) {
        self.client = client
        self.securePairingStore = securePairingStore
    }

    /// `matchDigits` is the number the user picked on the approval screen. The
    /// backend requires it to approve and ignores it to deny, so a deny path
    /// can keep calling this without one.
    func callAsFunction(
        challengeId: String,
        approved: Bool,
        matchDigits: String = ""
    ) async -> MfaResponseOutcome {
        let loaded: Pairing?
        do {
            loaded = try securePairingStore.loadPairing()
        } catch MailSourceError.credentialUnavailable {
            // Credential gate + app locked: the user must unlock first.
            return .failure("Unlock KyPost, then approve from the app")
        } catch {
            loaded = nil
        }
        guard let pairing = loaded else {
            return .failure("Device is not paired")
        }
        // The backend requires the responding device's ID and secret so it
        // can verify the device is still permitted to approve; without both,
        // re-pairing is the only way to obtain them.
        guard let deviceId = pairing.lastDeviceId, !deviceId.isEmpty, !pairing.deviceSecret.isEmpty else {
            return .failure("Device registration is incomplete — re-pair this device")
        }
        return await client.respond(
            serverUrl: pairing.srv,
            auth: RelayAuth(pairing: pairing),
            challengeId: challengeId,
            approved: approved,
            matchDigits: matchDigits
        )
    }
}
