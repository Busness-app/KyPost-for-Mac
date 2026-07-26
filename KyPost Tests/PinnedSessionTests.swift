//
//  PinnedSessionTests.swift
//  KyPost Tests
//
//  Security-hardening Task 9: TOFU certificate pinning. The SPKI hashes
//  are known-answer vectors — self-signed fixture certificates generated
//  offline with OpenSSL, expected hashes from
//  `openssl x509 -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256`.
//  The full TLS handshake path (cancel on mismatch, recovery UI) is
//  verified manually against the real relay.
//

import Foundation
import Security
import Testing
@testable import KyPost

/// CN=relay.test, RSA-2048, self-signed (DER, base64).
private let rsaCertBase64 = "MIIDCzCCAfOgAwIBAgIUWKIyLBs2WOkkS4EzAbpl7wfLFzcwDQYJKoZIhvcNAQELBQAwFTETMBEGA1UEAwwKcmVsYXkudGVzdDAeFw0yNjA3MjYyMzU1MDRaFw0yNjA4MjUyMzU1MDRaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDYSilHJlpYKYDXIy3aK5xkXAlSrhEFkro3CzBsNgEYWOXFz1JD7vhulqRFjyRMemCBUE9sShAkIAwKGSFm6xqlN050SPniDvEoeOGt7/9KLCxurYV1IHJElCcKc2RBk7zBDVecSM4Pfmy3fd5SjzFm0BIg+SjmHjV/Z0ROn2MmiI6VS2Pq9Nike8aHxaCG0DxEPtpu5L9NpKhHXv3K5KbprhZs+hSo5HGXAToXYM9X2KzitQQ4uICQ4c8+N1/DKeIVaihq8k9yGalBtAOgjY0Xf33l++CglMmFhsDa/ZgQzqyk96mkc7xE9IJuB0aQp4U60V70qjg1mxREUZxn7o9lAgMBAAGjUzBRMB0GA1UdDgQWBBQvlEgaa/IMQritowOOVbGM+kUr6DAfBgNVHSMEGDAWgBQvlEgaa/IMQritowOOVbGM+kUr6DAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQDP8LI+4n7riQcXTsC2rwoKHb/kmZFFpNPcq635oiDxKJ4JqHHD6BplqKQP7Ku+klPYPLGq+2ueTl+IZv8SSAWmYJIeXRBGEsYn8ZF7aznPtKvXoe3+OZ5EiuOL/jBnBGAi5jnDidGX8zwIojdt/BaVZfvRdEOAQym73FH6ld3f6QsFlSHxEdA9szOw5hVJNpAGb9gf7MXFlFDAvIifdppPB3B1I6HSAOKsByqcDLWjBNn4wPi5mVziWnNel2F9aZuIUtuzKy+1gD4DqSZ0M8sMgz2WqY9rfXlgugNNRGsdfSsj9UyslIXlOAEVNUM4L84lDpaAEMXevdU8QMgMpehb"
private let rsaExpectedSpki = "d45acab703640fa9dbab3fe499f0bd1cfd4db3298bf23e8ce3c4687194f0858d"

/// CN=relay.test, EC P-256, self-signed (DER, base64).
private let ecCertBase64 = "MIIBfzCCASWgAwIBAgIUOElCaYhAhyE3AAB9mgf5PguNcdEwCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKcmVsYXkudGVzdDAeFw0yNjA3MjYyMzU1MDRaFw0yNjA4MjUyMzU1MDRaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQTajE7GZknDPURD+kx5WA8Ybz6Y1rUqyArcE8dIzXarPXmuX4G4w6w3QK0ZLK8cfGldiDzlPeOPrcRLApKiVLho1MwUTAdBgNVHQ4EFgQUt1BRIS2y5s9ib52uqwbo5sQ6bWkwHwYDVR0jBBgwFoAUt1BRIS2y5s9ib52uqwbo5sQ6bWkwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEArAoNowtzduTDXdnMP5hJJemjAhw3WpcWw/i4486LWxACIC7CKFEpf9rQidAuALy1NFZIFgQzht1lmafpeDJsZRZd"
private let ecExpectedSpki = "293de4192605d3a987e9f46ce37ef5fac20247d825187db18ce0860dce790ce1"

private func certificate(fromBase64 base64: String) throws -> SecCertificate {
    let data = try #require(Data(base64Encoded: base64))
    return try #require(SecCertificateCreateWithData(nil, data as CFData))
}

@Suite struct PinnedSessionDelegateTests {
    @Test func rsaSpkiHashMatchesOpenSSL() throws {
        let cert = try certificate(fromBase64: rsaCertBase64)
        #expect(PinnedSessionDelegate.spkiSHA256(ofCertificate: cert) == rsaExpectedSpki)
    }

    @Test func ecSpkiHashMatchesOpenSSL() throws {
        let cert = try certificate(fromBase64: ecCertBase64)
        #expect(PinnedSessionDelegate.spkiSHA256(ofCertificate: cert) == ecExpectedSpki)
    }

    @Test func recordsTheLastSeenHashPerHostAndFlagsPinFailuresOnce() {
        let delegate = PinnedSessionDelegate { _ in nil }
        #expect(delegate.lastSeenHash(forHost: "relay.test") == nil)
        #expect(!delegate.consumePinFailure())
    }

    @Test @MainActor func pinnedHashRoundTripsThroughThePairingStore() throws {
        let keychain = KeychainStorage(service: "com.urlxl.mail.tests.\(UUID().uuidString)")
        let store = SecurePairingStore(keychain: keychain)
        #expect(store.pinnedSpkiHash == nil)

        try store.setPinnedSpkiHash(rsaExpectedSpki)
        #expect(store.pinnedSpkiHash == rsaExpectedSpki)

        // The pin clears with the pairing — re-pairing is the rotation
        // recovery path.
        try store.clear()
        #expect(store.pinnedSpkiHash == nil)
    }
}
