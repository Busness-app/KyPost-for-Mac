//
//  GopenPGPCryptoTests.swift
//  KyPost Tests
//
//  Holds the OpenPGP core to the guarantees PgpCrypto.swift promises, against
//  material gpg produced. See TestPgpFixtures for why the fixtures come from a
//  different implementation than the one under test.
//

import Foundation
import Gopenpgp
import Testing
@testable import KyPost

@Suite(.serialized) struct GopenPGPCryptoTests {
    private let crypto = GopenPGPCrypto()
    private var privateKey: Data { Data(TestPgpFixtures.armoredPrivate.utf8) }

    // MARK: - Reading

    @Test func decryptsAMessageGpgProduced() throws {
        let result = try crypto.decrypt(
            armoredCiphertext: TestPgpFixtures.armoredMessage,
            privateKey: privateKey,
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        #expect(String(decoding: result.body, as: UTF8.self) == TestPgpFixtures.expectedPlaintext)
    }

    /// The one that made attribution entity-level.
    ///
    /// `signerFingerprint` must be the key's own fingerprint — the value a
    /// bound public key reports about itself — so `signatureState` can match
    /// it. If this ever comes back as the signing component's fingerprint
    /// instead, every signed message silently reads as an unknown signer.
    @Test func aVerifiedSignatureIsAttributedToTheEntityFingerprint() throws {
        let result = try crypto.decrypt(
            armoredCiphertext: TestPgpFixtures.armoredMessage,
            privateKey: privateKey,
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        #expect(result.signature.present)
        #expect(result.signature.valid)
        #expect(
            result.signature.signerFingerprint.caseInsensitiveCompare(TestPgpFixtures.fingerprint)
                == .orderedSame
        )
        // And it is the value the bound key reports, which is the whole point.
        #expect(
            crypto.fingerprint(ofArmoredPublicKey: TestPgpFixtures.armoredPublic)?
                .caseInsensitiveCompare(result.signature.signerFingerprint) == .orderedSame
        )
    }

    /// **A message may not vouch for itself.**
    ///
    /// The signer's public key travels inside signed mail, and using it would
    /// prove only that whoever wrote the message owned a key. With no key
    /// offered, the signature must come back present but not valid — which
    /// `signatureState` renders as "signed by a key you haven't saved", not as
    /// an accusation.
    @Test func withNoOfferedKeyASignatureIsPresentButNotValid() throws {
        let result = try crypto.decrypt(
            armoredCiphertext: TestPgpFixtures.armoredMessage,
            privateKey: privateKey,
            signerKeys: []
        )
        #expect(String(decoding: result.body, as: UTF8.self) == TestPgpFixtures.expectedPlaintext)
        #expect(!result.signature.valid)
    }

    /// Only a key we were **offered** may validate a signature.
    ///
    /// The message here is signed by one key and encrypted to another, and the
    /// key held is the second — the only arrangement in which this question is
    /// really being asked. Reusing the stock fixture cannot ask it: that
    /// message is signed by the very key that decrypts it, and GopenPGP will
    /// verify against the decryption key whether or not it was offered. That
    /// is not a forgery route, since signing still needs the private half we
    /// alone hold, but it does mean a test using a self-signed message proves
    /// nothing about which keys are trusted.
    @Test func onlyAnOfferedKeyValidatesASignature() throws {
        let signedByFirstSentToSecond = try crypto.encryptAndSign(
            plaintext: Data("from someone else".utf8),
            recipientKeys: [TestPgpFixtures.unrelatedPublicKey],
            privateKey: privateKey
        )
        let held = Data(TestPgpFixtures.unrelatedPrivate.utf8)

        // Offered nothing: signed, but not something we can vouch for.
        let unoffered = try crypto.decrypt(
            armoredCiphertext: signedByFirstSentToSecond,
            privateKey: held,
            signerKeys: []
        )
        #expect(unoffered.signature.present)
        #expect(!unoffered.signature.valid)

        // Offered the wrong key: still not vouched for.
        let wrongKey = try crypto.decrypt(
            armoredCiphertext: signedByFirstSentToSecond,
            privateKey: held,
            signerKeys: [TestPgpFixtures.unrelatedPublicKey]
        )
        #expect(!wrongKey.signature.valid)

        // Offered the key that actually signed it: verified, and attributed.
        let right = try crypto.decrypt(
            armoredCiphertext: signedByFirstSentToSecond,
            privateKey: held,
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        #expect(right.signature.valid)
        #expect(
            right.signature.signerFingerprint
                .caseInsensitiveCompare(TestPgpFixtures.fingerprint) == .orderedSame
        )
    }

