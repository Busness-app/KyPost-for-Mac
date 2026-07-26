//
//  PinnedSessionDelegate.swift
//  KyPost
//
//  TOFU certificate pinning for the relay connection (security-hardening
//  plan, Task 9). kypost is self-hosted with a per-user srv URL captured
//  at pairing, so a hardcoded pin can't work; instead the leaf SPKI
//  SHA-256 seen during the pairing handshake is stored, and every later
//  request to that host must present the same key.
//
//  Scope and limits, same as Android's: protects against MITM *after*
//  pairing; the initial pairing trusts whatever srv URL the scanned code
//  carried. Pin checks apply only to the paired relay host — scanned
//  foreign key-exchange URLs (ScanPgpKeyView) get default TLS handling.
//

import CryptoKit
import Foundation
import Security

nonisolated final class PinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// The pin to enforce for a host, or nil for TOFU/default handling.
    private let pinnedHash: @Sendable (_ host: String) -> String?

    private let lock = NSLock()
    private var lastSeenByHost: [String: String] = [:]
    private var pinFailed = false

    init(pinnedHash: @escaping @Sendable (_ host: String) -> String?) {
        self.pinnedHash = pinnedHash
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let hash = Self.spkiSHA256(of: trust)
        else {
            // Not a server-trust challenge, or an unreadable key shape:
            // let the system's normal TLS evaluation decide.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        lock.lock()
        lastSeenByHost[host] = hash
        lock.unlock()

        if let pinned = pinnedHash(host), pinned != hash {
            lock.lock()
            pinFailed = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    /// The SPKI hash observed on the most recent handshake with `host` —
    /// the value the pairing flow persists (trust on first use).
    func lastSeenHash(forHost host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastSeenByHost[host]
    }

    /// Reads and clears the pin-failure flag, so HTTPClient can map the
    /// resulting URLError.cancelled to certificateMismatch.
    func consumePinFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let failed = pinFailed
        pinFailed = false
        return failed
    }

    // MARK: - SPKI hashing

    static func spkiSHA256(of trust: SecTrust) -> String? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        return spkiSHA256(ofCertificate: leaf)
    }

    /// Lowercase hex SHA-256 over the DER SubjectPublicKeyInfo — the same
    /// value `openssl x509 -pubkey | openssl pkey -pubin -outform DER |
    /// openssl dgst -sha256` prints. SecKeyCopyExternalRepresentation
    /// returns the raw key (PKCS#1/X9.63), so the fixed ASN.1 header for
    /// the key's type and size is prepended to reconstruct the SPKI.
    static func spkiSHA256(ofCertificate certificate: SecCertificate) -> String? {
        guard
            let key = SecCertificateCopyKey(certificate),
            let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
            let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        guard let header = spkiHeader(
            keyType: attributes[kSecAttrKeyType] as? String,
            keySizeInBits: attributes[kSecAttrKeySizeInBits] as? Int
        ) else { return nil }

        var spki = Data(header)
        spki.append(keyData)
        return SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    /// Fixed SPKI prefixes per key shape (the TrustKit table). Unknown
    /// shapes return nil and fall back to default TLS handling — never a
    /// wrong hash.
    private static func spkiHeader(keyType: String?, keySizeInBits: Int?) -> [UInt8]? {
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        switch (keyType, keySizeInBits) {
        case (rsa, 2048):
            return [
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
            ]
        case (rsa, 3072):
            return [
                0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x8f, 0x00,
            ]
        case (rsa, 4096):
            return [
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
            ]
        case (ec, 256):
            return [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00,
            ]
        case (ec, 384):
            return [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
            ]
        default:
            return nil
        }
    }
}
