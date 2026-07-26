//
//  SecuritySettingsView.swift
//  KyPost
//
//  Security settings (security-hardening plan, Task 3): the three toggles
//  with Android's order and dependency rules. Only "Require Unlock to
//  Open" is live; Hostile Location Protection and the credential gate ship
//  disabled until their tasks land. Shared row content feeds both the iOS
//  screen here and MacPreferencesView's Security pane.
//

import SwiftUI

/// The section rows, shared by the iOS Form screen and the macOS pane.
struct SecuritySettingsContent: View {
    @Environment(\.theme) private var theme

    private var lockManager: AppLockManager { SingletonGraph.shared.appLockManager }
    @State private var lockToggleMessage: String?

    var body: some View {
        Section {
            Toggle("Require Unlock to Open", isOn: lockEnabledBinding)
            if let lockToggleMessage {
                Text(lockToggleMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
        } footer: {
            Text("Unlocks with Face ID, Touch ID, or this device's passcode. KyPost locks when it goes to the background (iOS) or the screen locks (Mac).")
        }

        Section {
            Toggle("Hostile Location Protection", isOn: .constant(false))
                .disabled(true)
        } footer: {
            Text("Keeps no mail, contacts, or attachments on this device — for border crossings and other device-seizure risks. Not available yet in this build; requires Require Unlock to Open.")
        }

        Section {
            Toggle("Require unlock for notifications & MFA", isOn: .constant(false))
                .disabled(true)
        } footer: {
            Text("Blocks background mail checks and MFA approvals until you open and unlock KyPost. Not available yet in this build; requires Require Unlock to Open.\n\nNote: new-mail notifications carry the sender and subject through Apple's push service and your KyPost relay.")
        }
    }

    private var lockEnabledBinding: Binding<Bool> {
        Binding(
            get: { lockManager.isLockEnabled },
            set: { enabled in
                Task {
                    if await lockManager.setLockEnabled(enabled) {
                        lockToggleMessage = nil
                    } else {
                        lockToggleMessage = enabled
                            ? String(localized: "Set a device passcode or login password first.")
                            : String(localized: "Authentication is required to turn this off.")
                    }
                }
            }
        )
    }
}

/// iOS screen, pushed from Settings. macOS uses SecurityPane instead.
struct SecuritySettingsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            SecuritySettingsContent()
                .listRowBackground(theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Security")
    }
}
