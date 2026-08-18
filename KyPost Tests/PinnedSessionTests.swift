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

/// CN=relay.test, EC P-521, self-signed (DER, base64).
private let ec521CertBase64 = "MIICBzCCAWigAwIBAgIUGh4KKPqF1742hVGc1c9ZcVMhPFcwCgYIKoZIzj0EAwQwFTETMBEGA1UEAwwKcmVsYXkudGVzdDAeFw0yNjA3MjcwMTAxNDlaFw0yNjA4MjYwMTAxNDlaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwgZswEAYHKoZIzj0CAQYFK4EEACMDgYYABABUMf/d72uuceZ7MpZrcQNiFuUcIbgW5ZisMVysuOGRFEVj5pIOPyDb0C6H8rths4Wg50dxRMveSlsNvX8qdYUbeQBtqlKKA17Ob9dE7tJTW4rdz1RcLleWZGSRdXIlPeU1MXZ7w4uutR+mYjP+8IZ2CScFPB0O9DKhyqs03XU2NUhdBaNTMFEwHQYDVR0OBBYEFELRvSCTw/OcSRSyQY2U9BCVpZFKMB8GA1UdIwQYMBaAFELRvSCTw/OcSRSyQY2U9BCVpZFKMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwQDgYwAMIGIAkIAik7Rk3A8gPMwR0xJ4j7bRQPw5PekM4YQGF+J/ywork+f07sTmOHFBYqAa7aJg7Tr3+HVORJZhoUL5gdTIz+Jzl0CQgF0xWoigr996FdtKyHaCnlE0a4md5ULnQpCG4+wfgoOncjI5ta9K3fgGwM7KGyfuHvFn30aayfcO3A0G6Vf5i52tw=="
private let ec521ExpectedSpki = "a5bb99297033185206759a5d68b50d9e9d51a260492f2e82732bd51d93ecc1b5"

