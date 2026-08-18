//
//  PgpMessageStateTests.swift
//  KyPost Tests
//
//  Truth tables for the PGP state rule, row markers, signature-pill
//  visibility, and the webmail deep link.
//

import Foundation
import Testing
@testable import KyPost

@Suite struct PgpMessageStateRuleTests {
    @Test func plainMessageIsNone() {
        #expect(pgpMessageState(pgpEncrypted: false, pgpDecryptError: "", body: "Hello") == .none)
    }

    @Test func notEncryptedWinsEvenWithAnError() {
        // Guards against reordering the guard clause: an error on a
        // non-encrypted message is not a PGP state.
        #expect(pgpMessageState(pgpEncrypted: false, pgpDecryptError: "boom", body: nil) == .none)
    }

    @Test func encryptedWithNoBodyAndNoErrorIsClientProtected() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: nil) == .clientProtected)
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: "") == .clientProtected)
    }

    @Test func encryptedWithErrorIsDecryptFailed() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "no key", body: nil) == .decryptFailed)
    }

    @Test func errorIsCheckedBeforeBody() {
        // The ordering is load-bearing. The server populates the error and
        // leaves the body empty; if a body is somehow present too, the error
        // still wins. Reading this as decryptedByServer would render content
        // while an unreported failure sits beside it.
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "bad mac", body: "partial") == .decryptFailed)
    }

    @Test func encryptedWithBodyIsDecryptedByServer() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "", body: "Secret") == .decryptedByServer)
    }

    @Test func whitespaceOnlyErrorAndBodyCountAsBlank() {
        #expect(pgpMessageState(pgpEncrypted: true, pgpDecryptError: "   ", body: " \n ") == .clientProtected)
    }
}

@Suite struct PgpRowMarkerTests {
    @Test func onlyUnreadableStatesAreMarked() {
        #expect(pgpRowSymbol(.clientProtected) == "lock.fill")
        #expect(pgpRowSymbol(.decryptFailed) == "exclamationmark.triangle.fill")
        #expect(pgpRowSymbol(.none) == nil)
        // Deliberately unmarked: the row opens and reads normally, so in a
        // server-mode mailbox this would decorate nearly every row with
        // nothing the user can act on.
        #expect(pgpRowSymbol(.decryptedByServer) == nil)
    }

    @Test func accessibilityLabelsSpellOutTheState() {
        #expect(pgpRowAccessibilityLabel(state: .clientProtected, subject: "Invoice")
            == "Encrypted, can't be read in this app: Invoice")
        #expect(pgpRowAccessibilityLabel(state: .decryptFailed, subject: "Invoice")
            == "Encrypted, couldn't be decrypted: Invoice")
        #expect(pgpRowAccessibilityLabel(state: .none, subject: "Invoice") == nil)
        #expect(pgpRowAccessibilityLabel(state: .decryptedByServer, subject: "Invoice") == nil)
    }
}

@Suite struct PgpSignaturePillTests {
    @Test func shownOnlyWhenTheServerActuallyVerifiedPlaintext() {
        #expect(showsSignaturePill(state: .decryptedByServer, signed: true))
    }

    @Test func hiddenForClientProtectedEvenWhenServerClaimsSigned() {
        // THE rule most likely to be "fixed" by a later well-meaning edit.
        // For a client-protected message the server never saw the plaintext,
        // so pgpSigned/pgpVerified are not a verdict about content anyone
        // verified. Rendering "signature not verified" here would assert
        // something we have no basis for. See the design spec §1.
        #expect(showsSignaturePill(state: .clientProtected, signed: true) == false)
    }

    @Test func hiddenWhenDecryptFailed() {
        #expect(showsSignaturePill(state: .decryptFailed, signed: true) == false)
    }

    @Test func hiddenWhenNotSigned() {
        #expect(showsSignaturePill(state: .decryptedByServer, signed: false) == false)
        #expect(showsSignaturePill(state: .none, signed: false) == false)
    }
}

