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
    @State private var hostileConfirmationShown = false
    @State private var hostileProtectionMessage: String?
    private var gateService: CredentialGateService { SingletonGraph.shared.credentialGateService }
    @State private var credentialGateConfirmationShown = false
    @State private var credentialGateMessage: String?

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
            Toggle("Hostile Location Protection", isOn: hostileProtectionBinding)
                .disabled(!lockManager.isLockEnabled)
            if let hostileProtectionMessage {
                Text(hostileProtectionMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
        } footer: {
            Text("Keeps no mail, contacts, or attachments on this device — everything reloads from your server. For border crossings and other device-seizure risks. Requires Require Unlock to Open. Attachment previews still touch this device's temporary storage briefly while open.")
        }
        .confirmationDialog(
            "Enable Hostile Location Protection?",
            isPresented: $hostileConfirmationShown,
            titleVisibility: .visible
        ) {
            Button("Erase Local Cache & Enable", role: .destructive) {
                applyHostileProtection(true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Erases mail, contacts, and attachments cached on this device and closes open compose windows. Your mail stays on the server.")
        }

        Section {
            Toggle("Require unlock for notifications & MFA", isOn: credentialGateBinding)
                .disabled(!lockManager.isLockEnabled)
            if let credentialGateMessage {
                Text(credentialGateMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
            }
        } footer: {
            Text("Blocks background mail checks and MFA approvals until you open and unlock KyPost. On iPhone this covers all background delivery; on a Mac it applies while the screen is locked. Requires Require Unlock to Open.\n\nNote: new-mail notifications carry the sender and subject through Apple's push service and your KyPost relay.")
        }
        .confirmationDialog(
            "Delay notifications until unlocked?",
            isPresented: $credentialGateConfirmationShown,
            titleVisibility: .visible
        ) {
            Button("Require Unlock for Delivery") {
                if !gateService.enable() {
                    credentialGateMessage = String(
                        localized: "Nothing to protect yet — pair this device first."
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New-mail notifications and MFA approval requests will only be delivered after you open and unlock KyPost.")
        }
    }

    /// Enabling confirms first (it erases the local cache); disabling
    /// applies directly — the in-memory data is simply dropped. Both paths
    /// end in a graph rebuild, which recreates this whole view, so the
    /// toggle re-reads the store rather than mirroring it in state.
    private var hostileProtectionBinding: Binding<Bool> {
        Binding(
            get: { SingletonGraph.shared.hostileLocationProtectionStore.enabled },
            set: { enabled in
                if enabled {
                    hostileConfirmationShown = true
                } else {
                    applyHostileProtection(false)
                }
            }
        )
    }

    /// Enabling confirms first (delivery stops while locked); disabling
    /// applies directly, with one user-presence read to restore the secret.
    private var credentialGateBinding: Binding<Bool> {
        Binding(
            get: { gateService.isEnabled },
            set: { enabled in
                if enabled {
                    credentialGateConfirmationShown = true
                } else if gateService.disable() {
                    credentialGateMessage = nil
                } else {
                    credentialGateMessage = String(
                        localized: "Authentication is required to turn this off."
                    )
                }
            }
        )
    }

    private func applyHostileProtection(_ enabled: Bool) {
        do {
            try AppEnvironment.shared.setHostileLocationProtection(enabled)
            hostileProtectionMessage = nil
        } catch {
            hostileProtectionMessage = "Could not switch modes: \(error.localizedDescription)"
        }
    }

    /// Dependency rule: toggles 2 and 3 require the lock, so dropping the lock
    /// drops them too. The credential gate has to come off *first* and its
    /// failure has to abort the whole change: its toggle is disabled while the
    /// lock is off, and once the lock is off `requestUnlock` can no longer
    /// repopulate the in-memory secret, so turning the lock off over a failed
    /// `disable()` strands the device secret behind a prompt the user can no
    /// longer reach — silently, since the app just stops syncing.
    ///
    /// Hostile Location Protection stays *after* the lock flag is persisted:
    /// it rebuilds the graph, and a rebuild while `lockEnabled` is still true
    /// comes up with a fresh AppLockManager in the locked state.
    ///
    /// The cost of going gate-first is that declining the lock's own re-auth
    /// afterwards leaves the gate off with the lock still on. That state is
    /// visible, both toggles stay reachable, and nothing stops working — the
    /// opposite ordering's failure is none of those things.
    private var lockEnabledBinding: Binding<Bool> {
        Binding(
            get: { lockManager.isLockEnabled },
            set: { enabled in
                Task {
                    if !enabled, gateService.isEnabled, !gateService.disable() {
                        lockToggleMessage = String(
                            localized: "Turn off \"Require unlock for notifications & MFA\" first — it needs to be authenticated before this can be switched off."
                        )
                        return
                    }
                    if await lockManager.setLockEnabled(enabled) {
                        lockToggleMessage = nil
                        if !enabled,
                           SingletonGraph.shared.hostileLocationProtectionStore.enabled {
                            applyHostileProtection(false)
                        }
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
