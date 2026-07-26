//
//  PgpFingerprint.swift
//  KyPost
//
//  Locally computed OpenPGP v4 fingerprints (security-hardening plan,
//  Task 10). A compromised relay could pair an armored key with an
//  unrelated fingerprint string, making the out-of-band "does this match?"
//  check verify a label with no cryptographic tie to the key actually
//  saved. Computing from the key's own bytes closes that.
//
//  V4 fingerprint = SHA-1 over 0x99 || 2-byte length || public-key packet
//  body (RFC 4880 §12.2). SHA-1 here is mandated by the OpenPGP spec, not
//  a hashing choice this app owns. Anything malformed returns nil — never
//  trust-and-fall-back to the relay's string.
//

import CryptoKit
import Foundation

enum PgpFingerprint {
    /// Uppercase hex fingerprint of the first public-key packet in an
    /// armored key, or nil when the armor or packet stream is malformed or
    /// the key isn't v4.
    static func compute(fromArmored armored: String) -> String? {
        guard
            let data = dearmor(armored),
            let body = firstPublicKeyPacketBody(in: data),
            body.first == 4, // v3 uses a different digest — refuse, don't guess
            body.count <= Int(UInt16.max)
        else { return nil }

        var message = Data([0x99, UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
        message.append(body)
        return Insecure.SHA1.hash(data: message)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    /// Strips the BEGIN/END lines, armor headers ("Version: …" up to the
    /// blank line), and the "=" CRC24 line, then base64-decodes the rest.
    static func dearmor(_ armored: String) -> Data? {
        let lines = armored
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard
            let begin = lines.firstIndex(of: "-----BEGIN PGP PUBLIC KEY BLOCK-----"),
            let end = lines[begin...].firstIndex(of: "-----END PGP PUBLIC KEY BLOCK-----"),
            end > begin + 1
        else { return nil }

        var base64 = ""
        var inHeaders = true
        for line in lines[(begin + 1)..<end] {
            if inHeaders {
                if line.isEmpty || line.contains(":") { continue }
                inHeaders = false
            }
            if line.isEmpty || line.hasPrefix("=") { continue }
            base64 += line
        }
        guard !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    /// Walks the packet stream to the first public-key packet (tag 6),
    /// handling both old- and new-format headers. Partial body lengths and
    /// indeterminate old-format lengths are invalid for key material.
    static func firstPublicKeyPacketBody(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let header = bytes[index]
            guard header & 0x80 != 0 else { return nil }
            index += 1

            let tag: UInt8
            let length: Int
            if header & 0x40 != 0 {
                // New format: tag in the low six bits, variable-width length.
                tag = header & 0x3F
                guard index < bytes.count else { return nil }
                let first = Int(bytes[index])
                index += 1
                switch first {
                case 0..<192:
                    length = first
                case 192...223:
                    guard index < bytes.count else { return nil }
                    length = ((first - 192) << 8) + Int(bytes[index]) + 192
                    index += 1
                case 255:
                    guard index + 4 <= bytes.count else { return nil }
                    length = bytes[index..<(index + 4)].reduce(0) { ($0 << 8) | Int($1) }
                    index += 4
                default:
                    return nil // 224–254: partial body lengths
                }
            } else {
                // Old format: tag in bits 5–2, length width in the low two.
                tag = (header >> 2) & 0x0F
                let widths = [1, 2, 4]
                let lengthType = Int(header & 0x03)
                guard lengthType < widths.count else { return nil } // 3: indeterminate
                let width = widths[lengthType]
                guard index + width <= bytes.count else { return nil }
                length = bytes[index..<(index + width)].reduce(0) { ($0 << 8) | Int($1) }
                index += width
            }

            guard length >= 0, index + length <= bytes.count else { return nil }
            if tag == 6 {
                return Data(bytes[index..<(index + length)])
            }
            index += length
        }
        return nil
    }
}
