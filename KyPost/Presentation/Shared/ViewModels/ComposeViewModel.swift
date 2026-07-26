//
//  ComposeViewModel.swift
//  KyPost
//
//  Compose state (spec §7). On failure the draft stays in memory — no DB
//  auto-save. The body is rich text: formatted drafts send as mode:"html"
//  (RichTextHTML), unformatted ones stay mode:"plain".
//

import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A file staged for sending; kept in memory with its loaded bytes.
struct ComposeAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var mimeType: String
    var data: Data
}

/// Which address field a token belongs to. Also the focus identity for
/// compose's recipient rows.
nonisolated enum RecipientField: Hashable, CaseIterable, Sendable {
    case to, cc, bcc

    var label: String {
        switch self {
        case .to: "To:"
        case .cc: "Cc:"
        case .bcc: "Bcc:"
        }
    }
}

@Observable
@MainActor
final class ComposeViewModel {
    private let sendEmail: SendEmailUseCase
    private let contacts: ContactsViewModel
    private let debounceInterval: Duration

    var to: [RecipientToken] = []
    var cc: [RecipientToken] = []
    var bcc: [RecipientToken] = []
    var subject = ""
    var body = AttributedString()
    var attachments: [ComposeAttachment] = []

    /// Text typed but not yet committed to a token, per field. This lives on
    /// the model rather than in the view's @State so `send()` can flush it —
    /// otherwise typing a recipient and hitting ⌘↩ mails it to nobody.
    var toInput = ""
    var ccInput = ""
    var bccInput = ""

    private(set) var suggestions: [ContactMatch] = []
    /// Which field the visible dropdown belongs to; nil when it's closed.
    private(set) var suggestionsField: RecipientField?
    private(set) var toastMessage: String?
    private(set) var isSending = false
    private(set) var errorMessage: String?
    private(set) var didSend = false

    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    /// `debounceInterval` is injectable so tests don't sleep.
    init(
        sendEmail: SendEmailUseCase,
        contacts: ContactsViewModel,
        draft: ComposeDraft? = nil,
        debounceInterval: Duration = .milliseconds(150)
    ) {
        self.sendEmail = sendEmail
        self.contacts = contacts
        self.debounceInterval = debounceInterval
        if let draft {
            to = tokens(from: draft.to)
            cc = tokens(from: draft.cc)
            bcc = tokens(from: draft.bcc)
            subject = draft.subject
            body = AttributedString(draft.body)
        }
    }

    // MARK: - Contacts

    /// The book both the dropdown and the address book search.
    var contactIndex: ContactSearchIndex { contacts.searchIndex }

    /// iOS loads contacts only when the Contacts tab is opened, so compose
    /// asks for them itself.
    func loadContactsIfNeeded() async {
        await contacts.loadIfNeeded()
    }

    // MARK: - Recipients

    subscript(field: RecipientField) -> [RecipientToken] {
        get {
            switch field {
            case .to: to
            case .cc: cc
            case .bcc: bcc
            }
        }
        set {
            switch field {
            case .to: to = newValue
            case .cc: cc = newValue
            case .bcc: bcc = newValue
            }
        }
    }

    subscript(input field: RecipientField) -> String {
        get {
            switch field {
            case .to: toInput
            case .cc: ccInput
            case .bcc: bccInput
            }
        }
        set {
            switch field {
            case .to: toInput = newValue
            case .cc: ccInput = newValue
            case .bcc: bccInput = newValue
            }
        }
    }

    /// Adds `token` unless that address is already a recipient anywhere.
    ///
    /// Duplicates are checked across all three fields, not just the target:
    /// the same person in both To and Cc is always a mistake, and it's what
    /// the spec asks for.
    @discardableResult
    func add(_ token: RecipientToken, to field: RecipientField) -> Bool {
        guard !isRecipient(token.address) else {
            showToast("\(token.label) is already a recipient")
            return false
        }
        self[field].append(token)
        errorMessage = nil
        return true
    }

    func remove(_ token: RecipientToken, from field: RecipientField) {
        self[field].removeAll { $0.id == token.id }
    }

    func isRecipient(_ address: String) -> Bool {
        let key = address.lowercased()
        return RecipientField.allCases.contains { field in
            self[field].contains { $0.comparisonKey == key }
        }
    }

