//
//  InboxViewModel.swift
//  KyPost
//
//  Inbox state: cached-first load, server refresh, keyword tab filtering,
//  and the 90-second foreground refresh cadence (spec §2).
//

import Foundation
import Observation

@Observable
@MainActor
final class InboxViewModel {
    private let mailRepository: MailRepository
    private let keywordRepository: KeywordRepository

    private(set) var folder = Config.defaultFolder
    private(set) var emails: [Email] = []
    private(set) var tabs: [KeywordTab] = []
    /// Server-side children of Inbox and Archive, for folder navigation.
    private(set) var inboxSubfolders: [MailFolder] = []
    private(set) var archiveSubfolders: [MailFolder] = []
    var selectedTab: String?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    private var refreshTask: Task<Void, Never>?

    init(mailRepository: MailRepository, keywordRepository: KeywordRepository) {
        self.mailRepository = mailRepository
        self.keywordRepository = keywordRepository
    }

    var filteredEmails: [Email] {
        guard let selectedTab else { return emails }
        return emails.filter { $0.keywords.contains(selectedTab) }
    }

    var folderDisplayName: String {
        StandardFolder.displayName(folder)
    }

    /// Switches to another server folder (Junk, Trash, Archive/…) and reloads,
    /// optionally landing on a keyword tab.
    func selectFolder(_ name: String, tab: String? = nil) async {
        guard folder != name else {
            selectedTab = tab
            return
        }
        folder = name
        selectedTab = tab
        emails = []
        tabs = []
        errorMessage = nil
        await load()
    }

    /// Best-effort fetch of Inbox and Archive children (paths come back full,
    /// e.g. "INBOX/Receipts", ready to use as the fetch mailbox).
    func loadSubfolders() async {
        if let folders = try? await mailRepository.listFolders(parent: StandardFolder.inbox) {
            inboxSubfolders = folders
        }
        if let folders = try? await mailRepository.listFolders(parent: StandardFolder.archive) {
            archiveSubfolders = folders
        }
    }

    /// Moves emails to another folder (drag & drop), then re-syncs the list.
    func move(serverIds: [String], to targetFolder: String) async {
        guard !serverIds.isEmpty, targetFolder != folder else { return }
        await removeAndSync(serverIds: serverIds, failureVerb: "move") { [self] in
            try await mailRepository.move(messageIds: serverIds, from: folder, to: targetFolder)
        }
    }

    /// Deletes emails (the relay moves them to Trash, or expunges them when
    /// this folder is already Trash), then re-syncs the list.
    func delete(serverIds: [String]) async {
        guard !serverIds.isEmpty else { return }
        await removeAndSync(serverIds: serverIds, failureVerb: "delete") { [self] in
            try await mailRepository.delete(messageIds: serverIds, from: folder)
        }
    }

    /// Archives emails (the relay moves them to Archive), then re-syncs.
    func archive(serverIds: [String]) async {
        guard !serverIds.isEmpty else { return }
        await removeAndSync(serverIds: serverIds, failureVerb: "archive") { [self] in
            try await mailRepository.archive(messageIds: serverIds, from: folder)
        }
    }

    /// Marks emails as read from the list (relay bulk action). Rows stay in
    /// place, so unlike the move-style actions there is no removal, and no
    /// re-sync on success — the optimistic flag flip already matches the
    /// server. (The relay has no "unread" action, so this is one-way.)
    func markRead(serverIds: [String]) async {
        guard !serverIds.isEmpty else { return }
        for index in emails.indices where serverIds.contains(emails[index].serverId) {
            emails[index].read = true
        }
        do {
            try await mailRepository.markRead(messageIds: serverIds, from: folder)
        } catch {
            errorMessage = "Could not mark as read: \(error.localizedDescription)"
            await refresh()
        }
    }

    /// Marks emails as junk (the relay moves them to Junk), then re-syncs.
    func markJunk(serverIds: [String]) async {
        guard !serverIds.isEmpty else { return }
        await removeAndSync(serverIds: serverIds, failureVerb: "mark as junk") { [self] in
            try await mailRepository.markSpam(messageIds: serverIds, from: folder)
        }
    }

    /// Folders an email in the current folder can be moved to, in the same
    /// order as the macOS sidebar (used by the Move To menus).
    var moveDestinations: [String] {
        let all = [StandardFolder.inbox]
            + inboxSubfolders.map(\.name)
            + [StandardFolder.junk, StandardFolder.trash, StandardFolder.archive]
            + archiveSubfolders.map(\.name)
        return all.filter { $0 != folder }
    }

