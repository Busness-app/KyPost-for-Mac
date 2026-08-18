//
//  DeviceEnrollmentTests.swift
//  KyPost Tests
//

import CryptoKit
import Foundation
import Testing
@testable import KyPost

// MARK: - Envelope

@Suite struct DeviceEnvelopeParsingTests {
    private func envelope(
        v: String = "2",
        alg: String = "ECDH-P256+HKDF-SHA256+A256GCM",
        epk: Data = Data([0x04] + Array(repeating: UInt8(1), count: 64)),
        iv: Data = Data(repeating: 2, count: 12),
        ct: Data = Data(repeating: 3, count: 32)
    ) -> String {
        """
        {"v":"\(v)","alg":"\(alg)","epk":"\(epk.base64EncodedString())",
         "iv":"\(iv.base64EncodedString())","ct":"\(ct.base64EncodedString())"}
        """
    }

    @Test func parsesAWellFormedEnvelope() {
        let fields = parseDeviceEnvelope(envelope())
        #expect(fields?.epk.count == 65)
        #expect(fields?.iv.count == 12)
    }

    /// Nil means re-run the ceremony, never retry — so every malformed shape
    /// must land here rather than reaching the ECDH layer.
    @Test func rejectsAnythingUnsupportedOrWrongSized() {
        #expect(parseDeviceEnvelope(envelope(v: "1")) == nil)
        #expect(parseDeviceEnvelope(envelope(alg: "ECDH-P384+HKDF-SHA256+A256GCM")) == nil)
        #expect(parseDeviceEnvelope("not json") == nil)
        #expect(parseDeviceEnvelope("{}") == nil)
        // The browser requires exactly 65 bytes with an 0x04 prefix before it
        // will import the point; matching that here means the ECDH layer is
        // not the only thing standing between a hostile blob and the key.
        #expect(parseDeviceEnvelope(envelope(epk: Data(repeating: 4, count: 64))) == nil)
        #expect(parseDeviceEnvelope(
            envelope(epk: Data([0x02] + Array(repeating: UInt8(1), count: 64)))
        ) == nil, "a compressed-point marker must be refused")
        #expect(parseDeviceEnvelope(envelope(iv: Data(repeating: 2, count: 16))) == nil)
        // Ciphertext must exceed the GCM tag, or there is no plaintext at all.
        #expect(parseDeviceEnvelope(envelope(ct: Data(repeating: 3, count: 16))) == nil)
    }
}

@Suite struct DeviceEnvelopeAADTests {
    /// The ambiguity length-prefixing removes: under pipe concatenation these
    /// two produce byte-identical AAD, and each envelope opens under the
    /// other's binding.
    @Test func lengthPrefixingRemovesTheDelimiterAmbiguity() throws {
        let a = try deviceEnvelopeAAD(deviceId: "dev|BADC0FFEE", pgpFingerprint: "0123")
        let b = try deviceEnvelopeAAD(deviceId: "dev", pgpFingerprint: "BADC0FFEE0123")
        #expect(a != b)
    }

    /// The repo's fingerprint producer returns space-grouped hex while the
    /// browser strips whitespace, so an unnormalised AAD could never
    /// authenticate — and the failure surfaces as "the key this server gave
    /// the browser is not the key on that device", training users to dismiss
    /// the one alarm this feature has.
    @Test func normalisesSpacedAndLowercaseFingerprints() throws {
        let spaced = try deviceEnvelopeAAD(
            deviceId: "d1", pgpFingerprint: "abcd 1234 ABCD 1234"
        )
        let bare = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234ABCD1234")
        #expect(spaced == bare)
    }

    @Test func refusesAFingerprintThatIsNotHex() {
        #expect(throws: DeviceEnvelopeError.malformedFingerprint) {
            try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "not-a-fingerprint")
        }
        #expect(throws: DeviceEnvelopeError.malformedFingerprint) {
            try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "   ")
        }
    }

    @Test func bindsToBothTheDeviceAndTheIdentity() throws {
        let base = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD")
        let otherDevice = try deviceEnvelopeAAD(deviceId: "d2", pgpFingerprint: "ABCD")
        let otherIdentity = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "BEEF")
        #expect(base != otherDevice)
        #expect(base != otherIdentity)
    }
}

