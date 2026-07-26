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

    @Test func leadingNonKeyPacketsAreSkipped() {
        // A marker packet (tag 10, "PGP") ahead of the key packet.
        let marker = Data([0xCA, 0x03]) + Data("PGP".utf8)
        let packet = marker + Data([0xC6, UInt8(keyBody.count)]) + keyBody
        #expect(PgpFingerprint.compute(fromArmored: armored(packet)) == expectedFingerprint(for: keyBody))
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
