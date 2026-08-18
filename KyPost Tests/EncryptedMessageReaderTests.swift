//
//  EncryptedMessageReaderTests.swift
//  KyPost Tests
//
//  The exit table, one test per row. These run with fakes because
//  EncryptedMessageReader has no platform imports — which is the whole reason
//  it was written that way.
//

import Foundation
import Testing
@testable import KyPost

// MARK: - Fakes

private struct FakeOpener: VaultOpening {
    let outcome: VaultOpenOutcome
    func open() async -> VaultOpenOutcome { outcome }
}

private struct FakePayloads: PgpPayloadSource {
    let result: PgpPayloadResult
    var thrown: (any Error)?
    func fetch(mailbox: String, messageId: String) async throws -> PgpPayloadResult {
        if let thrown { throw thrown }
        return result
    }
}

private struct FakeCrypto: PgpDecrypting {
    var body = Data("plaintext".utf8)
    var signature = RawSignature()
    var error: PgpCryptoError?
    var fingerprints: [String: String] = [:]

    func decrypt(
        armoredCiphertext: String,
        privateKey: Data,
        signerKeys: [String]
    ) throws -> DecryptedMessage {
        if let error { throw error }
        return DecryptedMessage(body: body, signature: signature)
    }

    func fingerprint(ofArmoredPublicKey key: String) -> String? { fingerprints[key] }
}

private let mimeBody = Data("Content-Type: text/plain\r\n\r\nhello\r\n".utf8)

private func makeReader(
    opener: VaultOpenOutcome = .opened(privateKey: Data("KEY".utf8)),
    payload: PgpPayloadResult = .success(PgpPayload(encryptedPayload: "CIPHERTEXT")),
    crypto: FakeCrypto = FakeCrypto(body: mimeBody),
    thrown: (any Error)? = nil,
    session: EnrollmentSession
) -> EncryptedMessageReader {
    EncryptedMessageReader(
        opener: FakeOpener(outcome: opener),
        payloads: FakePayloads(result: payload, thrown: thrown),
        crypto: crypto,
        session: session
    )
}

/// A session per test. `EnrollmentSession.shared` is process-wide by design,
/// and tests that shared it would leak a held key into each other.
private func freshSession() -> EnrollmentSession { EnrollmentSession() }

// MARK: - Tests

@Suite(.serialized) struct EncryptedMessageReaderTests {

    /// The automatic attempt when a screen opens must not raise a prompt. Only
    /// a deliberate Decrypt may do that.
    @Test func anAutomaticAttemptWithNoHeldKeyAsksForUnlockRatherThanPrompting() async {
        let reader = makeReader(opener: .cancelled, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: false
        )
        #expect(outcome == .needsUnlock)
    }

    /// Dismissing a sheet you raised is not an error, and the screen goes back
    /// to offering Decrypt.
    @Test func cancellingTheUnlockIsNotAnError() async {
        let reader = makeReader(opener: .cancelled, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .cancelled)
        #expect(!readOutcomeAllowsRetry(outcome))
    }

    @Test func notEnrolledIsItsOwnRow() async {
        let reader = makeReader(opener: .notEnrolled, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .notEnrolled
        )
    }

    @Test func noSecureLockScreenIsItsOwnRow() async {
        let reader = makeReader(opener: .noSecureLockScreen, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .noSecureLockScreen
        )
    }

    @Test func anUnsealFailureCarriesItsMessage() async {
        let reader = makeReader(opener: .failed("enclave busy"), session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .unsealFailed("enclave busy")
        )
    }

    @Test func tooLargeIsItsOwnRow() async {
        let reader = makeReader(payload: .tooLarge, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .tooLarge
        )
    }

    @Test func notClientProtectedIsItsOwnRow() async {
        let reader = makeReader(payload: .notClientProtected, session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .notClientProtected
        )
    }

    /// Terminal, and the UI must not offer Retry: the server has the message
    /// and it carries no OpenPGP payload, so retrying cannot change it.
    @Test func noEncryptedContentIsTerminalAndNotRetryable() async {
        let reader = makeReader(payload: .noPayload, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .noEncryptedContent)
        #expect(!readOutcomeAllowsRetry(outcome))
    }

    /// Unlike the row above, a transport failure is worth retrying.
    @Test func aFetchFailureIsRetryable() async {
        let reader = makeReader(payload: .failed("offline"), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(outcome == .fetchFailed("offline"))
        #expect(readOutcomeAllowsRetry(outcome))
    }

    @Test func aThrownFetchIsAFetchFailureRatherThanACrash() async {
        struct Boom: Error {}
        let reader = makeReader(thrown: Boom(), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        if case .fetchFailed = outcome {} else {
            Issue.record("expected fetchFailed, got \(outcome)")
        }
    }

    @Test func aDecryptFailureSaysWhichKindItWas() async {
        let reader = makeReader(
            crypto: FakeCrypto(error: .cannotDecrypt), session: freshSession()
        )
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .decryptFailed("this message is not encrypted to a key on this device")
        )
    }

    /// One message failing says nothing about the held key, and clearing would
    /// re-prompt for every later message.
    @Test func aDecryptFailureDoesNotDropTheHeldKey() async {
        let session = freshSession()
        let reader = makeReader(crypto: FakeCrypto(error: .cannotDecrypt), session: session)
        _ = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        #expect(session.isHeld)
    }

    /// The size cap surfaces as its own row even when it is the crypto layer
    /// that spots it, not the fetch.
    @Test func aZipBombFoundDuringDecryptionIsTooLarge() async {
        let reader = makeReader(crypto: FakeCrypto(error: .tooLarge), session: freshSession())
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .tooLarge
        )
    }

