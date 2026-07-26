//
//  EmailDetailView.swift
//  KyPost
//
//  Read view. HTML bodies render in a themed WebView (matching Android
//  EmailDetailActivity's wrapper); plain-text bodies use the mono font per
//  STYLE_GUIDE §2 (web .email-reader-body-block). Reply/Reply All/Forward
//  open a prefilled composition (ComposeDraft).
//

import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

struct EmailDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#endif

    let email: Email
    let inboxViewModel: InboxViewModel

    /// Fetched lazily on open — the inbox listing has no attachment info.
    @State private var attachments: [EmailAttachment] = []
    @State private var downloadingIndex: Int?
    @State private var quickLookURL: URL?
    /// Downloaded attachment staged for Save As…; non-nil shows the exporter.
    @State private var attachmentExport: AttachmentDocument?
    /// Reply/forward prefill; non-nil presents the compose sheet (iOS only —
    /// macOS opens the "compose" window instead).
    @State private var composeDraft: ComposeDraft?
    /// Resolved once in `.task` rather than computed in `body` — building it
    /// reads the pairing out of the Keychain, and SwiftUI re-evaluates `body`
    /// far too often for that.
    @State private var webmailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
                .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.panel))
                .padding([.horizontal, .top])

            if pgpState != .none {
                pgpBadges
                    .padding(.horizontal)
                    .padding(.top, 10)
                pgpBanner
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            if !attachments.isEmpty {
                attachmentBar
            }

            if suppressesBody {
                Spacer(minLength: 0)
            } else if bodyLooksLikeHTML {
                EmailBodyWebView(html: themedHTML(email.body))
                    .padding()
            } else {
                ScrollView {
                    Text(email.body)
                        .font(AppFont.mono(14))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .background(theme.bg)
        .navigationTitle(email.senderName.isEmpty ? "Email" : email.senderName)
        .toolbar {
            // Reply/Reply All/Forward + Archive/Junk/Delete, matching Android
            // EmailDetailActivity's action row. On iOS they live in the
            // bottom bar — the navigation bar can't fit six buttons.
#if os(iOS)
            ToolbarItemGroup(placement: .bottomBar) {
                mailActionButtons
            }
#else
            ToolbarItemGroup {
                mailActionButtons
            }
#endif
        }
#if os(iOS)
        // The mail actions live in the bottom bar; hide the app tab bar
        // while reading so the two don't stack.
        .toolbarVisibility(.hidden, for: .tabBar)
        .sheet(item: $composeDraft) { draft in
            ComposeView(draft: draft).environment(\.theme, theme)
        }
#endif
        .quickLookPreview($quickLookURL)
        .fileExporter(
            isPresented: Binding(
                get: { attachmentExport != nil },
                set: { if !$0 { attachmentExport = nil } }
            ),
            document: attachmentExport,
            contentType: .data,
            defaultFilename: attachmentExport?.name
        ) { result in
            if case .failure(let error) = result {
                Log.mail.error("Attachment save failed: \(error.localizedDescription)")
            }
        }
        .task {
            resolveWebmailURL()
            await inboxViewModel.markRead(email)
            attachments = await inboxViewModel.attachments(for: email)
        }
    }

    /// The six mail actions, in Android's order: reply, reply all, forward,
    /// archive, junk, delete.
    @ViewBuilder
    private var mailActionButtons: some View {
        Button {
            compose(.reply(to: email))
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        .help("Reply to the sender")
        Button {
            compose(.replyAll(to: email, ownAddress: ownAddress))
        } label: {
            Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
        }
        .help("Reply to the sender and all recipients")
        Button {
            compose(.forward(email))
        } label: {
            Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        .help("Forward this email")
        Button {
            Task {
                await inboxViewModel.archive(serverIds: [email.serverId])
                dismiss()
            }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .help("Move to Archive")
        Button {
            Task {
                await inboxViewModel.markJunk(serverIds: [email.serverId])
                dismiss()
            }
        } label: {
            Label("Junk", systemImage: "xmark.bin")
        }
        .help("Move to Junk")
        Button(role: .destructive) {
            Task {
                await inboxViewModel.delete(serverIds: [email.serverId])
                dismiss()
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .help("Move to Trash")
    }

    /// Attachment chips; tapping downloads to a temp file and Quick Looks it.
    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Button {
                        openAttachment(attachment)
                    } label: {
                        HStack(spacing: 6) {
                            if downloadingIndex == attachment.index {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 11))
                            }
                            Text(attachment.name)
                                .font(AppFont.ui(12, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                                .lineLimit(1)
                            Text(attachment.size.formatted(.byteCount(style: .file)))
                                .font(AppFont.ui(10))
                                .foregroundStyle(theme.ink.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.panel, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(downloadingIndex != nil)
                    .help("Click to preview; right-click to save")
                    .contextMenu {
                        Button {
                            saveAttachment(attachment)
                        } label: {
                            Label("Save As…", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    /// Opens a prefilled composition: its own window on macOS (matching
    /// plain compose), a sheet on iOS.
    private func compose(_ draft: ComposeDraft) {
#if os(macOS)
        openWindow(id: "compose", value: draft)
#else
        composeDraft = draft
#endif
    }

    /// Our own relay address (the pairing's sub), excluded from Reply All.
    private var ownAddress: String? {
        (try? SingletonGraph.shared.securePairingStore.loadPairing())?.sub
    }

    private func openAttachment(_ attachment: EmailAttachment) {
        downloadingIndex = attachment.index
        Task {
            if let url = await inboxViewModel.downloadAttachment(attachment, of: email) {
                quickLookURL = url
            }
            downloadingIndex = nil
        }
    }

    /// Downloads an attachment's bytes and stages them for the save panel.
    private func saveAttachment(_ attachment: EmailAttachment) {
        downloadingIndex = attachment.index
        Task {
            if let data = await inboxViewModel.attachmentData(attachment, of: email) {
                attachmentExport = AttachmentDocument(name: attachment.name, data: data)
            }
            downloadingIndex = nil
        }
    }

    private func resolveWebmailURL() {
        guard pgpState == .clientProtected,
              let pairing = try? SingletonGraph.shared.securePairingStore.loadPairing()
        else {
            webmailURL = nil
            return
        }
        webmailURL = webmailMessageURL(
            serverUrl: pairing.srv,
            mailbox: email.folder,
            messageId: email.serverId
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(email.subject.isEmpty ? "(No subject)" : email.subject)
                .font(AppFont.ui(20, weight: .semibold))
                .foregroundStyle(theme.inkStrong)

            HStack(spacing: 10) {
                AvatarView(name: email.senderName.isEmpty ? email.senderEmail : email.senderName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(email.senderName.isEmpty ? email.senderEmail : email.senderName)
                        .font(AppFont.ui(15, weight: .medium))
                        .foregroundStyle(theme.inkStrong)
                    Text(email.senderEmail)
                        .font(AppFont.mono(12))
                        .foregroundStyle(theme.ink.opacity(0.8))
                }
                Spacer()
                Text(email.receivedAt, format: .dateTime.day().month().hour().minute())
                    .font(AppFont.ui(12))
                    .foregroundStyle(theme.ink.opacity(0.7))
            }

            if !email.keywords.isEmpty {
                HStack(spacing: 6) {
                    ForEach(email.keywords.sorted(), id: \.self) { keyword in
                        Text(keyword)
                            .font(AppFont.ui(11, weight: .medium))
                            .foregroundStyle(theme.readableOnAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.accent))
                    }
                }
            }
        }
    }

    /// The relay serves HTML bodies inline on /api/inbox; plain-text messages
    /// come through without markup, so sniff for tags before using WebKit.
    private var bodyLooksLikeHTML: Bool {
        email.body.range(
            of: "<(html|head|body|div|p|br|table|tr|td|a|img|span|ul|ol|li|h[1-6])[\\s>/]",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private var pgpState: PgpMessageState {
        pgpMessageState(
            pgpEncrypted: email.pgpEncrypted,
            pgpDecryptError: email.pgpDecryptError,
            body: email.body
        )
    }

    /// Neither unreadable state has content to render; showing an empty
    /// WebView for them is the defect this change fixes.
    private var suppressesBody: Bool {
        pgpState == .clientProtected || pgpState == .decryptFailed
    }

    /// Wraps the message HTML in the same themed scaffold Android uses
    /// (EmailDetailActivity), so colors track the active palette.
    private func themedHTML(_ body: String) -> String {
        """
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
                body {
                    font-family: ui-monospace, Menlo, monospace;
                    font-size: 14px;
                    line-height: 1.5;
                    color: \(cssHex(theme.inkStrong));
                    background-color: \(cssHex(theme.bg));
                    margin: 0;
                    padding: 12px;
                    word-break: break-word;
                }
                a { color: \(cssHex(theme.accent)); }
                img { max-width: 100%; height: auto; }
                pre { white-space: pre-wrap; }
            </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    private func cssHex(_ color: Color) -> String {
        let resolved = color.resolve(in: environment)
        func channel(_ value: Float) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            channel(resolved.red), channel(resolved.green), channel(resolved.blue)
        )
    }

    /// Mirrors the web reader's two security badges (frontend ReadPage.tsx).
    @ViewBuilder
    private var pgpBadges: some View {
        HStack(spacing: 6) {
            StatusBadgeView(
                label: pgpState == .decryptFailed ? "PGP: could not decrypt" : "PGP: encrypted",
                isActive: pgpState != .decryptFailed
            )
            if showsSignaturePill(state: pgpState, signed: email.pgpSigned) {
                StatusBadgeView(
                    label: email.pgpVerified ? "signature verified" : "signature not verified",
                    isActive: email.pgpVerified
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// Same shape as remoteContentBanner below. Copy is ported verbatim from
    /// kypost-android's strings.xml — do not reword.
    @ViewBuilder
    private var pgpBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: pgpState == .decryptFailed ? "exclamationmark.triangle.fill" : "lock.fill")
                .foregroundStyle(theme.ink.opacity(0.7))
            Text(pgpBannerText)
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let webmailURL {
                Button("Open in webmail") { openURL(webmailURL) }
                    .font(AppFont.ui(12, weight: .medium))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
    }

    private var pgpBannerText: String {
        switch pgpState {
        case .clientProtected:
            webmailURL == nil
                ? "This message is end-to-end encrypted. Only your browser holds the key, so it can't be read here.\nCouldn't work out this server's web address — open this message in your browser."
                : "This message is end-to-end encrypted. Only your browser holds the key, so it can't be read here."
        case .decryptFailed:
            "This message is encrypted and couldn't be decrypted: \(email.pgpDecryptError)"
        case .decryptedByServer:
            "This message was encrypted. The server decrypted it to show it here."
        case .none:
            ""
        }
    }
}

/// Wraps downloaded attachment bytes for `fileExporter`. The generic `.data`
/// content type keeps the attachment's own filename extension authoritative.
private struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var name: String
    var data: Data

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        name = configuration.file.filename ?? "attachment"
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Renders one email's HTML; link taps open in the default browser instead
/// of navigating the message view.
///
/// Sender-controlled HTML is untrusted input, the same way it is in any mail
/// client: JavaScript execution is disabled unconditionally (mainstream mail
/// clients — Apple Mail, Thunderbird, Outlook — do the same in their message
/// view), and remote resources (images, stylesheets, anything with a network
/// fetch of its own) are blocked by default, matching those clients'
/// "load remote content" opt-in, so a message can't silently beacon home or
/// probe the local network the moment it's opened.
struct EmailBodyWebView: View {
    let html: String

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var page: WebPage?
    @State private var allowsRemoteContent = false

    private struct LoadKey: Equatable {
        let html: String
        let allowsRemoteContent: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !allowsRemoteContent {
                remoteContentBanner
            }
            Group {
                if let page {
                    WebView(page)
                        .webViewBackForwardNavigationGestures(.disabled)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: LoadKey(html: html, allowsRemoteContent: allowsRemoteContent)) {
            // Rebuilt (not reused) whenever `allowsRemoteContent` changes —
            // `loadsSubresources` is fixed at configuration time, so opting
            // in to remote content requires a fresh WebPage.
            let page = WebPage(
                configuration: Self.makeConfiguration(allowsRemoteContent: allowsRemoteContent),
                navigationDecider: LinksOpenExternally(openURL: openURL)
            )
            self.page = page
            page.load(html: html)
        }
    }

    private var remoteContentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(theme.ink.opacity(0.7))
            Text("Remote images and content are blocked.")
                .font(AppFont.ui(12))
                .foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            Button("Load Remote Content") { allowsRemoteContent = true }
                .font(AppFont.ui(12, weight: .medium))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: Shape.field))
    }

    /// Pure so the hardening it applies (JS off unconditionally, remote
    /// content gated) is directly testable without touching WebKit itself.
    static func makeConfiguration(allowsRemoteContent: Bool) -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.loadsSubresources = allowsRemoteContent
        return configuration
    }

    /// Only a real link tap reaches here — JavaScript is disabled above, so
    /// a script-driven redirect of this navigation is no longer possible.
    private struct LinksOpenExternally: WebPage.NavigationDeciding {
        let openURL: OpenURLAction

        func decidePolicy(
            for action: WebPage.NavigationAction,
            preferences: inout WebPage.NavigationPreferences
        ) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated else { return .allow }
            if let url = action.request.url {
                openURL(url)
            }
            return .cancel
        }
    }
}
