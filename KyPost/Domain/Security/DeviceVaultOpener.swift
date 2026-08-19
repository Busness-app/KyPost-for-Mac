//
//  DeviceVaultOpener.swift
//  KyPost
//
//  The real `VaultOpening`: reads the sealed envelope back out of the
//  Keychain, which is where the user-presence prompt happens.
//
//  Separate from EnrollmentVault so EncryptedMessageReader stays free of
//  platform imports — the reader talks to the protocol, and this is the only
//  place the Security framework's failure modes get turned into exit-table
//  rows.
//

import Foundation

nonisolated struct DeviceVaultOpener: VaultOpening {
    private let vault: EnrollmentVault

    init(vault: EnrollmentVault) {
        self.vault = vault
    }

    func open() async -> VaultOpenOutcome {
        // Off the calling actor: reading an access-controlled Keychain item
        // blocks until the user answers the presence prompt, and doing that on
        // the main actor freezes the window the prompt is attached to.
        await Task.detached(priority: .userInitiated) {
            do {
                return VaultOpenOutcome.opened(privateKey: try vault.storedPrivateKey())
            } catch EnrollmentVaultError.notEnrolled {
                return .notEnrolled
            } catch EnrollmentVaultError.noDeviceCredential {
                return .noSecureLockScreen
            } catch EnrollmentVaultError.cancelled {
                // Dismissing the prompt is a decision, not a failure.
                return .cancelled
            } catch EnrollmentVaultError.unavailable {
                return .failed("this device's secure hardware is unavailable")
            } catch let EnrollmentVaultError.keychain(status) {
                // `errSecUserCanceled` reaches here when the prompt is
                // dismissed by the system rather than by the vault's own
                // mapping. Treated as cancellation for the same reason: the
                // screen goes back to offering Decrypt rather than accusing
                // the device of a fault.
                if status == errSecUserCanceled { return .cancelled }
                return .failed("the key on this device could not be opened (\(status))")
            } catch {
                return .failed("the key on this device could not be opened")
            }
        }.value
    }
}
