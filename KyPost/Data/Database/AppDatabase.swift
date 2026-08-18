//
//  AppDatabase.swift
//  KyPost
//
//  Owns the SwiftData ModelContainer for the local cache (spec §8).
//

import Foundation
import SwiftData

final class AppDatabase: Sendable {
    static let schema = Schema([
        EmailEntity.self,
        ContactEntity.self,
        PushNotificationEntity.self,
        KeywordEntity.self,
        GroupEntity.self,
    ])

    let container: ModelContainer
    /// True for tests and for Hostile Location Protection mode.
    let isInMemory: Bool

    /// - Parameter inMemory: no data is written to disk (tests, Hostile
    ///   Location Protection).
    init(inMemory: Bool = false) throws {
        isInMemory = inMemory
        let configuration = ModelConfiguration(
            schema: Self.schema,
            isStoredInMemoryOnly: inMemory
        )
        container = try ModelContainer(
            for: Self.schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// Where the on-disk store lives (the default ModelConfiguration URL,
    /// under Application Support).
    static var storeURL: URL {
        ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: false).url
    }

    /// Excludes the store files from iCloud/Finder backups — Apple has no
    /// allowBackup=false equivalent; it's per-file. Best effort: a failure
    /// is logged upstream, never fatal. Re-run after Hostile Location
    /// Protection recreates the file. Keychain items need nothing — the
    /// ThisDeviceOnly class is already excluded by construction.
    static func excludeStoreFromBackup(at url: URL = storeURL) throws {
        for suffix in ["", "-wal", "-shm"] {
            var file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        }
    }

    /// Removes the SQLite store plus its -wal/-shm siblings so nothing
    /// pre-toggle survives a Hostile Location Protection switch. Plain
    /// delete, not a secure overwrite (explicitly out of scope in the
    /// design). Missing files are not an error.
    static func deleteStoreFiles(at url: URL = storeURL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
