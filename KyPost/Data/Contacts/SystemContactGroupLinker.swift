//
//  SystemContactGroupLinker.swift
//  KyPost
//
//  Materializes backend contact groups as CNGroups and keeps card membership
//  in step. Swift counterpart of kypost-android's
//  contacts/device/DeviceGroupLinker.kt.
//

import Contacts
import Foundation
import os

/// One direction only: **backend → device**. A group the user made in
/// Contacts is never turned into a backend group, matching
/// `Client_Contact_Update.md` Part 2 point 3 and Android's linker. This app
/// cannot create a backend group at all (`GET /api/groups` is pull-only), so
/// the reverse would have nowhere to go.
struct SystemContactGroupLinker {
    private let store: any SystemContactStoring
    private let linkStore: SystemContactGroupLinkStore

    init(store: any SystemContactStoring, linkStore: SystemContactGroupLinkStore) {
        self.store = store
        self.linkStore = linkStore
    }

    /// The CNGroup identifier for a backend group, creating or adopting one as
    /// needed, or nil when the store refused.
    ///
    /// Order matters, and mirrors the card path: an existing link wins (the
    /// name is corrected in place if the backend renamed the group); failing
    /// that, a group the user already has *by the same name* is adopted rather
    /// than duplicated; only then is a new one created.
    func ensureGroup(id: String, name: String) async -> String? {
        let existingGroups = (try? await store.listGroups()) ?? []

        if let link = linkStore.link(groupId: id) {
            // A link whose group vanished (deleted in Contacts) must not keep
            // claiming the id, or the group can never be re-materialized.
            if let live = existingGroups.first(where: { $0.identifier == link.cnIdentifier }) {
                // Never rename a group the user authored; we only adopted it.
                if !link.userOwned, live.name != name {
                    try? await store.renameGroup(identifier: link.cnIdentifier, to: name)
                }
                return link.cnIdentifier
            }
            linkStore.remove(groupId: id)
        }

        let linked = Set(linkStore.all().map(\.cnIdentifier))
        if let match = existingGroups.first(where: { $0.name == name && !linked.contains($0.identifier) }) {
            linkStore.upsert(SystemContactGroupLink(
                groupId: id,
                cnIdentifier: match.identifier,
                userOwned: true
            ))
            return match.identifier
        }

        let group = CNMutableGroup()
        group.name = name
        do {
            try await store.addGroup(group)
        } catch {
            Log.sync.error("Creating contact group failed: \(error.localizedDescription)")
            return nil
        }
        // The identifier is assigned by the save, so it is read back rather
        // than taken from the object we handed over.
        guard let created = (try? await store.listGroups())?
            .first(where: { $0.name == name && !linked.contains($0.identifier) })
        else { return nil }
        linkStore.upsert(SystemContactGroupLink(
            groupId: id,
            cnIdentifier: created.identifier,
            userOwned: false
        ))
        return created.identifier
    }

    /// Brings one card's membership in line with its contact's `groupIDs`.
    ///
    /// Removals are scoped to groups this app links: a card the user also put
    /// in their own "Climbing" group stays in it. Only memberships we are the
    /// source of truth for are withdrawn.
    func syncMembership(
        cardIdentifier: String,
        groupIDs: [String],
        groupNames: [String: String]
    ) async {
        var wanted: Set<String> = []
        for groupId in groupIDs {
            guard let name = groupNames[groupId], !name.isEmpty else { continue }
            if let cnIdentifier = await ensureGroup(id: groupId, name: name) {
                wanted.insert(cnIdentifier)
            }
        }

        for link in linkStore.all() {
            let members = (try? await store.memberIdentifiers(ofGroup: link.cnIdentifier)) ?? []
            let isMember = members.contains(cardIdentifier)
            if wanted.contains(link.cnIdentifier), !isMember {
                try? await store.addMember(
                    contactIdentifier: cardIdentifier,
                    toGroup: link.cnIdentifier
                )
            } else if !wanted.contains(link.cnIdentifier), isMember {
                try? await store.removeMember(
                    contactIdentifier: cardIdentifier,
                    fromGroup: link.cnIdentifier
                )
            }
        }
    }
}
