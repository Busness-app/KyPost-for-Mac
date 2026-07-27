//
//  DeviceRegistrationService.swift
//  KyPost
//
//  Push token registration flow (spec §3): initial pairing from a QR/deep
//  link, and re-registration on token refresh / app foreground using the
//  stored pairing. On success the pairing and delivery settings are persisted.
//

import Foundation

extension PairingParams {
    /// Rebuilds link params from a stored pairing, for re-registration.
    init(pairing: Pairing) {
        self.init(
            sub: pairing.sub,
            srv: pairing.srv,
            pt: pairing.pairingToken,
            reg: pairing.registrationUrl
        )
    }
}

final class DeviceRegistrationService {
    private let client: NativeRegistrationClient
    private let securePairingStore: SecurePairingStore
    private let pushSettingsStore: PushSettingsStore
    /// TOFU pinning capture: the SPKI hash the transport saw on its latest
    /// handshake with the given host. Wired by SingletonGraph to the pinned
    /// session's delegate; nil in tests (no pin is recorded).
    var observedSpkiHash: ((_ host: String) -> String?)?

    /// One registration per (pairing token, device token). A pairing deep
    /// link is delivered to every open main window and each auto-pairs, so
    /// without this guard a single "Pair Desktop App" click registers the
    /// same computer several times (the server appends a device row per
    /// register call). Unlike desktop pairing codes these are not single-use,
    /// so only concurrent calls are shared — a later call with a new device
    /// token (APNs refresh) must still go through.
    private var inFlight: [String: Task<RegistrationOutcome, Never>] = [:]

    init(
        client: NativeRegistrationClient,
        securePairingStore: SecurePairingStore,
        pushSettingsStore: PushSettingsStore
    ) {
        self.client = client
        self.securePairingStore = securePairingStore
        self.pushSettingsStore = pushSettingsStore
    }

    /// Initial pairing (QR scan / deep link). Persists the pairing and
    /// delivery settings only if registration succeeds (spec §1 flow).
    /// Concurrent calls with the same tokens share one registration.
    func pair(
        params: PairingParams,
        deviceToken: String,
        deviceId: String? = nil
    ) async -> RegistrationOutcome {
        let key = "\(params.pt)|\(deviceToken)"
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task {
            await performPair(params: params, deviceToken: deviceToken, deviceId: deviceId)
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }

    private func performPair(
        params: PairingParams,
        deviceToken: String,
        deviceId: String?
    ) async -> RegistrationOutcome {
        let outcome = await client.register(
            deviceToken: deviceToken,
            params: params,
            deviceId: deviceId
        )
        if case .success(let response) = outcome {
            do {
                try securePairingStore.savePairing(Pairing(
                    sub: params.sub,
                    // Every successful register mints a brand-new secret
                    // server-side, invalidating whatever was stored before —
                    // persist unconditionally, never fall back to the
                    // previous value.
                    deviceSecret: response.deviceSecret ?? "",
                    srv: params.srv,
                    registrationUrl: params.reg,
                    pairingToken: params.pt,
                    lastDeviceId: response.deviceId ?? deviceId,
                    pairedAt: Date()
                ))
            } catch {
                return .failure("Registered but could not save pairing: \(error)")
            }
            pushSettingsStore.deliveryMode = response.deliveryMode ?? .push
            pushSettingsStore.pullEndpoint = response
                .resolvedPullEndpoint(srv: params.srv)?.absoluteString
            // Trust on FIRST use: pin the key this handshake presented only
            // when nothing is pinned yet. `performPair` also runs for every
            // re-registration (foreground, APNs token refresh), so pinning
            // unconditionally here would be trust-on-every-use — it would
            // quietly adopt whatever key was last seen, turning a single
            // interception into a permanent pin for the attacker's key and
            // locking out the real relay. Clearing the pairing is the only
            // way to re-pin, which is the documented rotation recovery.
            // Best effort: a Keychain hiccup must not fail a good registration.
            // Empty counts as unpinned, matching the delegate's own lookup.
            if (securePairingStore.pinnedSpkiHash ?? "").isEmpty,
               let host = URL(string: params.srv)?.host(),
               let hash = observedSpkiHash?(host) {
                try? securePairingStore.setPinnedSpkiHash(hash)
            }
        }
        return outcome
    }

    /// Re-registration for safety (token refresh, app foreground, spec §3).
    /// Sends the stored deviceId so the server updates the existing device
    /// row rather than pairing this computer a second time.
    /// Returns nil when the device was never paired — nothing to refresh.
    @discardableResult
    func reregisterIfPaired(deviceToken: String) async -> RegistrationOutcome? {
        guard let pairing = try? securePairingStore.loadPairing() else { return nil }
        return await pair(
            params: PairingParams(pairing: pairing),
            deviceToken: deviceToken,
            deviceId: pairing.lastDeviceId
        )
    }
}
