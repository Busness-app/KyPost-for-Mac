//
//  MailTests.swift
//  KyPost Tests
//
//  Phase 3 tests: relay source mapping, comma-string send contract, keyword
//  tab computation, mode-aware repository, send use-case validation.
//

import Foundation
import SwiftUI
import Testing
import WebKit
@testable import KyPost

// MARK: - Helpers


private let auth = RelayAuth(deviceId: "u1", deviceSecret: "h1")

private func makeEmail(serverId: String, keywords: Set<String>) -> Email {
    Email(
        serverId: serverId,
        folder: "INBOX",
        senderName: "S",
        senderEmail: "s@example.com",
        subject: "Subject",
        body: "Body",
        keywords: keywords,
        receivedAt: Date(),
        read: false,
        starred: false
    )
}

private func makeOutgoing(
    to: [String] = ["a@x.com", "b@x.com"],
    cc: [String] = ["c@x.com"],
    bcc: [String] = []
) -> OutgoingEmail {
    OutgoingEmail(to: to, cc: cc, bcc: bcc, subject: "Hi", body: "Hello there")
}

// MARK: - Comma-string send contract

@Suite struct RelaySendRequestTests {
    @Test func recipientsAreCommaJoinedStrings() throws {
        let request = RelaySendRequest(from: makeOutgoing())
        #expect(request.to == "a@x.com, b@x.com")
        #expect(request.cc == "c@x.com")
        #expect(request.bcc == "")
        #expect(request.mode == "plain")

        // Binding contract (Mobile_Mail_Relay.md Part 6): strings in the
        // JSON, not arrays, plus a "mode" field.
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["to"] as? String == "a@x.com, b@x.com")
        #expect(object["cc"] as? String == "c@x.com")
        #expect(object["mode"] as? String == "plain")
    }
}

// MARK: - RelayMailSource

@Suite struct RelayMailSourceTests {
    @Test func fetchEmailsMapsByTabResponse() async throws {
        // Shape from Mobile_Mail_Relay.md / Android RelayModels.kt.
        let json = """
        {
          "tabs": ["Work", "Personal"],
          "byTab": {
            "Work": [
              {
                "messageId": "e-1",
                "sender": "Ada Lovelace <ada@example.com>",
                "subject": "Report",
                "body": "The report",
                "label": "Important",
                "status": "read",
                "atUtc": "2025-06-15T15:06:40Z"
              }
            ],
            "Personal": [
              { "messageId": "e-2", "subject": "Bare minimum" }
            ]
          },
          "cursor": 1750000000,
          "delta": false,
          "removed": []
        }
        """
        let client = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/inbox?"))
            #expect(!url.contains("sub="))
            #expect(!url.contains("hash="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(url.contains("mailbox=INBOX"))
            #expect(url.contains("limit=50"))
            #expect(url.contains("since=0"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        let emails = try await source.fetchEmails(folder: "INBOX", from: 0, to: 50)

        #expect(emails.count == 2)
        let full = try #require(emails.first { $0.serverId == "e-1" })
        #expect(full.senderName == "Ada Lovelace")
        #expect(full.senderEmail == "ada@example.com")
        #expect(full.keywords == ["Important"]) // label wins over tab
        #expect(full.read) // any status but "unread"
        #expect(full.receivedAt == Date(timeIntervalSince1970: 1_750_000_000))

        let bare = try #require(emails.first { $0.serverId == "e-2" })
        #expect(bare.keywords == ["Personal"]) // falls back to its tab
        #expect(!bare.read) // status defaults to unread
    }

    @Test func fetchEmailsSortsNewestFirstAcrossTabs() async throws {
        // byTab is a dictionary with no stable iteration order; the flattened
        // list must come back sorted by date regardless of tab grouping.
        let json = """
        {
          "tabs": ["Work", "Personal"],
          "byTab": {
            "Work": [
              { "messageId": "old", "atUtc": "2025-01-01T00:00:00Z" },
              { "messageId": "newest", "atUtc": "2025-03-01T00:00:00Z" }
            ],
            "Personal": [
              { "messageId": "middle", "atUtc": "2025-02-01T00:00:00Z" }
            ]
          }
        }
        """
        let source = RelayMailSource(httpClient: stubClient(json: json), serverUrl: server, auth: auth)
        let emails = try await source.fetchEmails(folder: "INBOX", from: 0, to: 50)
        #expect(emails.map(\.serverId) == ["newest", "middle", "old"])
    }

