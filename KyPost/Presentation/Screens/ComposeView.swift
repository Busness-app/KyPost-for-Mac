//
//  ComposeView.swift
//  KyPost
//
//  Compose UI (spec §7): aligned header fields, a rich-text body
//  (Bold/Italic/Underline toolbar + system formatting controls; formatted
//  drafts send as mode:"html"), and attachments via file picker or drag &
//  drop. macOS shows this in its own window ("compose" WindowGroup,
//  ⌘↩ sends); iOS presents it as a sheet. Errors show inline and keep the
//  draft in memory.
//

import SwiftUI
import UniformTypeIdentifiers

/// Anchors each recipient row so the dropdown can be positioned against it
/// from the top of the view tree.
private struct RecipientAnchorKey: PreferenceKey {
    static let defaultValue: [RecipientField: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [RecipientField: Anchor<CGRect>],
        nextValue: () -> [RecipientField: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

struct ComposeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontResolutionContext) private var fontResolutionContext

    @State private var viewModel: ComposeViewModel
    @State private var selection = AttributedTextSelection()
    @State private var showFileImporter = false
    @State private var showAddressBook = false
    /// nil = nothing highlighted. The dropdown opens with no selection so
    /// Return commits what was actually typed; see `handleKey`.
    @State private var highlighted: Int?
    @FocusState private var focusedField: RecipientField?

    /// `draft` prefills reply/reply-all/forward compositions.
    init(draft: ComposeDraft? = nil) {
        _viewModel = State(initialValue: ComposeViewModel(
            sendEmail: SingletonGraph.shared.sendEmailUseCase,
            contacts: SingletonGraph.shared.contactsViewModel,
            pgp: SingletonGraph.shared.pgpSendService,
            draft: draft
        ))
    }

    var body: some View {
#if os(macOS)
        content
            .frame(minWidth: 560, minHeight: 480)
#else
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
        }
#endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            headerFields
                .padding(.horizontal)
                .padding(.vertical, 10)

            Divider().overlay(theme.line)

            TextEditor(text: $viewModel.body, selection: $selection)
                .font(AppFont.mono(14))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .textInputFormattingControlVisibility(.visible, for: .all)
                .padding(8)
                .frame(minHeight: 160)

            if !viewModel.attachments.isEmpty {
                attachmentBar
            }

            if let message = viewModel.errorMessage {
                Text(message)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .background(theme.bg)
        // The dropdown is anchored from up here rather than overlaid on the
        // field itself: as a sibling of the whole stack it draws reliably
        // over the AppKit-hosted TextEditor, can spill outside the header
        // Grid, and still inherits the theme.
        .overlayPreferenceValue(RecipientAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let field = viewModel.suggestionsField,
                   let anchor = anchors[field] {
                    dropdown(field: field, rect: proxy[anchor], in: proxy.size)
                }
            }
        }
        .toast(message: viewModel.toastMessage)
        .navigationTitle("New Email")
        .toolbar { toolbarContent }
        .task { await viewModel.loadContactsIfNeeded() }
        .sheet(isPresented: $showAddressBook) {
            AddressBookView(viewModel: viewModel)
                .environment(\.theme, theme)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    viewModel.addAttachment(from: url)
                }
            }
        }
        // Dragging files from Finder anywhere onto the compose surface
        // attaches them (addAttachment ignores non-file URLs).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            for url in files {
                viewModel.addAttachment(from: url)
            }
            return true
        }
        .onChange(of: viewModel.didSend) {
            if viewModel.didSend { dismiss() }
        }
        // Leaving a field commits what's in it, so a typed address isn't
        // quietly lost by clicking away. The dropdown belongs to the field
        // that had focus, so it closes on any change — not just on losing
        // focus entirely, or it would hang over the next field.
        .onChange(of: focusedField) { previous, current in
            guard previous != current else { return }
            if let previous {
                viewModel.commitPendingInput(for: previous, reportingErrors: false)
            }
            viewModel.closeSuggestions()
            highlighted = nil
        }
        .tint(theme.accent)
    }

    // MARK: - Header fields

    private var headerFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(RecipientField.allCases, id: \.self) { field in
                headerRow(field.label) {
                    recipientField(field)
                }
            }
            headerRow("Subject:") {
                TextField("", text: $viewModel.subject)
                    .font(AppFont.ui(14, weight: .medium))
                    .textFieldStyle(.plain)
            }
        }
