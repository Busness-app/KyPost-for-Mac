//
//  KyPostCommands.swift
//  KyPost
//
//  macOS menu bar integration (spec Phase 7).
//

#if os(macOS)
import SwiftUI

struct KyPostCommands: Commands {
    let router: NavigationRouter

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About KyPost") {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Email") {
                openWindow(id: "compose")
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Mailbox") {
            Button("Refresh Inbox") {
                Task { await SingletonGraph.shared.inboxViewModel.refresh() }
            }
            .keyboardShortcut("r")

            Button("Sync Contacts") {
                Task { await SingletonGraph.shared.contactsViewModel.sync() }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Check Notifications Now") {
                Task { await SingletonGraph.shared.pullPollingScheduler.pollNow() }
            }
        }
    }
}
#endif