    @Test func numericCursorDecodes() throws {
        // Some deployments emit cursor as a bare number, others as a string.
        let numeric = try JSONDecoder().decode(
            RelayInboxResponse.self,
            from: Data(#"{"cursor": 42}"#.utf8)
        )
        #expect(numeric.cursor == FlexibleCursor("42"))
        let string = try JSONDecoder().decode(
            RelayInboxResponse.self,
            from: Data(#"{"cursor": "42"}"#.utf8)
        )
        #expect(string.cursor == FlexibleCursor("42"))
    }

    @Test func listFoldersMapsPathAndSearchIsLocalOnly() async throws {
        let json = #"{"parent": "", "folders": [{"path": "INBOX"}, {"path": "Archive", "deletable": true}]}"#
        let foldersClient = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url == "\(server)/api/inbox/folders")
            #expect(!url.contains("parent="))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        }
        let folders = try await RelayMailSource(httpClient: foldersClient, serverUrl: server, auth: auth)
            .listFolders()
        #expect(folders.map(\.name) == ["INBOX", "Archive"])

        // Subfolder listing scopes the request with the parent param.
        let subJson = #"{"parent": "Archive", "folders": [{"path": "Archive/Receipts", "deletable": true}]}"#
        let subClient = stubClient(json: subJson) { request in
            #expect(request.url!.absoluteString.contains("parent=Archive"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
        }
        let subs = try await RelayMailSource(httpClient: subClient, serverUrl: server, auth: auth)
            .listFolders(parent: "Archive")
        #expect(subs.map(\.name) == ["Archive/Receipts"])

        // The relay has no search endpoint; inbox search uses the local cache.
        await #expect(throws: MailSourceError.unsupported) {
            _ = try await RelayMailSource(httpClient: stubClient(), serverUrl: server, auth: auth)
                .search(folder: "INBOX", query: "report")
        }
    }

