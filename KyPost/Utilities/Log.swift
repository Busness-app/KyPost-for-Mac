//
//  Log.swift
//  KyPost
//
//  Central os.Logger instances, one per subsystem area.
//

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.kysecurity.mail"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let mail = Logger(subsystem: subsystem, category: "mail")
    static let push = Logger(subsystem: subsystem, category: "push")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let storage = Logger(subsystem: subsystem, category: "storage")
}