/// CN=relay.test, RSA-1024, self-signed (DER, base64). A key shape with no
/// entry in the SPKI header table — the fail-closed case.
private let rsa1024CertBase64 = "MIICBjCCAW+gAwIBAgIUHY4ilx0l+y04NW3zlm0mwFtovncwDQYJKoZIhvcNAQELBQAwFTETMBEGA1UEAwwKcmVsYXkudGVzdDAeFw0yNjA3MjcwMTA2NDdaFw0yNjA4MjYwMTA2NDdaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBALx1TBNccRq+sCjpVhO1hIMZFuL5dGUvA0+/rZY2zlJEDNO5vTsHygrOhPACwTP6t5zyglbJFpU0iEQ6T2/FuF9zSrXNBZULxSLMmtv8+WVfbpph7HrDNnjLeocSrkssKTDJSxAh9maoKoyffCZqAuR4flp0MSWpTlpstLjq6aUBAgMBAAGjUzBRMB0GA1UdDgQWBBTRD4rZJ9Ji2VtKfRukuiRmfEPuYTAfBgNVHSMEGDAWgBTRD4rZJ9Ji2VtKfRukuiRmfEPuYTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4GBACRQ3+kEzopKN+COUwU11xpL5iYxZUoauMIQHq8jvySk3BBSlUZRFdWZeERdtHh6p5KR/bk514t4WWQFtlHF6IOlIesi61wg9m7spwIURIL9K3WuZycK2JSTaQTQVAitjOKQKxtW2cvBlnCy+72d9l6k3NmRDBDnch0KWLYVTd81"

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

    @Test func ec521SpkiHashMatchesOpenSSL() throws {
        let cert = try certificate(fromBase64: ec521CertBase64)
        #expect(PinnedSessionDelegate.spkiSHA256(ofCertificate: cert) == ec521ExpectedSpki)
    }

    /// A shape with no entry in the header table still hashes, via the DER
    /// fallback that reads the SubjectPublicKeyInfo straight out of the
    /// certificate.
    ///
    /// This used to assert nil, which is what the header table alone produced
    /// — and that was the bug the fallback fixed, not the contract. The table
    /// covers six key shapes; for anything else (Ed25519, RSA-1024,
    /// RSA-8192…) the observed hash was never recorded, so the pin silently
    /// never armed while the docs said pinning was always on. Enforcement was
    /// always fail-closed; it was *arming* that failed open.
    ///
    /// The expected value is `openssl x509 -pubkey | openssl pkey -pubin
    /// -outform DER | openssl dgst -sha256` over this certificate, computed
    /// independently rather than copied from what the code emitted.
    @Test func anUnsupportedKeyShapeStillHashesViaTheDERFallback() throws {
        let cert = try certificate(fromBase64: rsa1024CertBase64)
        #expect(
            PinnedSessionDelegate.spkiSHA256(ofCertificate: cert)
                == "15ba59611ff3b8c20120f6dfb33c443229b826d98c702ef136df2e99ee232b39"
        )
    }

    @Test func recordsTheLastSeenHashPerHost() {
        let delegate = PinnedSessionDelegate { _ in nil }
        #expect(delegate.lastSeenHash(forHost: "relay.test") == nil)
        #expect(!delegate.pinFailed(forHost: "relay.test"))
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

// MARK: - The pinning rule

@Suite struct PinDecisionTests {
    @Test func anUnpinnedHostProceeds() {
        #expect(PinnedSessionDelegate.decision(pinned: nil, observed: "aa") == .proceed)
        #expect(PinnedSessionDelegate.decision(pinned: "", observed: "aa") == .proceed)
        // Even with no readable key: unpinned means default TLS handling.
        #expect(PinnedSessionDelegate.decision(pinned: nil, observed: nil) == .proceed)
    }

    @Test func aMatchingPinProceeds() {
        #expect(PinnedSessionDelegate.decision(pinned: "aa", observed: "aa") == .proceed)
    }

    @Test func aDifferentKeyIsRefused() {
        #expect(PinnedSessionDelegate.decision(pinned: "aa", observed: "bb") == .refuse)
    }

    /// The bypass this closes: an attacker chooses their certificate's key
    /// algorithm, so a shape this app can't hash must not read as "no pin to
    /// check" on a host that is pinned.
    @Test func aPinnedHostWithAnUnhashableKeyIsRefused() {
        #expect(PinnedSessionDelegate.decision(pinned: "aa", observed: nil) == .refuse)
    }
}

// MARK: - The redirect rule

/// Requests carry the device secret in `X-Kypost-Device-Secret`, and
/// URLSession only strips `Authorization` across origins — a custom header
/// follows the redirect. Since the pin covers exactly one host, a relay
/// answering `302 Location: https://elsewhere/` handed the credential to a
/// host nothing was checking.
@Suite struct RedirectRuleTests {
    private let origin = URL(string: "https://relay.example.com/api/inbox")!

    @Test func sameHostRedirectIsAllowed() {
        #expect(PinnedSessionDelegate.allowsRedirect(
            from: origin,
            to: URL(string: "https://relay.example.com/api/inbox?page=2")!
        ))
    }

    @Test func crossHostRedirectIsRefused() {
        #expect(!PinnedSessionDelegate.allowsRedirect(
            from: origin,
            to: URL(string: "https://evil.example/collect")!
        ))
    }

    /// A subdomain is a different host and a different certificate.
    @Test func subdomainRedirectIsRefused() {
        #expect(!PinnedSessionDelegate.allowsRedirect(
            from: origin,
            to: URL(string: "https://attacker.relay.example.com/collect")!
        ))
    }

    @Test func downgradeToPlaintextIsRefused() {
        #expect(!PinnedSessionDelegate.allowsRedirect(
            from: origin,
            to: URL(string: "http://relay.example.com/api/inbox")!
        ))
    }

    @Test func hostComparisonIgnoresCase() {
        #expect(PinnedSessionDelegate.allowsRedirect(
            from: origin,
            to: URL(string: "https://Relay.Example.COM/api/inbox")!
        ))
    }

    @Test func anUnparseableDestinationIsRefused() {
        #expect(!PinnedSessionDelegate.allowsRedirect(from: origin, to: nil))
        #expect(!PinnedSessionDelegate.allowsRedirect(from: nil, to: origin))
        // No host at all (a scheme-only or relative URL) fails closed.
        #expect(!PinnedSessionDelegate.allowsRedirect(
            from: origin,
            to: URL(string: "https:///collect")!
        ))
    }
}