    @Test func movePostsBulkActionBody() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/inbox/actions")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""action":"move""#))
            #expect(body.contains(#""messageIds":["e-1","e-2"]"#))
            #expect(body.contains(#""mailbox":"INBOX""#))
            #expect(body.contains(#""targetMailbox":"Archive\/2026""#))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.move(messageIds: ["e-1", "e-2"], from: "INBOX", to: "Archive/2026")
    }

    @Test func deletePostsBulkActionBodyWithoutTarget() async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/inbox/actions")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""action":"delete""#))
            #expect(body.contains(#""messageIds":["e-1","e-2"]"#))
            #expect(body.contains(#""mailbox":"Trash""#))
            // targetMailbox is move-only; nil must be omitted, not null.
            #expect(!body.contains("targetMailbox"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.delete(messageIds: ["e-1", "e-2"], mailbox: "Trash")
    }

    @Test(arguments: [
        ("archive", { try await $0.archive(messageIds: ["e-1"], mailbox: "INBOX") }),
        ("spam", { try await $0.markSpam(messageIds: ["e-1"], mailbox: "INBOX") }),
        ("read", { try await $0.markRead(messageIds: ["e-1"], mailbox: "INBOX") }),
    ] as [(String, @Sendable (RelayMailSource) async throws -> Void)])
    func actionVerbsPostBulkActionBody(
        verb: String,
        call: @Sendable (RelayMailSource) async throws -> Void
    ) async throws {
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/inbox/actions")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""action":"\#(verb)""#))
            #expect(body.contains(#""messageIds":["e-1"]"#))
            #expect(body.contains(#""mailbox":"INBOX""#))
            #expect(!body.contains("targetMailbox"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await call(source)
    }

    @Test func sendPostsCommaStringBody() async throws {
        let client = stubClient(json: #"{"ok": true, "sentSaved": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/mail/send")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""to":"a@x.com, b@x.com""#))
            #expect(body.contains(#""mode":"plain""#))
            // No attachments → the key is omitted entirely, not null/[].
            #expect(!body.contains("attachments"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.send(email: makeOutgoing())
    }

    @Test func sendEncodesModeAndBase64Attachments() throws {
        var email = makeOutgoing()
        email.mode = "html"
        email.attachments = [OutgoingAttachment(
            name: "a.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )]
        let request = RelaySendRequest(from: email)
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mode"] as? String == "html")
        let attachments = try #require(object["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["name"] as? String == "a.txt")
        #expect(attachments[0]["mimeType"] as? String == "text/plain")
        #expect(attachments[0]["dataBase64"] as? String == Data("hello".utf8).base64EncodedString())
    }

    @Test func plaintextSendOmitsThePgpFlagsEntirely() throws {
        let data = try JSONEncoder().encode(RelaySendRequest(from: makeOutgoing()))
        let body = String(decoding: data, as: UTF8.self)
        // A plaintext send must look exactly as it did before encryption
        // existed; the relay defaults all three to false.
        #expect(!body.contains("encrypt"))
        #expect(!body.contains("sign"))
        #expect(!body.contains("allowPickupFallback"))
    }

    @Test func encryptedSendCarriesTheFlagsItWasGiven() throws {
        var email = makeOutgoing()
        email.encrypt = true
        email.sign = true
        let object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(RelaySendRequest(from: email))
        ) as? [String: Any])
        #expect(object["encrypt"] as? Bool == true)
        #expect(object["sign"] as? Bool == true)
        // Not consented to yet: the first send always asks without it.
        #expect(object["allowPickupFallback"] == nil)
    }

    /// allowPickupFallback is meaningful only with encrypt, so it never travels
    /// on a plaintext send even if something set it.
    @Test func pickupFallbackNeedsEncrypt() throws {
        var email = makeOutgoing()
        email.allowPickupFallback = true
        let plain = String(decoding: try JSONEncoder().encode(RelaySendRequest(from: email)), as: UTF8.self)
        #expect(!plain.contains("allowPickupFallback"))

        email.encrypt = true
        let encrypted = String(decoding: try JSONEncoder().encode(RelaySendRequest(from: email)), as: UTF8.self)
        #expect(encrypted.contains(#""allowPickupFallback":true"#))
    }

    @Test func sendReturnsTheRelayWarning() async throws {
        let json = #"{"ok": true, "sentSaved": false, "warning": "failed to deliver a pickup link to 1 of 3 recipient(s)"}"#
        let source = RelayMailSource(httpClient: stubClient(json: json), serverUrl: server, auth: auth)
        let warning = try await source.send(email: makeOutgoing())
        #expect(warning == "failed to deliver a pickup link to 1 of 3 recipient(s)")
    }

    @Test func aCleanSendHasNoWarning() async throws {
        let source = RelayMailSource(
            httpClient: stubClient(json: #"{"ok": true, "sentSaved": true, "warning": ""}"#),
            serverUrl: server,
            auth: auth
        )
        #expect(try await source.send(email: makeOutgoing()) == "")
        // Absent, not just empty.
        let terse = RelayMailSource(
            httpClient: stubClient(json: #"{"ok": true}"#),
            serverUrl: server,
            auth: auth
        )
        #expect(try await terse.send(email: makeOutgoing()) == "")
    }

    @Test func listAttachmentsMapsMetadata() async throws {
        let json = #"{"ok": true, "attachments": [{"index": 0, "name": "report.pdf", "mimeType": "application/pdf", "size": 1234}, {"index": 1}]}"#
        let client = stubClient(json: json) { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/mail/attachments?"))
            #expect(url.contains("mailbox=INBOX"))
            #expect(url.contains("messageId=42"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        let attachments = try await source.listAttachments(folder: "INBOX", messageId: "42")

        #expect(attachments.count == 2)
        #expect(attachments[0] == EmailAttachment(
            index: 0, name: "report.pdf", mimeType: "application/pdf", size: 1234
        ))
        // Missing fields get safe fallbacks.
        #expect(attachments[1] == EmailAttachment(
            index: 1, name: "attachment", mimeType: "application/octet-stream", size: 0
        ))
    }

    @Test func downloadAttachmentReturnsRawBytes() async throws {
        let client = stubClient(json: "raw-bytes") { request in
            let url = request.url!.absoluteString
            #expect(url.hasPrefix("\(server)/api/mail/attachment?"))
            #expect(url.contains("messageId=42"))
            #expect(url.contains("index=1"))
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Secret") == "h1")
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        let data = try await source.downloadAttachment(folder: "INBOX", messageId: "42", index: 1)
        #expect(String(decoding: data, as: UTF8.self) == "raw-bytes")
    }

    @Test func saveDraftPostsTheSendShapeWithoutPgpFields() async throws {
        var email = makeOutgoing()
        email.encrypt = true
        email.sign = true
        email.allowPickupFallback = true
        let client = stubClient(json: #"{"ok": true}"#) { request in
            #expect(request.url!.absoluteString == "\(server)/api/mail/draft")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Kypost-Device-Id") == "u1")
            let body = request.httpBody.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(body.contains(#""to":"a@x.com, b@x.com""#))
            #expect(body.contains(#""mode":"plain""#))
            // A draft has no PGP semantics; the server would ignore them and
            // sending them invites confusion.
            #expect(!body.contains("encrypt"))
            #expect(!body.contains("sign"))
            #expect(!body.contains("allowPickupFallback"))
        }
        let source = RelayMailSource(httpClient: client, serverUrl: server, auth: auth)
        try await source.saveDraft(email: email)
    }

    @Test func saveDraftSurfacesAPlainTextFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 500, json: "could not save draft"),
            serverUrl: server,
            auth: auth
        )
        await #expect(throws: NetworkError.server(statusCode: 500)) {
            try await source.saveDraft(email: makeOutgoing())
        }
    }
}