    @Test func aBodyThatWillNotParseIsADecryptFailureRatherThanAnEmptyPage() async {
        let reader = makeReader(
            crypto: FakeCrypto(body: Data()), session: freshSession()
        )
        #expect(
            await reader.read(mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true)
                == .decryptFailed("this message could not be read once decrypted")
        )
    }

    // MARK: - The happy path and what it reports

    @Test func aDecryptedMessageCarriesItsBodyAndResolvedSender() async throws {
        let payload = PgpPayload(
            encryptedPayload: "CIPHERTEXT",
            resolvedSender: "bob@example.com",
            rawSender: "Bob (Eve <eve@evil>) <bob@example.com>"
        )
        let reader = makeReader(payload: .success(payload), session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: payload.rawSender, unlockIfNeeded: true
        )
        guard case .decrypted(let body, _, let resolvedSender) = outcome else {
            Issue.record("expected decrypted, got \(outcome)")
            return
        }
        #expect(body.plain?.contains("hello") == true)
        // The verdict is about what the SERVER resolved, never the raw From.
        #expect(resolvedSender == "bob@example.com")
    }

    /// A held key means no prompt, so a second read does not re-authenticate.
    @Test func aHeldKeySkipsTheUnlockEntirely() async {
        let session = freshSession()
        session.put(armoredKey: "ALREADY-HELD")
        // An opener that would fail if it were consulted at all.
        let reader = makeReader(opener: .failed("should not be called"), session: session)
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: false
        )
        if case .decrypted = outcome {} else {
            Issue.record("expected decrypted without unlocking, got \(outcome)")
        }
    }

    /// A conflicted key carries no key material and must never be offered to a
    /// signature check — but it stays in `signerKeys` so the verdict can be
    /// `.keyChanged` rather than a silent "unknown signer".
    @Test func aConflictedKeyYieldsKeyChanged() async {
        let payload = PgpPayload(
            encryptedPayload: "CIPHERTEXT",
            signerKeys: [SignerKey(publicKey: "", conflict: true)]
        )
        let crypto = FakeCrypto(
            body: mimeBody,
            signature: RawSignature(present: true, valid: true, signerFingerprint: "FPR1")
        )
        let reader = makeReader(payload: .success(payload), crypto: crypto, session: freshSession())
        let outcome = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        )
        guard case .decrypted(_, let signature, _) = outcome else {
            Issue.record("expected decrypted, got \(outcome)")
            return
        }
        #expect(signature == .keyChanged)
    }

    @Test func aVerifiedSignatureReachesTheVerdict() async {
        let payload = PgpPayload(
            encryptedPayload: "CIPHERTEXT",
            signerKeys: [SignerKey(publicKey: "k", verified: true)]
        )
        let crypto = FakeCrypto(
            body: mimeBody,
            signature: RawSignature(present: true, valid: true, signerFingerprint: "FPR1"),
            fingerprints: ["k": "FPR1"]
        )
        let reader = makeReader(payload: .success(payload), crypto: crypto, session: freshSession())
        guard case .decrypted(_, let signature, _) = await reader.read(
            mailbox: "INBOX", messageId: "1", sender: "a@b", unlockIfNeeded: true
        ) else {
            Issue.record("expected decrypted")
            return
        }
        #expect(signature == .verifiedConfirmed)
    }
}

// MARK: - Session

@Suite(.serialized) struct EnrollmentSessionTests {
    @Test func aHeldKeyIsLentRatherThanReturned() {
        let session = EnrollmentSession()
        #expect(!session.isHeld)
        session.put(armoredKey: "SECRET")
        #expect(session.isHeld)
        session.withKey { key in
            #expect(key.map { String(decoding: $0, as: UTF8.self) } == "SECRET")
        }
    }

    @Test func clearingForgetsIt() {
        let session = EnrollmentSession()
        session.put(armoredKey: "SECRET")
        session.clear()
        #expect(!session.isHeld)
        session.withKey { #expect($0 == nil) }
    }

    /// Replacing must not strand the previous key.
    @Test func replacingAKeyDoesNotKeepTheOldOne() {
        let session = EnrollmentSession()
        session.put(armoredKey: "FIRST")
        session.put(armoredKey: "SECOND")
        session.withKey { key in
            #expect(key.map { String(decoding: $0, as: UTF8.self) } == "SECOND")
        }
    }

    /// Presence is answered without materialising the key.
    @Test func presenceDoesNotRequireACopy() {
        let session = EnrollmentSession()
        session.put(armoredKey: "SECRET")
        #expect(session.isHeld)
        session.clear()
        #expect(!session.isHeld)
    }
}
