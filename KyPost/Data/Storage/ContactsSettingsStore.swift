//
//  ContactsSettingsStore.swift
//  KyPost
//
//  UserDefaults-backed contacts preferences: the "export to Apple Contacts"
//  toggle read by SystemContactsExporter before every export.
//

import Foundation

final class ContactsSettingsStore {
    private enum Key {
        static let exportToSystemEnabled = "contacts.exportToSystemEnabled"
        static let syncExplained = "contacts.syncExplained"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Set once the first-run contact-sync explainer has been acknowledged.
    /// Defaults to false so an existing install sees it once too — a user who
    /// never learned where their contacts go is the reason it exists.
    var syncExplained: Bool {
        get { defaults.bool(forKey: Key.syncExplained) }
        set { defaults.set(newValue, forKey: Key.syncExplained) }
    }

    /// User toggle from Preferences; when on, contact changes are mirrored to
    /// the system Contacts database after syncs and local edits.
    var exportToSystemContactsEnabled: Bool {
        get { defaults.object(forKey: Key.exportToSystemEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.exportToSystemEnabled) }
    }
}
