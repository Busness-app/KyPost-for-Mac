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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .task { await manager.requestUnlock() }
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