    /// Turns whatever is uncommitted in `field` into a token. Called on
    /// Return, on a separator keystroke, on blur, and from `send()`.
    ///
    /// `reportingErrors` is false on blur: half-typed text is usually a
    /// search in progress, and clicking to another field shouldn't scold
    /// anyone. The text stays put and send() complains if it's still bad.
    @discardableResult
    func commitPendingInput(for field: RecipientField, reportingErrors: Bool = true) -> Bool {
        let text = self[input: field].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        func reject(_ address: String) -> Bool {
            if reportingErrors {
                errorMessage = "\(address) isn't a valid email address"
            }
            return false
        }

        let parsed = EmailAddress.parse(text)
        // No "@" anywhere means this isn't an attempt at an address at all.
        guard !parsed.isEmpty else { return reject(text) }
        guard parsed.allSatisfy({ EmailAddress.isValid($0.address) }) else {
            return reject(parsed.first { !EmailAddress.isValid($0.address) }?.address ?? text)
        }
        for entry in parsed {
            add(resolve(address: entry.address, name: entry.name), to: field)
        }
        self[input: field] = ""
        closeSuggestions()
        return true
    }

    func selectSuggestion(_ match: ContactMatch, for field: RecipientField) {
        add(
            RecipientToken(
                address: match.entry.address,
                displayName: match.entry.displayName,
                contactId: match.entry.contact.localId
            ),
            to: field
        )
        self[input: field] = ""
        closeSuggestions()
    }

    // MARK: - Suggestions

