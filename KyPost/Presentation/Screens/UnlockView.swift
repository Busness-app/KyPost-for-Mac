//
//  UnlockView.swift
//  KyPost
//
//  Full-window cover shown while the app is locked (security-hardening
//  plan, Task 2). Auto-attempts device-owner authentication on appear;
//  the button retries after a cancel or failure.
//
//  Presentation is per-platform: iOS uses a fullScreenCover from
//  MainTabView; macOS overlays each window's root via LockedOverlay.
//

import SwiftUI

struct UnlockView: View {
    @Environment(\.theme) private var theme

    let manager: AppLockManager

    @State private var resetConfirmationShown = false
    @State private var resetMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 42))
                .foregroundStyle(theme.accent)
            Text("KyPost is locked")
                .font(AppFont.ui(17, weight: .semibold))
                .foregroundStyle(theme.inkStrong)
            Button("Unlock") {
                Task { await manager.requestUnlock() }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)

            // The lock has no bypass, so a device that can no longer satisfy
            // the authenticator at all — biometric enrolment changed, passcode
            // removed — would otherwise strand the user permanently: the
            // setting that turns the lock off lives behind the lock.
            if manager.shouldOfferReset {
                VStack(spacing: 8) {
                    Text("Can't unlock? Resetting removes this device's pairing and everything KyPost has cached here. Your mail stays on your server.")
                        .font(AppFont.ui(13))
                        .foregroundStyle(theme.ink.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Reset KyPost on This Device") {
                        resetConfirmationShown = true
                    }
                    .buttonStyle(.bordered)
                    .tint(SemanticColors.danger)
                }
                .padding(.top, 12)
            }

            if let resetMessage {
                Text(resetMessage)
                    .font(AppFont.ui(13))
                    .foregroundStyle(SemanticColors.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .confirmationDialog(
            "Reset KyPost on this device?",
            isPresented: $resetConfirmationShown,
            titleVisibility: .visible
        ) {
            Button("Erase & Unpair", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the pairing, the app lock, and all cached mail, contacts, photos, attachments, and drafts. You'll need to pair this device again from the web app.")
        }
        .task { await manager.requestUnlock() }
    }

    private func reset() {
        do {
            try AppEnvironment.shared.resetAfterFailedUnlock()
            resetMessage = nil
        } catch {
            resetMessage = "Could not reset: \(error.localizedDescription)"
        }
    }
}

/// Covers a macOS window's content while locked; renders nothing on iOS
/// (which presents UnlockView as a fullScreenCover instead). Known limit,
/// disclosed in the plan: window-modal sheets sit above a root overlay.
struct LockedOverlay: View {
    private var manager: AppLockManager { SingletonGraph.shared.appLockManager }

    var body: some View {
#if os(macOS)
        if manager.isLocked {
            UnlockView(manager: manager)
        }
#endif
    }
}