// MARK: - Rich text → HTML (compose mode:"html")

@Suite struct RichTextHTMLTests {
    /// Fake trait resolver so tests don't need a font resolution context.
    private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }
    private let allBold: RichTextHTML.FontTraits = { _ in (true, false) }

    @Test func escapesMarkupCharacters() {
        #expect(RichTextHTML.escape(#"<a href="x">&"#) == "&lt;a href=&quot;x&quot;&gt;&amp;")
    }

    @Test func plainTextHasNoFormatting() {
        let text = AttributedString("just words\ntwo lines")
        #expect(!RichTextHTML.hasFormatting(text, fontTraits: noTraits))
        // Fonts resolve to regular → still plain even with a font attribute.
        var fonted = AttributedString("styled?")
        fonted.font = .body
        #expect(!RichTextHTML.hasFormatting(fonted, fontTraits: noTraits))
    }

    @Test func underlineAndBoldCountAsFormatting() {
        var underlined = AttributedString("hello")
        underlined.underlineStyle = .single
        #expect(RichTextHTML.hasFormatting(underlined, fontTraits: noTraits))

        var fonted = AttributedString("hello")
        fonted.font = .body
        #expect(RichTextHTML.hasFormatting(fonted, fontTraits: allBold))
    }

    @Test func htmlDocumentWrapsAndTagsRuns() {
        var text = AttributedString("plain ")
        var bold = AttributedString("bold&co")
        bold.font = .body
        var underlined = AttributedString(" under\nline")
        underlined.underlineStyle = .single
        text += bold
        text += underlined

        let html = RichTextHTML.htmlDocument(from: text) { _ in (true, false) }
        #expect(html.hasPrefix("<html><body>"))
        #expect(html.hasSuffix("</body></html>"))
        // The unfonted runs also resolve bold here, so just check the tagged
        // pieces landed with escaping and <br> conversion intact.
        #expect(html.contains("<strong>bold&amp;co</strong>"))
        #expect(html.contains("<u>"))
        #expect(html.contains("<br>"))
    }

    @Test func linksBecomeAnchors() {
        var text = AttributedString("llama")
        text.link = URL(string: "https://mail.urlxl.com/x?a=1&b=2")
        let html = RichTextHTML.htmlDocument(from: text, fontTraits: noTraits)
        #expect(html.contains(#"<a href="https://mail.urlxl.com/x?a=1&amp;b=2">llama</a>"#))
    }
}

// MARK: - Email HTML rendering hardening (WebView JS / remote content)

@MainActor
@Suite struct EmailBodyWebViewConfigurationTests {
    @Test func javaScriptIsAlwaysDisabledRegardlessOfRemoteContentSetting() {
        #expect(
            EmailBodyWebView.makeConfiguration(allowsRemoteContent: false)
                .defaultNavigationPreferences.allowsContentJavaScript == false
        )
        #expect(
            EmailBodyWebView.makeConfiguration(allowsRemoteContent: true)
                .defaultNavigationPreferences.allowsContentJavaScript == false
        )
    }

    @Test func remoteContentIsBlockedByDefaultAndOnlyLoadsWhenExplicitlyAllowed() {
        #expect(EmailBodyWebView.makeConfiguration(allowsRemoteContent: false).loadsSubresources == false)
        #expect(EmailBodyWebView.makeConfiguration(allowsRemoteContent: true).loadsSubresources == true)
    }
}

// MARK: - Email body navigation policy (default-deny)

@MainActor
@Suite struct EmailBodyNavigationPolicyTests {
    private func policy(_ urlString: String, isLink: Bool = false) -> EmailBodyWebView.BodyNavigation {
        EmailBodyWebView.navigationPolicy(url: URL(string: urlString), isLinkActivation: isLink)
    }

    @Test func theMessageDocumentItselfLoads() {
        #expect(policy("about:blank") == .allow)
    }

    @Test func linkTapsOpenInTheBrowserAndNeverInTheReader() {
        let url = URL(string: "https://example.com/thread")!
        #expect(policy(url.absoluteString, isLink: true) == .openInBrowser(url))
    }

    /// The bypass this closes: a meta refresh is plain HTML and a main-frame
    /// navigation, so neither `allowsContentJavaScript = false` nor
    /// `loadsSubresources = false` touches it. Allowing everything that isn't
    /// a link tap would let a message beacon home on open, straight past the
    /// blocked-remote-content banner.
    @Test func aRedirectTheUserNeverClickedIsBlocked() {
        #expect(policy("https://tracker.example/beacon?id=victim") == .block)
    }

    @Test func aFormPostToAnArbitraryHostIsBlocked() {
        #expect(policy("https://tracker.example/collect") == .block)
    }