    /// Optimistically drops `serverIds` from the list, runs the server
    /// operation, then refreshes so the list matches the server either way.
    private func removeAndSync(
        serverIds: [String],
        failureVerb: String,
        _ operation: () async throws -> Void
    ) async {
        emails.removeAll { serverIds.contains($0.serverId) }
        tabs = keywordRepository.visibleTabs(from: emails)
        do {
            try await operation()
        } catch {
            errorMessage = "Could not \(failureVerb): \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Instant display from the local cache, then a server refresh.
    func load() async {
        if let cached = try? await mailRepository.cachedFolder(folder), !cached.isEmpty {
            apply(emails: cached)
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            apply(emails: try await mailRepository.refreshFolder(folder))
            errorMessage = nil
        } catch MailSourceError.notPaired {
            errorMessage = "Pair this device (Settings → Connection) to load mail."
        } catch {
            errorMessage = "Could not refresh: \(error.localizedDescription)"
        }
    }

    /// Best-effort 90s refresh while the inbox is in the foreground (spec §2).
    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Config.foregroundRefreshInterval))
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func markRead(_ email: Email) async {
        try? await mailRepository.markRead(serverId: email.serverId, folder: email.folder)
        if let index = emails.firstIndex(where: { $0.serverId == email.serverId }) {
            emails[index].read = true
        }
    }

    /// Resolves a notification tap's messageId to a cached email.
    func email(withServerId serverId: String) -> Email? {
        emails.first { $0.serverId == serverId }
    }

    /// Attachment metadata for an email, fetched lazily when it's opened
    /// (the inbox listing carries none). Errors surface as an empty list.
    func attachments(for email: Email) async -> [EmailAttachment] {
        (try? await mailRepository.listAttachments(
            folder: email.folder, messageId: email.serverId
        )) ?? []
    }

    /// Raw bytes of one attachment (for Save As…), or nil on failure.
    func attachmentData(_ attachment: EmailAttachment, of email: Email) async -> Data? {
        do {
            return try await mailRepository.downloadAttachment(
                folder: email.folder,
                messageId: email.serverId,
                index: attachment.index
            )
        } catch {
            errorMessage = "Could not download attachment: \(error.localizedDescription)"
            return nil
        }
    }

    /// Downloads one attachment to a temporary file and returns its URL
    /// (for Quick Look / opening externally), or nil on failure.
    func downloadAttachment(_ attachment: EmailAttachment, of email: Email) async -> URL? {
        guard let cacheKey = Self.sanitizedCacheComponent(email.serverId) else {
            errorMessage = "Could not download attachment: invalid message id"
            return nil
        }
        guard let data = await attachmentData(attachment, of: email) else { return nil }
        do {
            let directory = Self.attachmentTempRoot
                .appending(path: "\(cacheKey)/\(attachment.index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeName = attachment.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\0", with: "")
            let file = directory.appending(path: safeName.isEmpty ? "attachment" : safeName)
            try data.write(to: file)
            return file
        } catch {
            errorMessage = "Could not download attachment: \(error.localizedDescription)"
            return nil
        }
    }

    /// Root of the Quick Look staging area for downloaded attachments.
    static var attachmentTempRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "attachments")
    }

    /// Deletes every staged attachment file. Run when Hostile Location
    /// Protection toggles (both directions), so no pre-toggle bytes survive
    /// the mode switch. Missing directory is fine.
    static func purgeAttachmentTempFiles() {
        try? FileManager.default.removeItem(at: attachmentTempRoot)
    }

    /// The relay-supplied `serverId` must never be trusted as a path
    /// component (mirrors the same guard in ContactPhotoCache.fileURL) — a
    /// crafted "../" value would otherwise redirect the cache write outside
    /// the intended attachments subtree.
    static func sanitizedCacheComponent(_ value: String) -> String? {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains(".."),
              !value.contains("\0")
        else { return nil }
        return value
    }

    private func apply(emails newEmails: [Email]) {
        emails = newEmails
        tabs = keywordRepository.visibleTabs(from: newEmails)
        if let selectedTab, !tabs.contains(where: { $0.name == selectedTab }) {
            self.selectedTab = nil
        }
    }
}
