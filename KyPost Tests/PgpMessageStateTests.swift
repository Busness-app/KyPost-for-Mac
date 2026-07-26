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
