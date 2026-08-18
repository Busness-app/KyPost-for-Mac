//
//  VaultSealer.swift
//  KyPost
//
//  Opens a sealed envelope with the device key and stores the result.
//  Counterpart of kypost-android's pgp/VaultOpenerAndroid.kt.
//

import CryptoKit
import Foundation
import Security

/// The `EnrollmentSealer` the ceremony actually runs against.
///
/// Kept apart from `EnrollmentVault` so the ceremony depends on a protocol
/// rather than on the Keychain and LocalAuthentication: that is what lets the
/// whole exit table be a unit test.
struct VaultSealer: EnrollmentSealer {
    private let vault: EnrollmentVault
    private let deviceId: String

    init(vault: EnrollmentVault, deviceId: String) {
        self.vault = vault
        self.deviceId = deviceId
    }

    func deviceRawPublicKey() throws -> Data {
        _ = try vault.ensureDeviceKey()
        return try vault.rawPublicKey()
    }

    /// Unseals and stores, or throws.
    ///
    /// The ECDH step is where user presence is demanded: the private key is
    /// created with `.userPresence`, so `SecKeyCopyKeyExchangeResult` raises
    /// the system prompt. A cancelled prompt is surfaced as
    /// `EnrollmentVaultError.cancelled` and is **not** an error — the user
    /// dismissed something they raised.
    func openAndStore(envelopeJSON: String, identityFingerprint: String) async throws {
        guard let fields = parseDeviceEnvelope(envelopeJSON) else {
            throw EnrollmentSealerError.envelopeMalformed
        }
        let aad = try deviceEnvelopeAAD(
            deviceId: deviceId,
            pgpFingerprint: identityFingerprint
        )

        let privateKey = try vault.deviceKey()
        guard let ephemeral = SecKeyCreateWithData(
            fields.epk as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: 256,
            ] as CFDictionary,
            nil
        ) else {
            throw EnrollmentSealerError.envelopeMalformed
        }

        var error: Unmanaged<CFError>?
        guard let secretData = SecKeyCopyKeyExchangeResult(
            privateKey,
            .ecdhKeyExchangeStandard,
            ephemeral,
            [:] as CFDictionary,
            &error
        ) as Data? else {
            let failure = error?.takeRetainedValue()
            if failure.map(isUserCancellation) == true {
                throw EnrollmentVaultError.cancelled
            }
            // A key-exchange failure that is *not* a cancellation says nothing
            // about the envelope, so it must not be reported as one. Reporting
            // it as "hostile or stale" would tell the user their key was
            // substituted because their Secure Enclave was busy.
            throw EnrollmentVaultError.unavailable
        }

        // CryptoKit's HKDF wants a SharedSecret, which only its own key
        // agreement produces; the Secure Enclave path hands back raw bytes, so
        // the derivation is done directly here against the same inputs.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretData),
            salt: try vault.rawPublicKey(),
            info: Data(envelopeInfo.utf8),
            outputByteCount: 32
        )
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: fields.iv),
            ciphertext: fields.ct.dropLast(16),
            tag: fields.ct.suffix(16)
        ), let plaintext = try? AES.GCM.open(box, using: derived, authenticating: aad) else {
            // Hostile or stale, never a retry: the AAD binds the sealing to
            // this device and this identity.
            throw EnrollmentSealerError.envelopeRejected
        }

        try vault.store(privateKey: plaintext, identityFingerprint: identityFingerprint)
    }
}

/// Distinguishes "the user dismissed the prompt" from a real failure.
///
/// **Only cancellation counts.** `errSecAuthFailed` is an authentication that
/// was attempted and rejected, which is a different event with a different
/// remedy — folding it in here would report a wrong fingerprint as "never
/// mind", and the mirror-image mistake (treating an unanswerable check as a
/// failed one) is what destroyed user data on Android's app lock.
private func isUserCancellation(_ error: CFError) -> Bool {
    CFErrorGetCode(error) == errSecUserCanceled
}