    /// Debounced so fast typing doesn't re-rank on every keystroke or flicker
    /// the dropdown through intermediate states.
    func updateSuggestions(for field: RecipientField) {
        searchTask?.cancel()
        let query = self[input: field]
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            closeSuggestions()
            return
        }
        searchTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            suggestions = ContactSearch.matches(
                query,
                in: contacts.searchIndex,
                options: .autocomplete
            )
            suggestionsField = field
        }
    }

    func closeSuggestions() {
        searchTask?.cancel()
        searchTask = nil
        suggestions = []
        suggestionsField = nil
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    // MARK: - Draft parsing

    private func tokens(from header: String) -> [RecipientToken] {
        let parsed = EmailAddress.parse(header)
        guard parsed.isEmpty else {
            return parsed.map { resolve(address: $0.address, name: $0.name) }
        }
        // Nothing address-shaped in there, but the draft still means it as a
        // recipient — ComposeDraft.reply falls back to the sender's *name*
        // when an email has no sender address. Keep it visible as a token and
        // let send() reject it, rather than emptying the field silently.
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [RecipientToken(address: trimmed)]
    }

    /// Looks `address` up in the address book so a reply shows "Alice Chen"
    /// rather than a bare address. Falls back to whatever name came with it.
    private func resolve(address: String, name: String? = nil) -> RecipientToken {
        let key = address.lowercased()
        let entry = contacts.searchIndex.entries.first { $0.address.lowercased() == key }
        return RecipientToken(
            address: address,
            displayName: entry?.displayName ?? name,
            contactId: entry?.contact.localId
        )
    }

    var attachmentTotalBytes: Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }

    /// Loads a picked/dropped file into the draft, enforcing the same 25 MB
    /// total budget the backend applies. fileImporter URLs are
    /// security-scoped; access is claimed around the read.
    func addAttachment(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            guard attachmentTotalBytes + data.count <= SendEmailUseCase.maxAttachmentBytes else {
                errorMessage = "Attachments too large (max 25 MB total)"
                return
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            attachments.append(ComposeAttachment(
                name: url.lastPathComponent,
                mimeType: mimeType,
                data: data
            ))
            errorMessage = nil
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeAttachment(_ attachment: ComposeAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Sends the draft. `fontTraits` resolves bold/italic on body runs (from
    /// the view's font resolution context) so formatted text goes out as HTML.
    func send(fontTraits: @escaping RichTextHTML.FontTraits) async {
        guard !isSending else { return }
        // A recipient typed but not committed is still a recipient the user
        // means to mail. Bail on invalid text rather than dropping it.
        for field in RecipientField.allCases where !commitPendingInput(for: field) {
            return
        }
        isSending = true
        defer { isSending = false }

        let isHTML = RichTextHTML.hasFormatting(body, fontTraits: fontTraits)
        let outcome = await sendEmail(OutgoingEmail(
            to: to.map(\.address),
            cc: cc.map(\.address),
            bcc: bcc.map(\.address),
            subject: subject,
            body: isHTML
                ? RichTextHTML.htmlDocument(from: body, fontTraits: fontTraits)
                : String(body.characters),
            mode: isHTML ? "html" : "plain",
            attachments: attachments.map {
                OutgoingAttachment(name: $0.name, mimeType: $0.mimeType, data: $0.data)
            }
        ))
        switch outcome {
        case .success:
            didSend = true
            errorMessage = nil
        case .invalid(let message):
            errorMessage = message
        case .unauthorized:
            errorMessage = "Not authorized — re-pair the device or check credentials."
        case .notPaired:
            errorMessage = "Pair this device before sending."
        case .clientSideNeeded:
            errorMessage = "This account's PGP key is end-to-end protected, so signing and encryption aren't available on mobile. Send without them, or use webmail."
        // Task 7 placeholder: a warning means the send succeeded, so surfacing
        // it as errorMessage (and not setting didSend) is a stopgap, not the
        // final behavior.
        case .sentWithWarning(let warning):
            errorMessage = warning
        case .failure(let message):
            errorMessage = message
        }
    }
}

// MARK: - Reply / Reply All / Forward drafts

/// Prefilled compose state built from an existing email. Codable + Hashable
/// so macOS can pass it as a "compose" WindowGroup value; Identifiable so
/// iOS can present it with sheet(item:).
struct ComposeDraft: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""

    init(
        id: UUID = UUID(),
        to: String = "",
        cc: String = "",
        bcc: String = "",
        subject: String = "",
        body: String = ""
    ) {
        self.id = id
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Hand-written because synthesized Decodable doesn't fall back to
    /// property defaults for absent keys: a scene value archived by a build
    /// without `bcc` would throw here and the restored window would come up
    /// blank. Every key is optional for the same reason.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        to = try container.decodeIfPresent(String.self, forKey: .to) ?? ""
        cc = try container.decodeIfPresent(String.self, forKey: .cc) ?? ""
        bcc = try container.decodeIfPresent(String.self, forKey: .bcc) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }

    static func reply(to email: Email) -> ComposeDraft {
        ComposeDraft(
            to: email.senderEmail.isEmpty ? email.senderName : email.senderEmail,
            subject: prefixed("Re:", email.subject),
            body: quotedBody(of: email)
        )
    }

    /// Reply to the sender, Cc'ing everyone else on the original To/Cc —
    /// minus the sender (already in To) and our own address (`ownAddress`,
    /// the pairing's sub).
    static func replyAll(to email: Email, ownAddress: String?) -> ComposeDraft {
        var draft = reply(to: email)
        var excluded = [email.senderEmail.lowercased()]
        if let ownAddress { excluded.append(ownAddress.lowercased()) }
        var seen = Set<String>()
        let others = (addresses(in: email.sentTo) + addresses(in: email.cc)).filter {
            !excluded.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted
        }
        draft.cc = others.joined(separator: ", ")
        return draft
    }

    static func forward(_ email: Email) -> ComposeDraft {
        let sender = email.senderName == email.senderEmail || email.senderName.isEmpty
            ? email.senderEmail
            : "\(email.senderName) <\(email.senderEmail)>"
        var header = """
        ---------- Forwarded message ----------
        From: \(sender)
        Date: \(email.receivedAt.formatted(date: .abbreviated, time: .shortened))
        Subject: \(email.subject)
        """
        if !email.sentTo.isEmpty {
            header += "\nTo: \(email.sentTo)"
        }
        return ComposeDraft(
            subject: prefixed("Fwd:", email.subject),
            body: "\n\n\(header)\n\n\(plainText(email.body))"
        )
    }

    // MARK: - Helpers

    /// "Re:"/"Fwd:" prefix, skipped when the subject already carries it.
    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return trimmed
        }
        return trimmed.isEmpty ? prefix : "\(prefix) \(trimmed)"
    }

    /// "On {date}, {sender} wrote:" attribution plus the original body,
    /// each line "> "-quoted, after two blank lines for the reply text.
    private static func quotedBody(of email: Email) -> String {
        let sender = email.senderName.isEmpty ? email.senderEmail : email.senderName
        let date = email.receivedAt.formatted(date: .abbreviated, time: .shortened)
        let quoted = plainText(email.body)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\nOn \(date), \(sender) wrote:\n\(quoted)"
    }

    /// Bare addresses from a comma-joined header string whose entries may be
    /// "Name <addr>" or bare addresses.
    private static func addresses(in header: String) -> [String] {
        EmailAddress.parse(header).map(\.address)
    }

    /// Reduces an HTML body to quotable plain text (the compose editor is
    /// text, not a web view): tags stripped, block ends → newlines, common
    /// entities decoded. Plain bodies pass through untouched.
    static func plainText(_ body: String) -> String {
        guard body.range(of: "<[a-zA-Z!/]", options: .regularExpression) != nil else {
            return body
        }
        var text = body
        for pattern in ["(?is)<(style|script|head)\\b.*?</\\1>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)<br\\b[^>]*>|</(p|div|tr|li|h[1-6]|blockquote|table)>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // Collapse the newline runs left behind by nested block markup.
        text = text.replacingOccurrences(
            of: "\\n[ \\t]*(\\n[ \\t]*)+",
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
