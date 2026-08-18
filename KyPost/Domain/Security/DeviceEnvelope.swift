//
//  DeviceEnvelope.swift
//  KyPost
//
//  The sealed envelope a browser mints to hand this device the account's
//  OpenPGP private key. Swift port of kypost-android's pgp/DeviceEnvelope.kt.
//
//  Wire-compatible with the browser and with Android: the version tag, the
//  HKDF info string and the AAD layout move together, and changing one alone
//  strands every enrolled device.
//

import CryptoKit
import Foundation

/// Moves together with the version tag and the AAD prefix.
///
/// **v1 → v2:** the AAD stopped being pipe-delimited concatenation and became
/// length-prefixed. See `deviceEnvelopeAAD`.
let envelopeInfo = "kypost-device-envelope/v2"
private let envelopeVersion = "2"
private let envelopeAlgorithm = "ECDH-P256+HKDF-SHA256+A256GCM"
private let gcmTagBytes = 16

nonisolated struct DeviceEnvelopeFields: Equatable, Sendable {
    /// The browser's ephemeral public key, raw SEC1 (65 bytes, 0x04-prefixed).
    var epk: Data
    var iv: Data
    var ct: Data
}

/// Parses the envelope, returning nil for anything malformed, unsupported or
/// wrong-sized. **Nil means re-run the ceremony, never retry.**
///
/// The size and prefix checks match the browser, which requires exactly 65
/// bytes with an 0x04 prefix before it will import the point. Rejecting
/// compressed markers, the point at infinity and trailing junk here means the
/// ECDH layer is not the only thing standing between an attacker-supplied blob
/// and the key.
nonisolated func parseDeviceEnvelope(_ json: String) -> DeviceEnvelopeFields? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["v"] as? String == envelopeVersion,
          object["alg"] as? String == envelopeAlgorithm,
          let epkText = object["epk"] as? String,
          let ivText = object["iv"] as? String,
          let ctText = object["ct"] as? String,
          let epk = Data(base64Encoded: epkText),
          let iv = Data(base64Encoded: ivText),
          let ct = Data(base64Encoded: ctText)
    else { return nil }

    guard epk.count == 65, epk.first == 0x04 else { return nil }
    guard iv.count == 12, ct.count > gcmTagBytes else { return nil }
    return DeviceEnvelopeFields(epk: epk, iv: iv, ct: ct)
}

enum DeviceEnvelopeError: Error, Equatable {
    /// The fingerprint was not hex once normalised. A caller bug, not a
    /// hostile envelope — see the note below on why this validates rather
    /// than trusting the caller.
    case malformedFingerprint
    case fieldTooLongToLengthPrefix
}

/// Binds the sealing to this device and this identity, as **length-prefixed**
/// fields:
///
/// `info || uint16BE(len(deviceId)) || deviceId || uint16BE(len(fp)) || fp`
///
/// It used to be `info|deviceId|fingerprint` — unescaped pipe concatenation,
/// which is ambiguous: an envelope sealed under
/// (deviceId "dev|BADC0FFEE", fp "0123…") produces byte-identical AAD to one
/// sealed under (deviceId "dev", fp "BADC0FFEE|0123…"), and each opens under
/// the other. That was not exploitable as it stood — cross-device replay
/// already fails at the HKDF, whose salt is this device's own public key — but
/// it is a latent structural weakness of a class that produced real
/// key-binding CVEs in Matrix, which uses a structured transcript for exactly
/// this reason. Length prefixing removes the class rather than arguing about
/// reachability, at two bytes a field.
///
/// **Normalises and validates the fingerprint rather than trusting the
/// caller.** On Android this was a doc comment, and the repo's only
/// fingerprint producer returns *space-grouped* hex while the browser strips
/// whitespace before building its AAD — so the natural implementation produced
/// an AAD that could never authenticate, and the design's error table turns
/// that into "hostile or stale, no retry", which the browser reports as *"the
/// key this server gave the browser is not the key on that device"*. A
/// formatting bug arriving as a substituted-key alarm trains users to dismiss
/// the one alarm this feature has. A doc comment is not a contract across
/// three implementations.
nonisolated func deviceEnvelopeAAD(
    deviceId: String,
    pgpFingerprint: String
) throws -> Data {
    let fingerprint = pgpFingerprint.uppercased().filter { !$0.isWhitespace }
    guard !fingerprint.isEmpty,
          fingerprint.allSatisfy({ $0.isHexDigit && $0.isASCII && !$0.isLowercase })
    else { throw DeviceEnvelopeError.malformedFingerprint }

    let info = Data(envelopeInfo.utf8)
    let id = Data(deviceId.utf8)
    let fp = Data(fingerprint.utf8)
    guard id.count <= 0xFFFF, fp.count <= 0xFFFF else {
        throw DeviceEnvelopeError.fieldTooLongToLengthPrefix
    }

    var aad = Data()
    aad.append(info)
    aad.append(bigEndianUInt16(id.count))
    aad.append(id)
    aad.append(bigEndianUInt16(fp.count))
    aad.append(fp)
    return aad
}

/// Opens the envelope, or nil if GCM authentication fails.
///
/// A nil here is **hostile or stale, never a retry**: the AAD binds the
/// sealing to this device and this identity, so a failure means the envelope
/// was minted for someone else, or under an identity the account no longer
/// advertises.
///
/// `ownRawPublicKey` is the HKDF salt — this device's *own* raw 65-byte SEC1
/// point, not the ephemeral one in the envelope.
///
/// Returns bytes, not a String. `String(decoding:as:)` is silently lossy:
/// malformed bytes become U+FFFD and the call still succeeds, which reads as
/// success while handing back different bytes than were sealed. The plaintext
/// here is an OpenPGP private key; its lifetime belongs to the caller.
nonisolated func openDeviceEnvelope(
    sharedSecret: SharedSecret,
    ownRawPublicKey: Data,
    fields: DeviceEnvelopeFields,
    aad: Data
) -> Data? {
    let key = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: ownRawPublicKey,
        sharedInfo: Data(envelopeInfo.utf8),
        outputByteCount: 32
    )
    guard let box = try? AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: fields.iv),
        ciphertext: fields.ct.dropLast(gcmTagBytes),
        tag: fields.ct.suffix(gcmTagBytes)
    ) else { return nil }
    return try? AES.GCM.open(box, using: key, authenticating: aad)
}

nonisolated func bigEndianUInt16(_ value: Int) -> Data {
    Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
}
