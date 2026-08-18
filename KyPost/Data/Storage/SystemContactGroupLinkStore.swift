//
//  SystemContactGroupLinkStore.swift
//  KyPost
//
//  Mapping between backend group ids and the CNGroup rows this app
//  materialized. UserDefaults-backed for the same reason as
//  SystemContactsLinkStore: it must survive the SwiftData wipe on a tooOld
//  re-pull, which reassigns local ids.
//

import Foundation

struct SystemContactGroupLink: Codable, Equatable, Sendable {
    /// Backend group id (`Contact.groupIDs` holds these).
    var groupId: String
    /// Identifier of the CNGroup this app links it to.
    var cnIdentifier: String
    /// True when the group already existed in Contacts and was adopted purely
    /// to avoid creating a duplicate. The app did not author it, so it is
    /// never renamed and never deleted — adoption is a de-duplication device,
    /// not a claim of ownership.
    var userOwned: Bool
}

final class SystemContactGroupLinkStore: @unchecked Sendable {
    private enum Key {
        static let links = "contacts.systemGroupLinks"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [SystemContactGroupLink] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Key.links) else { return [] }
        return (try? JSONDecoder().decode([SystemContactGroupLink].self, from: data)) ?? []
    }

    func link(groupId: String) -> SystemContactGroupLink? {
        all().first { $0.groupId == groupId }
    }

    func upsert(_ link: SystemContactGroupLink) {
        lock.lock(); defer { lock.unlock() }
        var links = decodeLocked()
        links.removeAll { $0.groupId == link.groupId }
        links.append(link)
        writeLocked(links)
    }

    func remove(groupId: String) {
        lock.lock(); defer { lock.unlock() }
        var links = decodeLocked()
        links.removeAll { $0.groupId == groupId }
        writeLocked(links)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Key.links)
    }

    private func decodeLocked() -> [SystemContactGroupLink] {
        guard let data = defaults.data(forKey: Key.links) else { return [] }
        return (try? JSONDecoder().decode([SystemContactGroupLink].self, from: data)) ?? []
    }

    private func writeLocked(_ links: [SystemContactGroupLink]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Key.links)
    }
}