    @Test func aNavigationWithNoURLIsBlocked() {
        #expect(EmailBodyWebView.navigationPolicy(url: nil, isLinkActivation: false) == .block)
        #expect(EmailBodyWebView.navigationPolicy(url: nil, isLinkActivation: true) == .block)
    }
}

// MARK: - Attachment cache path sanitization

@MainActor
@Suite struct InboxViewModelAttachmentCachePathTests {
    @Test func acceptsAnOrdinaryServerId() {
        #expect(InboxViewModel.sanitizedCacheComponent("e-1") == "e-1")
    }

    @Test(arguments: [
        "",
        "../../Library/Preferences/evil",
        "..",
        "sub/dir",
        "null\0byte",
    ])
    func rejectsPathTraversalAndSeparators(value: String) {
        #expect(InboxViewModel.sanitizedCacheComponent(value) == nil)
    }
}

// MARK: - MailOutcome mapping

@Suite struct MailOutcomeTests {
    @Test func errorMapping() {
        #expect(MailOutcome.from(NetworkError.unauthorized) == .unauthorized)
        #expect(MailOutcome.from(MailSourceError.notPaired) == .notPaired)
        if case .failure = MailOutcome.from(MailSourceError.unsupported) {} else {
            Issue.record("unsupported should map to failure")
        }
        if case .failure = MailOutcome.from(NetworkError.serviceUnavailable) {} else {
            Issue.record("503 should map to failure")
        }
    }
}

// MARK: - The relay's two PGP 409s

@Suite struct RelayConflictTests {
    /// Discrimination is by field. The prose is user-facing copy and may be
    /// reworded at any time.
    @Test func clientSideNeededIsRecognisedByItsField() {
        #expect(RelayMailSource.conflictError(
            body: #"{"error":"end-to-end protected","clientSideNeeded":true}"#
        ) == .clientSideNeeded)
    }

    @Test func keylessRecipientsCarriesTheAddressesAndTheFallbackFlag() {
        let body = """
        {"error": "some recipients have no usable PGP key; sending them a one-time link stores this message's plaintext on the server for 7 days",
         "keylessRecipients": ["bob@example.com", "carol@example.com"],
         "pickupFallbackAvailable": true}
        """
        #expect(RelayMailSource.conflictError(body: body) == .keylessRecipients(
            addresses: ["bob@example.com", "carol@example.com"],
            pickupFallbackAvailable: true
        ))
    }

    /// A server with pickup links turned off refuses and offers nothing.
    @Test func aKeylessConflictWithoutTheFallbackFlagIsNotOfferable() {
        let body = #"{"keylessRecipients":["bob@example.com"]}"#
        #expect(RelayMailSource.conflictError(body: body) == .keylessRecipients(
            addresses: ["bob@example.com"],
            pickupFallbackAvailable: false
        ))
    }

    /// A 409 carrying neither field must not inherit PGP wording.
    @Test func anOrdinaryConflictMapsToNoPgpError() {
        #expect(RelayMailSource.conflictError(body: #"{"error":"duplicate"}"#) == nil)
        #expect(RelayMailSource.conflictError(body: #"{"clientSideNeeded":false}"#) == nil)
        #expect(RelayMailSource.conflictError(body: #"{"keylessRecipients":[]}"#) == nil)
    }

    /// Every non-409 error body is plain text, and a 409 body may still be
    /// malformed. Decoding must never trap.
    @Test func aMalformedConflictBodyDoesNotCrash() {
        #expect(RelayMailSource.conflictError(body: "") == nil)
        #expect(RelayMailSource.conflictError(body: "failed to send email: dial tcp") == nil)
        #expect(RelayMailSource.conflictError(body: #"{"keylessRecipients":"bob@example.com"}"#) == nil)
        #expect(RelayMailSource.conflictError(body: "[1,2,3]") == nil)
    }

    @Test func sendMapsTheClientSideConflictToItsOwnOutcome() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"clientSideNeeded":true}"#),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .clientSideNeeded)
    }

    @Test func sendMapsTheKeylessConflictToItsOwnOutcome() async {
        let json = #"{"keylessRecipients":["bob@example.com"],"pickupFallbackAvailable":true}"#
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: json),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .success
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        #expect(outcome == .keylessRecipients(
            addresses: ["bob@example.com"],
            pickupFallbackAvailable: true
        ))
    }

    @Test func anUnrelatedConflictStaysAGenericFailure() async {
        let source = RelayMailSource(
            httpClient: stubClient(status: 409, json: #"{"error":"duplicate"}"#),
            serverUrl: server,
            auth: auth
        )
        var outcome: MailOutcome = .clientSideNeeded          // must be overwritten
        do {
            try await source.send(email: makeOutgoing())
            Issue.record("a 409 should still throw")
        } catch {
            outcome = MailOutcome.from(error)
        }
        if case .failure = outcome {} else {
            Issue.record("an ordinary 409 should be a generic failure, got \(outcome)")
        }
    }
}