    /// Integrity protection is not optional.
    ///
    /// A legacy tag-9 packet carries no MDC, so a tampered ciphertext would
    /// otherwise render as ordinary mail. GopenPGP refuses it unless
    /// `insecureDisableUnauthenticatedMessagesCheck` is called, and it is not.
    @Test func failsClosedOnAnUnprotectedMessage() {
        #expect(throws: PgpCryptoError.self) {
            try crypto.decrypt(
                armoredCiphertext: TestPgpFixtures.armoredUnprotectedMessage,
                privateKey: privateKey,
                signerKeys: []
            )
        }
    }

    /// The message is built here rather than stored as a fixture: a stored
    /// one would have to come from somewhere, and what is being asserted is a
    /// refusal, not interoperability.
    @Test func aMessageNotEncryptedToThisKeyIsRefused() throws {
        let toSomeoneElse = try crypto.encryptAndSign(
            plaintext: Data("not for you".utf8),
            recipientKeys: [TestPgpFixtures.unrelatedPublicKey],
            privateKey: privateKey
        )
        #expect(throws: PgpCryptoError.self) {
            try crypto.decrypt(
                armoredCiphertext: toSomeoneElse,
                privateKey: privateKey,
                signerKeys: []
            )
        }
    }

    @Test func garbageIsNotAMessage() {
        #expect(throws: PgpCryptoError.self) {
            try crypto.decrypt(
                armoredCiphertext: "not an OpenPGP message at all",
                privateKey: privateKey,
                signerKeys: []
            )
        }
    }

    @Test func anUnusableKeyIsReportedAsSuch() {
        #expect(throws: PgpCryptoError.unusableKey) {
            try crypto.decrypt(
                armoredCiphertext: TestPgpFixtures.armoredMessage,
                privateKey: Data("-----BEGIN PGP PRIVATE KEY BLOCK-----\ngarbage\n".utf8),
                signerKeys: []
            )
        }
    }

    // MARK: - Detached signatures (the signed-but-not-encrypted path)

    /// Produces an armored detached signature over `data`, the way the server's
    /// signedOnlyParts hands one to the client. Built here rather than stored as
    /// a fixture because what is asserted is a byte-exact verification, and a
    /// round trip proves it end to end against the real library.
    private func detachedSignature(over data: Data) throws -> String {
        let pgp = try #require(CryptoPGP())
        let key = try #require(CryptoKey(fromArmored: TestPgpFixtures.armoredPrivate))
        let builder = try #require(pgp.sign())
        builder.signing(key)
        builder.detached()
        let handle = try builder.new()
        let signature = try #require(try handle.sign(data, encoding: CryptoArmor))
        return String(decoding: signature, as: UTF8.self)
    }

    /// The heart of the signed-only path: the offered key that signed the exact
    /// octets verifies, and is attributed to the entity fingerprint the bound
    /// key reports about itself — the value `signatureState` matches on.
    @Test func verifiesADetachedSignatureOverTheExactOctets() throws {
        let signed = Data("the exact octets that were signed\r\n".utf8)
        let signature = try detachedSignature(over: signed)

        let verdict = crypto.verifyDetached(
            signedBytes: signed,
            armoredSignature: signature,
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        #expect(verdict.present)
        #expect(verdict.valid)
        #expect(
            verdict.signerFingerprint.caseInsensitiveCompare(TestPgpFixtures.fingerprint)
                == .orderedSame
        )
    }

    /// One flipped byte must fail. This is the whole reason the server ships the
    /// verbatim signed part and the reader checks it instead of `body`: a
    /// byte-exact check is what makes a detached signature mean anything.
    @Test func aSingleAlteredByteDoesNotVerify() throws {
        let signed = Data("the exact octets that were signed\r\n".utf8)
        let signature = try detachedSignature(over: signed)

        let verdict = crypto.verifyDetached(
            signedBytes: signed + Data([0x21]),
            armoredSignature: signature,
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        #expect(!verdict.valid)
    }

    /// Only an offered key may vouch. Offered the wrong key — or none — a real
    /// signature comes back not valid, which `signatureState` renders as an
    /// unknown signer, never a pass.
    @Test func onlyAnOfferedKeyValidatesADetachedSignature() throws {
        let signed = Data("the exact octets that were signed\r\n".utf8)
        let signature = try detachedSignature(over: signed)

        let wrongKey = crypto.verifyDetached(
            signedBytes: signed,
            armoredSignature: signature,
            signerKeys: [TestPgpFixtures.unrelatedPublicKey]
        )
        #expect(!wrongKey.valid)

        // No offered key: a signature is present (the caller only calls this
        // with one) but nothing can vouch for it.
        let noKey = crypto.verifyDetached(
            signedBytes: signed,
            armoredSignature: signature,
            signerKeys: []
        )
        #expect(noKey.present)
        #expect(!noKey.valid)
    }

    // MARK: - Fingerprints

    @Test func readsTheFingerprintGpgReports() {
        #expect(
            crypto.fingerprint(ofArmoredPublicKey: TestPgpFixtures.armoredPublic)?
                .caseInsensitiveCompare(TestPgpFixtures.fingerprint) == .orderedSame
        )
    }

    /// nil, never an empty string that could compare equal to another absence.
    @Test func anUnparseableKeyHasNoFingerprint() {
        #expect(crypto.fingerprint(ofArmoredPublicKey: "garbage") == nil)
        #expect(crypto.fingerprint(ofArmoredPublicKey: "") == nil)
    }

    // MARK: - Writing

    @Test func encryptsBackToSomethingItCanRead() throws {
        let armored = try crypto.encryptAndSign(
            plaintext: Data("round trip".utf8),
            recipientKeys: [TestPgpFixtures.armoredPublic],
            privateKey: privateKey
        )
        #expect(armored.hasPrefix("-----BEGIN PGP MESSAGE-----"))

        let result = try crypto.decrypt(
            armoredCiphertext: armored,
            privateKey: privateKey,
            signerKeys: [TestPgpFixtures.armoredPublic]
        )
        #expect(String(decoding: result.body, as: UTF8.self) == "round trip")
        #expect(result.signature.valid)
    }

    @Test func refusesToEncryptWithNoUsableRecipient() {
        #expect(throws: PgpCryptoError.self) {
            try crypto.encryptAndSign(
                plaintext: Data("x".utf8),
                recipientKeys: ["garbage"],
                privateKey: privateKey
            )
        }
    }

    /// The Sent copy is encrypted to this, never to a key the server supplied
    /// — a hostile server offering "your" key would otherwise get a readable
    /// copy of everything sent.
    @Test func exportsItsOwnPublicHalf() throws {
        let armored = try crypto.ownPublicKey(privateKey: privateKey)
        #expect(armored.hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))
        #expect(!armored.contains("PRIVATE"))
        #expect(
            crypto.fingerprint(ofArmoredPublicKey: armored)?
                .caseInsensitiveCompare(TestPgpFixtures.fingerprint) == .orderedSame
        )
    }

    @Test func aBrokenKeyCannotExportAPublicHalf() {
        #expect(throws: PgpCryptoError.unusableKey) {
            try crypto.ownPublicKey(privateKey: Data("garbage".utf8))
        }
    }
}
