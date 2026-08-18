//
//  GroupEntity.swift
//  KyPost
//
//  SwiftData entity for contact groups (GET /api/groups).
//

import Foundation
import SwiftData

/// Groups are pull-only and have no offline-edit queue: this device never
/// creates one (Client_Contact_Update.md Part 2 point 3), so there is no
/// `needsSync` here and no reconciliation to do. The list is small and has no
/// delta cursor, so every sync is a full refresh.
@Model
final class GroupEntity {
    @Attribute(.unique) var id: String
    var name: String
    var rev: Int

    init(id: String, name: String, rev: Int = 0) {
        self.id = id
        self.name = name
        self.rev = rev
    }
}

extension GroupEntity {
    var toDomain: ContactGroup {
        ContactGroup(id: id, name: name, rev: rev)
    }
}
