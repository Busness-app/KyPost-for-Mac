//
//  ContactGroup.swift
//  KyPost
//
//  A server-side contact group. `Contact.groupIDs` holds these ids.
//

import Foundation

struct ContactGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var rev: Int = 0
}
