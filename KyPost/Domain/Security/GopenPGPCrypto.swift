//
//  GopenPGPCrypto.swift
//  KyPost
//
//  The one file in this app that may `import Gopenpgp`. Everything else talks
//  to `PgpDecrypting` / `PgpEncrypting`; see PgpCrypto.swift for why.
//
//  Swift port of kypost-android's pgp/PgpDecryptor.kt and pgp/PgpEncryptor.kt.
//  Android used Bouncy Castle and had to assemble the guarantees by hand — walk
//  to the literal packet, bound the decompressed stream before allocating,
//  check the integrity packet, refuse to let a message verify itself. GopenPGP
//  expresses all four as configuration, so the port is mostly a matter of not
//  switching them off.
//

import Foundation
import Gopenpgp

/// Bridges the OpenPGP implementation to this app's protocols.
///
/// Every entry point returns a value or throws a `PgpCryptoError`; nothing
/// leaks a `Gopenpgp` type. Errors from the library are deliberately not
/// forwarded verbatim — the caller renders an exit-table row, and a Go error
/// string is not that.
nonisolated struct GopenPGPCrypto: PgpDecrypting, PgpEncrypting {

    /// gomobile's encoding selector. 0 is "detect", which accepts both the
    /// armored and the binary form; mail carries armored, and a stored draft
    /// or an attachment may not.
    private static let autoDetectEncoding: Int8 = 0

    private var pgp: CryptoPGPHandle {
        get throws {
            guard let handle = CryptoPGP() else { throw PgpCryptoError.unavailable }
            return handle
        }
    }

    // MARK: - Reading

    func decrypt(
        armoredCiphertext: String,
        privateKey: Data,
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        let armoredPrivate = String(decoding: privateKey, as: UTF8.self)
        guard let key = CryptoKey(fromArmored: armoredPrivate) else {
            throw PgpCryptoError.unusableKey
        }
        // The key came out of the device envelope already unwrapped. One that
        // still wants a passphrase is not a key this device can use, and
        // guessing an empty one would report "wrong key" for what is really a
        // locked key.
        var locked: ObjCBool = false
        if (try? key.isLocked(&locked)) != nil, locked.boolValue {
            throw PgpCryptoError.unusableKey
        }

        guard let decryptionKeys = CryptoKeyRing(key) else { throw PgpCryptoError.unusableKey }

        // Only keys the address book bound to the displayed sender may verify.
        // The signer's public key travels inside signed mail often enough to
        // be tempting, and a message that vouches for itself proves only that
        // whoever wrote it owned a key.
        //
        // One measured caveat, because it is surprising: GopenPGP will also
        // verify a signature against the **decryption key**, offered or not.
        // Self-sent mail therefore reports as verified. That is not a forgery
        // route — signing still needs the private half only this device holds
        // — but it does mean a test built on a self-signed message proves
        // nothing about which keys are trusted. See
        // `onlyAnOfferedKeyValidatesASignature`, which arranges a signer
        // distinct from the decryption key for exactly that reason.
        let verificationKeys = try? keyRing(fromArmored: signerKeys)

        let handle: any CryptoPGPDecryptionProtocol
        do {
            guard let builder = try pgp.decryption() else { throw PgpCryptoError.unavailable }
            builder.decryptionKeys(decryptionKeys)
            if let verificationKeys { builder.verificationKeys(verificationKeys) }
            // The zip-bomb bound, enforced by the library during decompression
            // rather than after it. Android had to hand-roll this over the
            // decompressed stream; here it is a setting, and the reason it is
            // set explicitly is that the default is not this app's cap.
            builder.maxDecompressedMessageSize(Int64(maxDecompressedPlaintextBytes))
            handle = try builder.new()
        } catch let error as PgpCryptoError {
            throw error
        } catch {
            throw PgpCryptoError.cannotDecrypt
        }
        defer { handle.clearPrivateParams() }

        // Note what is *not* called on that builder:
        //
        //   insecureDisableUnauthenticatedMessagesCheck — integrity protection
        //     is mandatory. An unprotected message is malleable, and accepting
        //     one lets a tampered ciphertext render as ordinary mail.
        //   insecureAllowDecryptionWithSigningKeys — a signing key is not a
        //     decryption key.
        //   disableIntendedRecipients / disableVerifyTimeCheck — both weaken
        //     what a signature means.
        //
        // Each is an opt-out, so the secure behaviour is what happens by
        // leaving them alone. They are listed because "we never call these" is
        // otherwise invisible to a reader, and a future edit adding one would
        // look like a fix for a decryption failure.

        let result: CryptoVerifiedDataResult
        do {
            result = try handle.decrypt(
                Data(armoredCiphertext.utf8),
                encoding: Self.autoDetectEncoding
            )
        } catch {
            // The library reports the size cap as an ordinary decryption
            // error. Distinguishing it matters: "too large" is a different row
            // in the exit table from "not encrypted to a key on this device".
            throw Self.describesSizeLimit(error)
                ? PgpCryptoError.tooLarge
                : PgpCryptoError.cannotDecrypt
        }

        return DecryptedMessage(
            body: result.bytes() ?? Data(),
            signature: Self.rawSignature(from: result)
        )
    }

    func fingerprint(ofArmoredPublicKey key: String) -> String? {
        guard let parsed = CryptoKey(fromArmored: key) else { return nil }
        let value = parsed.getFingerprint()
        return value.isEmpty ? nil : value
    }

    // MARK: - Writing

    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String {
        let armoredPrivate = String(decoding: privateKey, as: UTF8.self)
        guard let signingKey = CryptoKey(fromArmored: armoredPrivate) else {
            throw PgpCryptoError.unusableKey
        }
        let recipients = try keyRing(fromArmored: recipientKeys)
        guard recipients.countEntities() > 0 else {
            throw PgpCryptoError.cannotEncrypt("no usable recipient key")
        }

        do {
            guard let builder = try pgp.encryption() else { throw PgpCryptoError.unavailable }
            builder.recipients(recipients)
            builder.signing(signingKey)
            let handle = try builder.new()
            defer { handle.clearPrivateParams() }
            let message = try handle.encrypt(plaintext)
            // Non-throwing in Swift because it returns a non-optional String,
            // so the error has to be read out by hand rather than caught.
            var armorError: NSError?
            let armored = message.armor(&armorError)
            if let armorError {
                throw PgpCryptoError.cannotEncrypt(armorError.localizedDescription)
            }
            return armored
        } catch let error as PgpCryptoError {
            throw error
        } catch {
            throw PgpCryptoError.cannotEncrypt(error.localizedDescription)
        }
    }

    func ownPublicKey(privateKey: Data) throws -> String {
        let armoredPrivate = String(decoding: privateKey, as: UTF8.self)
        guard let key = CryptoKey(fromArmored: armoredPrivate) else {
            throw PgpCryptoError.unusableKey
        }
        var error: NSError?
        let armored = key.getArmoredPublicKey(&error)
        guard error == nil, !armored.isEmpty else { throw PgpCryptoError.unusableKey }
        return armored
    }

    // MARK: - Private

    /// Collects armored public keys into one ring, skipping any that do not
    /// parse. A key that fails to parse only ever shrinks the candidate set.
    private func keyRing(fromArmored keys: [String]) throws -> CryptoKeyRing {
        guard let ring = CryptoKeyRing(nil) else { throw PgpCryptoError.unusableKey }
        for armored in keys {
            guard let key = CryptoKey(fromArmored: armored) else { continue }
            try? ring.add(key)
        }
        return ring
    }

    /// Reads what the verification actually established.
    ///
    /// `present` is "this message carried a signature", which is true whether
    /// or not it verified — a signed message from a sender with no bound key
    /// is `present, !valid`, and that is not an accusation. Only
    /// `signatureState` decides how it reads.
    private static func rawSignature(from result: CryptoVerifiedDataResult) -> RawSignature {
        let keyID = result.signedByKeyIdHex()
        // Attribution is the entity's fingerprint, never the signature's own
        // issuer fingerprint: that one is the signing subkey's whenever a
        // subkey signed, and nothing a bound public key reports matches it.
        let fingerprint = result.signedByKey()?.getFingerprint() ?? ""

        var verified = true
        do {
            try result.signatureError()
        } catch {
            verified = false
        }

        // No key id and no attribution means nothing claimed to sign this.
        let present = verified || !keyID.isEmpty || !fingerprint.isEmpty
        guard present else { return RawSignature() }

        return RawSignature(
            present: true,
            valid: verified && !fingerprint.isEmpty,
            signerKeyID: keyID,
            signerFingerprint: fingerprint
        )
    }

    /// Whether a decryption error is the decompressed-size cap being hit.
    ///
    /// Matched on the message because gomobile flattens every Go error to an
    /// `NSError` with the same domain and code, so there is nothing else to
    /// match on. A miss costs the precision of one exit-table row, never
    /// safety: the message is rejected either way.
    private static func describesSizeLimit(_ error: Error) -> Bool {
        let text = (error as NSError).localizedDescription.lowercased()
        return text.contains("decompressed")
            || text.contains("too large")
            || text.contains("size limit")
    }
}