@Suite struct WebmailMessageURLTests {
    @Test func inboxOmitsTheMailboxParam() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "INBOX",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func inboxMatchIsCaseInsensitive() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "inbox",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func blankMailboxOmitsTheParam() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func nonInboxMailboxIsIncluded() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "Junk",
            messageId: "7"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?mailbox=Junk&message=7")
    }

    @Test func subfolderPathKeepsItsSlash() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com",
            mailbox: "Archive/Receipts",
            messageId: "7"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?mailbox=Archive/Receipts&message=7")
    }

    @Test func trailingSlashOnServerUrlIsNormalized() throws {
        let url = try #require(webmailMessageURL(
            serverUrl: "https://mail.example.com/",
            mailbox: "INBOX",
            messageId: "42"
        ))
        #expect(url.absoluteString == "https://mail.example.com/read?message=42")
    }

    @Test func blankMessageIdIsRejected() {
        #expect(webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: "") == nil)
    }

    @Test func unusableServerUrlIsRejected() {
        // Callers render "no button" rather than a dead one.
        #expect(webmailMessageURL(serverUrl: "", mailbox: "INBOX", messageId: "42") == nil)
        #expect(webmailMessageURL(serverUrl: "not a url", mailbox: "INBOX", messageId: "42") == nil)
    }
}

// MARK: - Webmail mailbox links (compose handoff)

@Suite struct WebmailMailboxURLTests {
    @Test func draftsGetsAnExplicitMailboxParam() {
        #expect(
            webmailMailboxURL(serverUrl: "https://mail.example.com", mailbox: StandardFolder.drafts)?
                .absoluteString == "https://mail.example.com/read?mailbox=Drafts"
        )
    }

    @Test func inboxIsSentAsAnAbsentMailboxParam() {
        #expect(
            webmailMailboxURL(serverUrl: "https://mail.example.com/", mailbox: "INBOX")?
                .absoluteString == "https://mail.example.com/read"
        )
    }

    @Test func aServerUrlThatIsNotAbsoluteHasNoLink() {
        #expect(webmailMailboxURL(serverUrl: "", mailbox: "Drafts") == nil)
        #expect(webmailMailboxURL(serverUrl: "not a url", mailbox: "Drafts") == nil)
    }

    /// The message link keeps working exactly as it did — mailbox first, then
    /// message — now that both share one components builder.
    @Test func messageLinksAreUnchanged() {
        #expect(
            webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "Archive", messageId: "42")?
                .absoluteString == "https://mail.example.com/read?mailbox=Archive&message=42"
        )
        #expect(
            webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: "42")?
                .absoluteString == "https://mail.example.com/read?message=42"
        )
        #expect(webmailMessageURL(serverUrl: "https://mail.example.com", mailbox: "INBOX", messageId: " ") == nil)
    }
}

// MARK: - Signature trust model (Phase 6)

@Suite struct PgpSignatureStateTests {
    /// Stands in for the OpenPGP key-id extraction the crypto core will
    /// supply: maps an armored key to the ids it contains.
    private func keyIDs(_ table: [String: Set<String>]) -> (String) -> Set<String> {
        { table[$0] ?? [] }
    }

    private func signature(
        present: Bool = true,
        valid: Bool = true,
        keyID: String = "AAAA"
    ) -> RawSignature {
        RawSignature(present: present, valid: valid, signerKeyID: keyID)
    }

