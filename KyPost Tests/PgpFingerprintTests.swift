//
//  PgpFingerprintTests.swift
//  KyPost Tests
//
//  Security-hardening Task 10: locally computed OpenPGP v4 fingerprints.
//  No GnuPG on the build machine, so the vectors are synthetic packets;
//  the expected digests are computed straight-line over
//  0x99 || len || body (the RFC 4880 formula) without going through the
//  armor/packet parsing under test.
//

import CryptoKit
import Foundation
import Testing
@testable import KyPost

/// v4 public-key packet body: version, creation time, algorithm (RSA),
/// MPI n (9 bits, 0x0123), MPI e (2 bits, 3). The parser never inspects
/// the key material, but the shape is kept real.
private let keyBody = Data([
    0x04,
    0x60, 0x00, 0x00, 0x00,
    0x01,
    0x00, 0x09, 0x01, 0x23,
    0x00, 0x02, 0x03,
])

private func expectedFingerprint(for body: Data) -> String {
    var message = Data([0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
    message.append(body)
    return Insecure.SHA1.hash(data: message).map { String(format: "%02X", $0) }.joined()
}

private func armored(_ packets: Data, headers: String = "Version: KyPostTest\n") -> String {
    """
    -----BEGIN PGP PUBLIC KEY BLOCK-----
    \(headers)
    \(packets.base64EncodedString())
    =ABCD
    -----END PGP PUBLIC KEY BLOCK-----
    """
}

@Suite struct PgpFingerprintTests {
    @Test func newFormatPacketMatchesTheStraightLineDigest() {
        let packet = Data([0xC6, UInt8(keyBody.count)]) + keyBody
        #expect(PgpFingerprint.compute(fromArmored: armored(packet)) == expectedFingerprint(for: keyBody))
    }

    @Test func theSharedSyntheticFixtureIsSelfConsistent() {
        // PgpQrTests' scan-flow fixture relies on this exact value.
        #expect(PgpFingerprint.compute(fromArmored: syntheticArmoredKey) == syntheticKeyFingerprint)
        #expect(syntheticKeyFingerprint == expectedFingerprint(for: keyBody))
    }

    @Test func oldFormatPacketParsesToo() {
        let packet = Data([0x98, UInt8(keyBody.count)]) + keyBody
        #expect(PgpFingerprint.compute(fromArmored: armored(packet)) == expectedFingerprint(for: keyBody))
    }

    @Test func leadingNonKeyPacketsAreRefusedNotSkipped() {
        // A marker packet (tag 10, "PGP") ahead of the key packet. Skipping to
        // the first tag 6 is what let a decoy packet hijack the fingerprint, so
        // the primary key packet has to open the stream.
        let marker = Data([0xCA, 0x03]) + Data("PGP".utf8)
        let packet = marker + Data([0xC6, UInt8(keyBody.count)]) + keyBody
        #expect(PgpFingerprint.compute(fromArmored: armored(packet)) == nil)
    }

    @Test func aDecoyKeyPacketAheadOfARealKeyIsRefused() {
        // The attack: a bare tag-6 packet carrying the fingerprint the user
        // will read off, concatenated with the key an OpenPGP consumer will
        // actually select (Go's ReadKeyRing skips the identity-less leading
        // entity). Returning the decoy's fingerprint here is what decoupled
        // the verified fingerprint from the key mail gets encrypted to.
        var otherBody = keyBody
        otherBody[1] = 0x61 // a different creation time => a different key
        let decoy = Data([0xC6, UInt8(keyBody.count)]) + keyBody
        let real = Data([0xC6, UInt8(otherBody.count)]) + otherBody
            + Data([0xCD, 0x03]) + Data("uid".utf8) // tag 13 user id

        #expect(PgpFingerprint.compute(fromArmored: armored(decoy + real)) == nil)
    }

    @Test func twoCompleteKeysInOneArmorAreRefused() {
        // Ambiguous: this client would fingerprint the first, gopenpgp rejects
        // the blob outright. Refuse rather than pick one.
        var otherBody = keyBody
        otherBody[1] = 0x61
        let first = Data([0xC6, UInt8(keyBody.count)]) + keyBody
            + Data([0xCD, 0x03]) + Data("uid".utf8)
        let second = Data([0xC6, UInt8(otherBody.count)]) + otherBody
            + Data([0xCD, 0x03]) + Data("uid".utf8)

        #expect(PgpFingerprint.compute(fromArmored: armored(first + second)) == nil)
    }

    @Test func aRealTransferableKeyStillParses() {
        // Primary key, user id, self-signature, subkey, binding signature —
        // the packet sequence gpg --export actually emits. The single-key rule
        // must not reject an ordinary key.
        let packets = Data([0xC6, UInt8(keyBody.count)]) + keyBody
            + Data([0xCD, 0x03]) + Data("uid".utf8)      // 13 user id
            + Data([0xC2, 0x02]) + Data([0x00, 0x01])    // 2  signature
            + Data([0xCE, UInt8(keyBody.count)]) + keyBody // 14 public subkey
            + Data([0xC2, 0x02]) + Data([0x00, 0x02])    // 2  binding signature

        #expect(PgpFingerprint.compute(fromArmored: armored(packets)) == expectedFingerprint(for: keyBody))
    }

    @Test func aV3KeyIsRefusedNotGuessed() {
        var v3Body = keyBody
        v3Body[0] = 0x03
        let packet = Data([0xC6, UInt8(v3Body.count)]) + v3Body
        #expect(PgpFingerprint.compute(fromArmored: armored(packet)) == nil)
    }

    @Test(arguments: [
        "not a key at all",
        "-----BEGIN PGP PUBLIC KEY BLOCK-----\n-----END PGP PUBLIC KEY BLOCK-----",
        "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n!!!not base64!!!\n-----END PGP PUBLIC KEY BLOCK-----",
        // Missing END line entirely.
        "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nxg0EYAAAAAEACQEjAAID",
    ])
    func malformedArmorReturnsNil(input: String) {
        #expect(PgpFingerprint.compute(fromArmored: input) == nil)
    }

    @Test func truncatedPacketsReturnNil() {
        // Header claims 13 bytes; only 4 follow.
        let truncated = Data([0xC6, UInt8(keyBody.count)]) + keyBody.prefix(4)
        #expect(PgpFingerprint.compute(fromArmored: armored(truncated)) == nil)
        // Partial body lengths are invalid for key material.
        let partial = Data([0xC6, 0xE1]) + keyBody
        #expect(PgpFingerprint.compute(fromArmored: armored(partial)) == nil)
        // Old-format indeterminate length is invalid too.
        let indeterminate = Data([0x9B]) + keyBody
        #expect(PgpFingerprint.compute(fromArmored: armored(indeterminate)) == nil)
    }
}
