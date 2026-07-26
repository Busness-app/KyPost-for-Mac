//
//  HostileLocationProtectionStore.swift
//  KyPost
//
//  UserDefaults-backed flag for Hostile Location Protection (security-
//  hardening plan, Task 5). Plain defaults, not Keychain — the flag itself
//  isn't sensitive, matching Android's reasoning. Read at graph
//  construction to pick the in-memory database; flipping it goes through
//  AppEnvironment.setHostileLocationProtection, never here directly.
//

import Foundation

final class HostileLocationProtectionStore {
    private static let key = "security.hostileLocationProtection"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