    @Test func anUnsignedMessageSaysNothing() {
        #expect(signatureState(
            signature: signature(present: false),
            signerKeys: [SignerKey(publicKey: "k")],
            keyIDs: keyIDs(["k": ["AAAA"]])
        ) == .none)
    }

    /// Not an accusation: an ordinary correspondent not yet in the address
    /// book, a rotated key, and a forgery are locally indistinguishable.
    @Test func noBoundKeyIsUnknownRatherThanInvalid() {
        #expect(signatureState(
            signature: signature(), signerKeys: [], keyIDs: keyIDs([:])
        ) == .signerUnknown)

        // Bound keys exist, but none of them made this signature.
        #expect(signatureState(
            signature: signature(keyID: "ZZZZ"),
            signerKeys: [SignerKey(publicKey: "k")],
            keyIDs: keyIDs(["k": ["AAAA"]])
        ) == .signerUnknown)
    }

    /// The one alarm worth raising, and it outranks a good key for the same
    /// sender — reporting the survivor as verified would hide exactly the
    /// event worth reporting.
    @Test func aConflictOutranksAGoodKeyForTheSameSender() {
        #expect(signatureState(
            signature: signature(),
            signerKeys: [
                SignerKey(publicKey: "k", verified: true),
                SignerKey(publicKey: "", conflict: true),
            ],
            keyIDs: keyIDs(["k": ["AAAA"]])
        ) == .keyChanged)
    }

    /// Checked before validity, too: a changed key is the more important
    /// thing to say than a signature that fails against it.
    @Test func aConflictOutranksAnInvalidSignature() {
        #expect(signatureState(
            signature: signature(valid: false),
            signerKeys: [SignerKey(publicKey: "", conflict: true)],
            keyIDs: keyIDs([:])
        ) == .keyChanged)
    }

    @Test func aSignatureThatDoesNotVerifyIsInvalid() {
        #expect(signatureState(
            signature: signature(valid: false),
            signerKeys: [SignerKey(publicKey: "k")],
            keyIDs: keyIDs(["k": ["AAAA"]])
        ) == .invalid)
    }

    /// Continuity, not identity. Most keys arrive by Autocrypt harvest, so a
    /// flat "verified" would overclaim for nearly all of them.
    @Test func anUnconfirmedBoundKeyClaimsContinuityOnly() {
        #expect(signatureState(
            signature: signature(),
            signerKeys: [SignerKey(publicKey: "k", verified: false)],
            keyIDs: keyIDs(["k": ["AAAA"]])
        ) == .verifiedSeenBefore)
    }

    @Test func onlyAnOutOfBandConfirmationClaimsIdentity() {
        #expect(signatureState(
            signature: signature(),
            signerKeys: [SignerKey(publicKey: "k", verified: true)],
            keyIDs: keyIDs(["k": ["AAAA"]])
        ) == .verifiedConfirmed)
    }

    /// A signing subkey's id differs from the primary key's, so matching only
    /// the primary would reject every normally signed message.
    @Test func aSubkeyIdStillMatchesItsBoundKey() {
        #expect(signatureState(
            signature: signature(keyID: "SUBKEY"),
            signerKeys: [SignerKey(publicKey: "k", verified: true)],
            keyIDs: keyIDs(["k": ["PRIMARY", "SUBKEY"]])
        ) == .verifiedConfirmed)
    }

    /// An unparseable bound key must only ever shrink the candidate set, never
    /// grant a pass.
    @Test func anUnparseableKeyGrantsNothing() {
        #expect(signatureState(
            signature: signature(),
            signerKeys: [SignerKey(publicKey: "garbage", verified: true)],
            keyIDs: keyIDs([:])
        ) == .signerUnknown)
    }
}

@Suite struct SignatureRowMarkerTests {
    /// Only the two alarms mark. `signerUnknown` is the ordinary state for a
    /// correspondent not in the address book; a glyph on most rows carries
    /// nothing actionable.
    @Test func onlyTheAlarmsMarkARow() {
        #expect(signatureRowSymbol(.keyChanged) != nil)
        #expect(signatureRowSymbol(.invalid) != nil)
        #expect(signatureRowSymbol(.signerUnknown) == nil)
        #expect(signatureRowSymbol(.verifiedSeenBefore) == nil)
        #expect(signatureRowSymbol(.verifiedConfirmed) == nil)
        #expect(signatureRowSymbol(.none) == nil)
    }

    /// "The key this sender signs with is not the one you pinned" outranks
    /// "we couldn't read this".
    @Test func aSignatureAlarmOutranksTheContentState() {
        #expect(pgpRowSymbol(content: .clientProtected, signature: .keyChanged)
            == signatureRowSymbol(.keyChanged))
        #expect(pgpRowSymbol(content: .clientProtected, signature: .none)
            == pgpRowSymbol(.clientProtected))
        #expect(pgpRowSymbol(content: .none, signature: .signerUnknown) == nil)
    }

    /// Wording is the contract: continuity must not read as identity, and an
    /// unsaved key must not read as an accusation.
    @Test func theLabelsDoNotOverclaim() {
        #expect(signatureLabel(.verifiedConfirmed)?.contains("confirmed") == true)
        #expect(signatureLabel(.verifiedSeenBefore)?.contains("same key") == true)
        #expect(signatureLabel(.verifiedSeenBefore)?.lowercased().contains("verified") == false)
        #expect(signatureLabel(.none) == nil)
        #expect(signatureIsAlarming(.keyChanged))
        #expect(signatureIsAlarming(.invalid))
        #expect(!signatureIsAlarming(.signerUnknown))
    }
}