// MARK: - Keyword tabs

@Suite struct KeywordRepositoryTests {
    private let emails = [
        makeEmail(serverId: "1", keywords: ["Work", "Important"]),
        makeEmail(serverId: "2", keywords: ["work happens later alphabetically", "Work"]),
        makeEmail(serverId: "3", keywords: []),
    ]

    @Test func computeTabsIsUniqueSortedWithCounts() {
        let tabs = KeywordRepository.computeTabs(from: emails)
        #expect(tabs.map(\.name) == ["Important", "Work", "work happens later alphabetically"])
        #expect(tabs.first { $0.name == "Work" }?.count == 2)
        #expect(tabs.first { $0.name == "Important" }?.count == 1)
    }

    @Test func visibleTabsRespectsVisibilityStore() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let repository = KeywordRepository(settingsStore: KeywordSettingsStore(defaults: defaults))

        #expect(repository.visibleTabs(from: emails).count == 3)
        repository.setVisible(false, for: "Work")
        #expect(repository.visibleTabs(from: emails).map(\.name)
                == ["Important", "work happens later alphabetically"])

        // Settings list still includes hidden keywords, flagged invisible.
        let settings = repository.allSettings(from: emails)
        #expect(settings.first { $0.name == "Work" }?.visible == false)
    }
}

// MARK: - MailRepository