@Suite struct DeviceEnvelopeOpenTests {
    /// Seals exactly as the browser does, then opens it — the only way to know
    /// the HKDF salt, info string, AAD layout and GCM parameters all agree.
    private func seal(
        deviceKey: P256.KeyAgreement.PrivateKey,
        aad: Data,
        plaintext: Data
    ) throws -> (DeviceEnvelopeFields, SharedSecret) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ownRaw = deviceKey.publicKey.x963Representation
        let browserSecret = try ephemeral.sharedSecretFromKeyAgreement(
            with: deviceKey.publicKey
        )
        let key = browserSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ownRaw,
            sharedInfo: Data(envelopeInfo.utf8),
            outputByteCount: 32
        )
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        let fields = DeviceEnvelopeFields(
            epk: ephemeral.publicKey.x963Representation,
            iv: Data(box.nonce),
            ct: box.ciphertext + box.tag
        )
        let deviceSecret = try deviceKey.sharedSecretFromKeyAgreement(
            with: P256.KeyAgreement.PublicKey(x963Representation: fields.epk)
        )
        return (fields, deviceSecret)
    }

    @Test func opensAnEnvelopeSealedTheWayTheBrowserSealsIt() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let aad = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234")
        let plaintext = Data("-----BEGIN PGP PRIVATE KEY BLOCK-----".utf8)
        let (fields, secret) = try seal(deviceKey: deviceKey, aad: aad, plaintext: plaintext)

        let opened = openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: deviceKey.publicKey.x963Representation,
            fields: fields,
            aad: aad
        )
        #expect(opened == plaintext)
    }

    /// A failure is hostile or stale, never a retry: the AAD binds the sealing
    /// to this device and this identity.
    @Test func refusesAnEnvelopeBoundToAnotherIdentity() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let sealedAAD = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234")
        let (fields, secret) = try seal(
            deviceKey: deviceKey, aad: sealedAAD, plaintext: Data("secret".utf8)
        )
        let otherAAD = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "BEEF5678")

        #expect(openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: deviceKey.publicKey.x963Representation,
            fields: fields,
            aad: otherAAD
        ) == nil)
    }

    /// The HKDF salt is this device's own public key, which is what makes a
    /// cross-device replay fail even before the AAD is consulted.
    @Test func refusesAnEnvelopeMintedForAnotherDevice() throws {
        let deviceKey = P256.KeyAgreement.PrivateKey()
        let aad = try deviceEnvelopeAAD(deviceId: "d1", pgpFingerprint: "ABCD1234")
        let (fields, secret) = try seal(
            deviceKey: deviceKey, aad: aad, plaintext: Data("secret".utf8)
        )
        let otherDevice = P256.KeyAgreement.PrivateKey()

        #expect(openDeviceEnvelope(
            sharedSecret: secret,
            ownRawPublicKey: otherDevice.publicKey.x963Representation,
            fields: fields,
            aad: aad
        ) == nil)
    }
}

// MARK: - Enrollment code

@Suite struct DeviceEnrollmentCodeTests {
    private let key = Data([0x04] + (1...64).map(UInt8.init))

    @Test func isFourteenCrockfordCharacters() {
        let code = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        #expect(code.count == enrollmentCodeLength)
        // I, L, O and U are excluded so they cannot be confused with 1, 0, V.
        #expect(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
    }

    @Test func isDeterministicForOneBucket() {
        let first = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        let second = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        #expect(first == second)
    }

    @Test func changesWithEveryInput() {
        let base = deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 100)
        #expect(base != deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-1", bucket: 101))
        #expect(base != deviceEnrollmentCode(rawPublicKey: key, deviceId: "dev-2", bucket: 100))
        var otherKey = key
        otherKey[10] ^= 0xFF
        #expect(base != deviceEnrollmentCode(rawPublicKey: otherKey, deviceId: "dev-1", bucket: 100))
    }

    /// Length-prefixing the device id: without it, ("ab", bucket) and
    /// ("a", "b"-shifted) could share a preimage.
    @Test func theDeviceIdIsLengthPrefixedNotConcatenated() {
        #expect(
            deviceEnrollmentCode(rawPublicKey: key, deviceId: "ab", bucket: 1)
                != deviceEnrollmentCode(rawPublicKey: key, deviceId: "a", bucket: 1)
        )
    }

    @Test func bucketsAreTwoMinutesWide() {
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 0)) == 0)
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 119)) == 0)
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 120)) == 1)
        #expect(enrollmentBucket(at: Date(timeIntervalSince1970: 241)) == 2)
    }

    @Test func displaysAsTwoGroupsOfSeven() {
        #expect(formattedEnrollmentCode("ABCDEFGHJKMNPQ") == "ABCDEFG-HJKMNPQ")
    }
}
