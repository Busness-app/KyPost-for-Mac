//
//  PgpCrypto.swift
//  KyPost
//
//  The seam between this app and whatever OpenPGP implementation backs it.
//
//  **Nothing outside this file's conforming types may reference the crypto
//  library.** GopenPGP's v2→v3 API break is recent enough that a swap should
//  touch one file, and the call sites — the reader, compose, and the signature
//  binding — should never have known which library was underneath.
//

import Foundation

/// A decrypted message body plus what the signature over it claimed.
nonisolated struct DecryptedMessage: Equatable, Sendable {
    var body: Data
    var signature: RawSignature
}

nonisolated enum PgpCryptoError: Error, Equatable {
    /// The key material did not parse. Never a pass: an unparseable key only
    /// ever shrinks the candidate set.
    case unusableKey
    /// Decryption failed against the key held. Distinct from `unusableKey`
    /// because the remedies differ — one is a wrong key, the other a broken one.
    case cannotDecrypt
    /// Decompressed plaintext exceeded the cap **before** allocation. A zip
    /// bomb in an encrypted message is otherwise an OOM kill.
    case tooLarge
    case cannotEncrypt(String)
    /// No implementation is linked yet.
    case unavailable
}

/// Reading. Implemented against the account's private key once this device
/// holds one.
protocol PgpDecrypting: Sendable {
    /// Decrypts and verifies in one pass. `signerKeys` are the candidate
    /// public keys, already narrowed to the sender by the server.
    func decrypt(
        armoredCiphertext: String,
        privateKey: Data,
        signerKeys: [String]
    ) throws -> DecryptedMessage

    /// Every usable key id in an armored public key: the primary plus every
    /// subkey, regardless of usage flags.
    ///
    /// A one-pass signature is ordinarily made with a dedicated signing
    /// subkey whose id differs from the primary's, so matching only the
    /// primary would silently reject every normally signed message. Revoked
    /// and expired keys are excluded **before** matching. Returns an empty set
    /// rather than throwing on a key that fails to parse — see
    /// `PgpCryptoError.unusableKey`.
    func keyIDs(inArmoredPublicKey key: String) -> Set<String>
}

/// Writing. Used only on the client-custody send path.
protocol PgpEncrypting: Sendable {
    /// Encrypts to `recipientKeys` and signs with the device's key.
    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String

    /// The public half of the key this device holds.
    ///
    /// The Sent copy is encrypted to **this**, never to bootstrap's
    /// `publicKey`: a hostile server supplying "your" key would otherwise get
    /// a readable copy of every message sent.
    func ownPublicKey(privateKey: Data) throws -> String
}

/// The cap applied before allocating decompressed plaintext.
let maxDecompressedPlaintextBytes = 32 * 1024 * 1024

/// Stands in until an implementation is linked.
///
/// Deliberately fails rather than degrading: a decrypt path that silently
/// returns nothing is indistinguishable from a client-protected message the
/// user must open in webmail, and that is precisely the confusion the message
/// states exist to avoid.
struct UnavailablePgpCrypto: PgpDecrypting, PgpEncrypting {
    func decrypt(
        armoredCiphertext: String,
        privateKey: Data,
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        throw PgpCryptoError.unavailable
    }

    func keyIDs(inArmoredPublicKey key: String) -> Set<String> { [] }

    func encryptAndSign(
        plaintext: Data,
        recipientKeys: [String],
        privateKey: Data
    ) throws -> String {
        throw PgpCryptoError.unavailable
    }

    func ownPublicKey(privateKey: Data) throws -> String {
        throw PgpCryptoError.unavailable
    }
}
