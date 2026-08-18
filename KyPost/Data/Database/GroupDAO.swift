//
//  GroupDAO.swift
//  KyPost
//
//  Data access for contact groups.
//

import Foundation
import SwiftData

@ModelActor
actor GroupDAO {
    /// Replaces the whole cache: `GET /api/groups` has no delta cursor, so
    /// every sync is a full refresh and anything absent from the response is
    /// a group that no longer exists.
    func replaceAll(_ groups: [ContactGroup]) throws {
        let incoming = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for existing in try modelContext.fetch(FetchDescriptor<GroupEntity>()) {
            guard let match = incoming[existing.id] else {
                modelContext.delete(existing)
                continue
            }
            existing.name = match.name
            existing.rev = match.rev
            seen.insert(existing.id)
        }
        for group in groups where !seen.contains(group.id) {
            modelContext.insert(GroupEntity(id: group.id, name: group.name, rev: group.rev))
        }
        try modelContext.save()
    }

    func listAll() throws -> [ContactGroup] {
        try modelContext.fetch(
            FetchDescriptor<GroupEntity>(sortBy: [SortDescriptor(\.name)])
        ).map(\.toDomain)
    }

    /// Names for a contact's `groupIDs`, in the group list's own order.
    /// Unknown ids are dropped rather than rendered raw — a bare UUID on a
    /// contact card is noise, and it means the groups cache is simply behind.
    func names(forIDs ids: [String]) throws -> [String] {
        let wanted = Set(ids)
        return try listAll().filter { wanted.contains($0.id) }.map(\.name)
    }

    func clearAll() throws {
        try modelContext.delete(model: GroupEntity.self)
        try modelContext.save()
    }
}
