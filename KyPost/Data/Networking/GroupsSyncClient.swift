//
//  GroupsSyncClient.swift
//  KyPost
//
//  GET /api/groups. Pull-only: there is no delta cursor, so the caller always
//  fetches the full list and full-refreshes its cache. Two-way group
//  *creation* (POST /api/groups) is out of scope, matching Android's client
//  and Client_Contact_Update.md Part 2 point 3.
//

import Foundation

/// `GET /api/groups` responds `{"groups": [...]}`, not a bare array.
struct RelayGroupsListResponse: Decodable, Sendable {
    var groups: [RelayGroupDTO]?
}

/// Matches the backend's `groups.Group` JSON shape 1:1.
struct RelayGroupDTO: Decodable, Equatable, Sendable {
    var id: String?
    var name: String?
    var rev: Int?
}

struct GroupsSyncClient: Sendable {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
    }

    func pull(serverUrl: String, auth: RelayAuth) async throws -> [ContactGroup] {
        guard let base = URL(string: serverUrl) else {
            throw MailSourceError.invalidServerURL
        }
        let response = try await httpClient.get(
            RelayGroupsListResponse.self,
            url: base.appending(path: "api/groups"),
            headers: auth.headerFields
        )
        // A group with no id cannot be matched to Contact.groupIDs and cannot
        // be stored under a unique key, so it is dropped rather than given a
        // synthetic one.
        return (response.groups ?? []).compactMap { dto in
            guard let id = dto.id, !id.isEmpty else { return nil }
            return ContactGroup(id: id, name: dto.name ?? "", rev: dto.rev ?? 0)
        }
    }
}