@Suite struct MailRepositoryTests {
    private func makeRepository(
        client: HTTPClient,
        paired: Bool
    ) throws -> MailRepository {
        let pairingStore = try makePairedStore(paired: paired)
        let db = try AppDatabase(inMemory: true)
        return MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        )
    }

    @Test func withoutPairingIsNotPaired() throws {
        let repository = try makeRepository(client: stubClient(), paired: false)
        #expect(throws: MailSourceError.notPaired) {
            _ = try repository.makeSource()
        }
    }

    @Test func refreshFolderCachesSnapshot() async throws {
        let json = #"{"byTab": {"Work": [{"messageId": "e-1", "subject": "Cached"}]}}"#
        let repository = try makeRepository(client: stubClient(json: json), paired: true)

        let fetched = try await repository.refreshFolder("INBOX")
        #expect(fetched.count == 1)

        let cached = try await repository.cachedFolder("INBOX")
        #expect(cached.map(\.serverId) == ["e-1"])
        #expect(cached.first?.subject == "Cached")
    }

    @Test func sendWithoutPairingIsNotPaired() async throws {
        let repository = try makeRepository(client: stubClient(), paired: false)
        let outcome = await repository.send(makeOutgoing())
        #expect(outcome == .notPaired)
    }

    @Test func saveDraftIsSuccessAndNeedsAPairing() async throws {
        let paired = try makeRepository(client: stubClient(json: #"{"ok": true}"#), paired: true)
        #expect(await paired.saveDraft(makeOutgoing()) == .success)
        #expect(paired.pairedServerUrl == server)

        let unpaired = try makeRepository(client: stubClient(), paired: false)
        #expect(await unpaired.saveDraft(makeOutgoing()) == .notPaired)
        #expect(unpaired.pairedServerUrl == nil)
    }
}

// MARK: - SendEmailUseCase

@Suite struct SendEmailUseCaseTests {
    private func makeUseCase(client: HTTPClient) throws -> SendEmailUseCase {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        return SendEmailUseCase(repository: MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: client
        ))
    }

    @Test func rejectsEmptyRecipients() async throws {
        let send = try makeUseCase(client: stubClient())
        let outcome = await send(makeOutgoing(to: [], cc: [], bcc: []))
        #expect(outcome == .invalid("Add at least one recipient"))
    }

    @Test func rejectsMalformedAddresses() async throws {
        let send = try makeUseCase(client: stubClient())
        let outcome = await send(makeOutgoing(to: ["not-an-address"], cc: [], bcc: []))
        #expect(outcome == .invalid("Check the recipient addresses"))
    }

    @Test func sendsValidEmail() async throws {
        let send = try makeUseCase(client: stubClient(json: #"{"ok": true}"#))
        let outcome = await send(makeOutgoing())
        #expect(outcome == .success)
    }

    @Test func rejectsOversizedAttachments() async throws {
        let send = try makeUseCase(client: stubClient(json: #"{"ok": true}"#))
        var email = makeOutgoing()
        // Two 13 MB files cross the 25 MB budget (backend maxMailAttachmentBytes).
        let big = Data(count: 13 << 20)
        email.attachments = [
            OutgoingAttachment(name: "one", mimeType: "application/octet-stream", data: big),
            OutgoingAttachment(name: "two", mimeType: "application/octet-stream", data: big),
        ]
        let outcome = await send(email)
        #expect(outcome == .invalid("Attachments too large (max 25 MB total)"))
    }

    @Test func addressShapeCheck() {
        #expect(SendEmailUseCase.looksLikeEmailAddress("a@b.co"))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("a@b"))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("@b.co"))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("a@b."))
        #expect(!SendEmailUseCase.looksLikeEmailAddress("a@@b.co"))
    }
}

// MARK: - PGP field wire contract

@Suite struct RelayEmailPgpFieldTests {
    /// The server marks all five pgp* fields omitempty, so absent means "no
    /// OpenPGP content" — the decoded defaults ARE the contract, not an
    /// unknown state.
    @Test func absentPgpFieldsDecodeToFalseAndEmpty() throws {
        let json = """
        {"messageId":"1","sender":"a@x.com","subject":"Hi","body":"Hello"}
        """
        let dto = try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
        let email = dto.toDomain(folder: "INBOX", tab: "")

        #expect(email.pgpEncrypted == false)
        #expect(email.pgpSigned == false)
        #expect(email.pgpVerified == false)
        #expect(email.pgpSignerFingerprint == "")
        #expect(email.pgpDecryptError == "")
    }

    @Test func presentPgpFieldsAreCarriedIntoTheDomainModel() throws {
        let json = """
        {"messageId":"2","subject":"Secret","body":"",
         "pgpEncrypted":true,"pgpSigned":true,"pgpVerified":false,
         "pgpSignerFingerprint":"ABCD1234","pgpDecryptError":"no key"}
        """
        let dto = try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
        let email = dto.toDomain(folder: "INBOX", tab: "")

        #expect(email.pgpEncrypted)
        #expect(email.pgpSigned)
        #expect(email.pgpVerified == false)
        #expect(email.pgpSignerFingerprint == "ABCD1234")
        #expect(email.pgpDecryptError == "no key")
    }

    @Test func pgpFieldsSurviveTheRoundTripThroughPersistence() {
        let email = Email(
            serverId: "3",
            folder: "INBOX",
            senderName: "S",
            senderEmail: "s@example.com",
            subject: "Subject",
            body: "",
            keywords: [],
            receivedAt: Date(),
            read: false,
            starred: false,
            pgpEncrypted: true,
            pgpSigned: true,
            pgpVerified: true,
            pgpSignerFingerprint: "FEED",
            pgpDecryptError: ""
        )
        let restored = EmailEntity(from: email).toDomain

        #expect(restored.pgpEncrypted)
        #expect(restored.pgpSigned)
        #expect(restored.pgpVerified)
        #expect(restored.pgpSignerFingerprint == "FEED")
        #expect(restored.pgpDecryptError == "")
    }
}

// MARK: - Partial-success warnings

@Suite struct SendWarningTests {
    /// A warning means the message *was* sent. It must never look like a
    /// failure, and must never offer a retry that would duplicate it.
    @Test func aWarningIsSuccessNotFailure() async throws {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let json = #"{"ok": true, "sentSaved": false, "warning": "sent copy not saved"}"#
        let repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: json)
        )

        let outcome = await repository.send(makeOutgoing())
        #expect(outcome == .sentWithWarning("sent copy not saved"))
    }

    @Test func noWarningIsPlainSuccess() async throws {
        let pairingStore = try makePairedStore()
        let db = try AppDatabase(inMemory: true)
        let repository = MailRepository(
            securePairingStore: pairingStore,
            emailDAO: EmailDAO(modelContainer: db.container),
            httpClient: stubClient(json: #"{"ok": true, "sentSaved": true, "warning": ""}"#)
        )
        #expect(await repository.send(makeOutgoing()) == .success)
    }
}

// MARK: - Generated link schemes

/// Escaping the attribute value stops it breaking out of the quotes and does
/// nothing about the scheme. This app is the *sender* of the HTML it builds, so
/// a `javascript:` or `data:text/html` href would have been an active payload
/// shipped under the user's own address, left for the recipient's client to
/// clean up.
@Suite struct RichTextHTMLLinkSchemeTests {
    private let noTraits: RichTextHTML.FontTraits = { _ in (false, false) }

    private func linked(_ urlString: String) -> AttributedString {
        var text = AttributedString("click")
        text.link = URL(string: urlString)
        return text
    }

    @Test func safeSchemesKeepTheirAnchor() {
        for scheme in ["https://example.com/a", "http://example.com/a", "mailto:a@example.com"] {
            let html = RichTextHTML.htmlDocument(from: linked(scheme), fontTraits: noTraits)
            #expect(html.contains("<a href="), "expected an anchor for \(scheme)")
        }
    }

    @Test func activeSchemesLoseTheAnchorButKeepTheText() {
        for scheme in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "vbscript:msgbox(1)",
            "file:///etc/passwd",
        ] {
            let html = RichTextHTML.htmlDocument(from: linked(scheme), fontTraits: noTraits)
            #expect(!html.contains("<a href="), "expected no anchor for \(scheme)")
            #expect(html.contains("click"), "expected the text to survive for \(scheme)")
        }
    }

    /// A draft whose only "formatting" is a link the converter drops should
    /// still send as plain, not as an HTML document with nothing in it.
    @Test func aDroppedLinkDoesNotCountAsFormatting() {
        #expect(!RichTextHTML.hasFormatting(linked("javascript:alert(1)"), fontTraits: noTraits))
        #expect(RichTextHTML.hasFormatting(linked("https://example.com"), fontTraits: noTraits))
    }
}

// MARK: - Body rendering (bodyMode)

@Suite struct EmailBodyRenderingTests {
    @Test func honoursADeclaredPlainModeOverTheBodyContent() {
        // The point of carrying bodyMode: a plain-text message that happens to
        // contain angle brackets must not be rendered as markup.
        let body = "See <div> in the spec, and use <p> sparingly."
        #expect(isPlainTextBody(body, mode: "plain"))
        #expect(emailBodyToHTML(body, mode: "plain").contains("&lt;div&gt;"))
        #expect(!emailBodyToHTML(body, mode: "plain").contains("<div>"))
    }

    @Test func honoursADeclaredHtmlModeWithoutSniffing() {
        // A real HTML message that opens with text still converts verbatim.
        let body = "Hello there.<p>Second paragraph.</p>"
        #expect(emailBodyToHTML(body, mode: "html") == body)
    }

    @Test func sniffsOnlyWhenTheServerDidNotSayAnything() {
        let markup = "<p>Hi</p>"
        let text = "Just a sentence."
        #expect(emailBodyToHTML(markup, mode: "") == markup)
        #expect(emailBodyToHTML(text, mode: "").contains("kypost-plain-text"))
        #expect(!isPlainTextBody(markup, mode: ""))
        #expect(isPlainTextBody(text, mode: ""))
    }

    @Test func treatsAnUnrecognisedModeAsAbsent() {
        // A relay that invents a third value must degrade to sniffing, not to
        // one of the two branches by accident.
        #expect(normalizedBodyMode("HTML") == "html")
        #expect(normalizedBodyMode("  Plain ") == "plain")
        #expect(normalizedBodyMode("richtext") == "")
        #expect(normalizedBodyMode("") == "")
    }

    @Test func rendersMislabelledMarkdownNatively() {
        // Relay and cache rows do label Markdown as HTML. Rendering it in the
        // WebView shows the raw syntax behind a horizontal scrollbar.
        let markdown = "# Heading\n\nSee [the docs](https://example.com/x) for more."
        #expect(isPlainTextBody(markdown, mode: "html"))
        // The conversion still honours the declared mode — only the choice of
        // renderer reacts to the content.
        #expect(emailBodyToHTML(markdown, mode: "html") == markdown)
    }

    @Test func keepsRealMarkupInTheWebViewEvenWhenLabelledHtml() {
        #expect(!isPlainTextBody("<table><tr><td>x</td></tr></table>", mode: "html"))
    }

    @Test func escapesAmpersandsBeforeTheEscapesItIntroduces() {
        #expect(escapeHTMLText("a & b < c") == "a &amp; b &lt; c")
    }
}

// MARK: - Relay wire fields

@Suite struct RelayBodyModeDecodingTests {
    private func decode(_ json: String) throws -> RelayEmailDTO {
        try JSONDecoder().decode(RelayEmailDTO.self, from: Data(json.utf8))
    }

    @Test func carriesBodyModeAndHasAttachmentsThrough() throws {
        let dto = try decode("""
        {"messageId": "m1", "bodyMode": "plain", "hasAttachments": true}
        """)
        let email = dto.toDomain(folder: "INBOX", tab: "")
        #expect(email.bodyMode == "plain")
        #expect(email.hasAttachments)
    }

    @Test func anOlderRelayOmittingThemDegradesToSniffing() throws {
        // Absent is a distinct state from "html"/"plain": "" is what puts the
        // reader back on content sniffing, and false is the safe direction for
        // a marker.
        let dto = try decode(#"{"messageId": "m1"}"#)
        let email = dto.toDomain(folder: "INBOX", tab: "")
        #expect(email.bodyMode == "")
        #expect(!email.hasAttachments)
    }
}