#if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
#endif
    }

    private func headerRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        GridRow {
            Text(label)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(theme.ink.opacity(0.7))
                .gridColumnAlignment(.trailing)
            field()
                .foregroundStyle(theme.inkStrong)
        }
    }

    private func recipientField(_ field: RecipientField) -> some View {
        HStack(spacing: 6) {
            RecipientTokenField(
                placeholder: field == .to ? "recipient@example.com" : "",
                tokens: Binding(
                    get: { viewModel[field] },
                    set: { viewModel[field] = $0 }
                ),
                input: Binding(
                    get: { viewModel[input: field] },
                    set: { viewModel[input: field] = $0 }
                ),
                onCommit: { commit(field) },
                onRemove: { viewModel.remove($0, from: field) }
            )
            .focused($focusedField, equals: field)
            .onChange(of: viewModel[input: field]) {
                guard focusedField == field else { return }
                highlighted = nil
                viewModel.updateSuggestions(for: field)
            }
            .anchorPreference(key: RecipientAnchorKey.self, value: .bounds) { [field: $0] }
            .onKeyPress { handleKey($0, in: field) }

            if field == .to {
                Button {
                    showAddressBook = true
                } label: {
                    Image(systemName: "text.book.closed")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.ink.opacity(0.7))
                .help("Browse contacts")
                .accessibilityLabel("Browse contacts")
            }
        }
    }

    // MARK: - Recipient input

    private func commit(_ field: RecipientField) {
        if let highlighted, viewModel.suggestionsField == field,
           viewModel.suggestions.indices.contains(highlighted) {
            viewModel.selectSuggestion(viewModel.suggestions[highlighted], for: field)
        } else {
            viewModel.commitPendingInput(for: field)
        }
        highlighted = nil
    }

    /// Key events bubble up the focus chain, so this fires while the inner
    /// TextField still holds focus. `.ignored` hands the key back for normal
    /// editing; `.handled` swallows it.
    private func handleKey(_ press: KeyPress, in field: RecipientField) -> KeyPress.Result {
        let isOpen = viewModel.suggestionsField == field
        switch press.key {
        case .downArrow where isOpen:
            let count = viewModel.suggestions.count
            guard count > 0 else { return .ignored }
            highlighted = highlighted.map { min($0 + 1, count - 1) } ?? 0
            return .handled
        case .upArrow where isOpen:
            guard viewModel.suggestions.count > 0 else { return .ignored }
            // Arrowing off the top returns to "nothing selected" rather than
            // sticking on row 0, so the typed text is reachable again.
            highlighted = highlighted.flatMap { $0 == 0 ? nil : $0 - 1 }
            return .handled
        case .escape where isOpen:
            // Must be handled: on iOS compose is a sheet, and an unhandled
            // Escape from a hardware keyboard would dismiss it and bin the
            // draft.
            viewModel.closeSuggestions()
            highlighted = nil
            return .handled
        case .return where highlighted != nil:
            commit(field)
            return .handled
        case .tab where highlighted != nil:
            commit(field)
            return .handled
        default:
            // No backspace-deletes-last-token case: AppKit's field editor
            // swallows backspace before onKeyPress sees it, at any level of
            // the focus chain, even with the field empty. The only known way
            // around it is a zero-width sentinel character in the text, which
            // corrupts paste and selection. Tokens come off via their X
            // button, which works on both platforms.
            return .ignored
        }
    }

    // MARK: - Suggestions

    private func dropdown(field: RecipientField, rect: CGRect, in size: CGSize) -> some View {
        let width = max(rect.width, 240)
        let estimatedHeight = viewModel.suggestions.isEmpty
            ? 36
            : CGFloat(viewModel.suggestions.count) * 42 + 8
        // Flip above the field when there isn't room below — the iOS
        // keyboard makes this the common case, not the rare one.
        let fitsBelow = size.height - rect.maxY >= estimatedHeight
        let y = fitsBelow ? rect.maxY + 4 : rect.minY - estimatedHeight - 4

        return ContactSuggestionsDropdown(
            matches: viewModel.suggestions,
            highlighted: highlighted,
            onHighlight: { highlighted = $0 },
            onSelect: { match in
                viewModel.selectSuggestion(match, for: field)
                highlighted = nil
                focusedField = field
            }
        )
        .frame(width: width, alignment: .topLeading)
        .position(x: rect.minX + width / 2, y: y + estimatedHeight / 2)
    }

    // MARK: - Attachments

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .font(AppFont.ui(12, weight: .medium))
                                .foregroundStyle(theme.inkStrong)
                                .lineLimit(1)
                            Text(attachment.data.count.formatted(.byteCount(style: .file)))
                                .font(AppFont.ui(10))
                                .foregroundStyle(theme.ink.opacity(0.7))
                        }
                        Button {
                            viewModel.removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.ink.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.panel, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Toolbar

    /// iOS keeps the nav bar to Cancel/title/Send (everything inline
    /// truncates the title and drops the attach button); formatting and
    /// attach live in the bottom bar instead.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
#if os(macOS)
        ToolbarItemGroup {
            formattingControls
            attachButton
        }
#else
        ToolbarItemGroup(placement: .bottomBar) {
            formattingControls
            Spacer()
            attachButton
        }
#endif
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await viewModel.send(fontTraits: fontTraits) }
            } label: {
                if viewModel.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.isSending)
            .help("Send (⌘↩)")
        }
    }

    private var formattingControls: some View {
        ControlGroup {
            Toggle(isOn: boldBinding) {
                Label("Bold", systemImage: "bold")
            }
            .keyboardShortcut("b")
            Toggle(isOn: italicBinding) {
                Label("Italic", systemImage: "italic")
            }
            .keyboardShortcut("i")
            Toggle(isOn: underlineBinding) {
                Label("Underline", systemImage: "underline")
            }
            .keyboardShortcut("u")
        }
    }

    private var attachButton: some View {
        Button {
            showFileImporter = true
        } label: {
            Label("Attach File", systemImage: "paperclip")
        }
        .help("Attach a file (max 25 MB total)")
    }

    // MARK: - Formatting

    /// Resolves a run's font to concrete traits so ComposeViewModel /
    /// RichTextHTML can tell bold/italic apart without a view environment.
    private var fontTraits: RichTextHTML.FontTraits {
        { [fontResolutionContext] font in
            let resolved = font.resolve(in: fontResolutionContext)
            return (resolved.isBold, resolved.isItalic)
        }
    }

    /// Bold/italic toggles follow the documented rich-TextEditor pattern:
    /// read the typing attributes, write through transformAttributes.
    private var boldBinding: Binding<Bool> {
        Binding {
            let font = selection.typingAttributes(in: viewModel.body).font ?? .default
            return font.resolve(in: fontResolutionContext).isBold
        } set: { isBold in
            viewModel.body.transformAttributes(in: &selection) {
                $0.font = ($0.font ?? .default).bold(isBold)
            }
        }
    }

    private var italicBinding: Binding<Bool> {
        Binding {
            let font = selection.typingAttributes(in: viewModel.body).font ?? .default
            return font.resolve(in: fontResolutionContext).isItalic
        } set: { isItalic in
            viewModel.body.transformAttributes(in: &selection) {
                $0.font = ($0.font ?? .default).italic(isItalic)
            }
        }
    }

    private var underlineBinding: Binding<Bool> {
        Binding {
            selection.typingAttributes(in: viewModel.body).underlineStyle != nil
        } set: { isOn in
            viewModel.body.transformAttributes(in: &selection) {
                $0.underlineStyle = isOn ? .single : nil
            }
        }
    }
}
