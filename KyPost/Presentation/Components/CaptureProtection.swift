//
//  CaptureProtection.swift
//  KyPost
//
//  Screen-capture mitigations (security-hardening plan, Task 7). The two
//  platforms genuinely diverge:
//
//  - macOS: NSWindow.sharingType = .none removes the window from screen
//    recordings and screen sharing. It does NOT block ⌘⇧3/⌘⇧4 system
//    screenshots — macOS has no API for that; disclosed, not papered over.
//  - iOS: there is no supported way to *prevent* screenshots or recording
//    of arbitrary views. The only mitigation is reactive: while the screen
//    is being captured/mirrored, cover the content. Plain screenshots are
//    deliberately not "blocked" — the secure-text-field overlay hack is
//    fragile, undocumented API abuse.
//

import SwiftUI

#if os(macOS)
import AppKit

private struct WindowSharingDisabler: NSViewRepresentable {
    final class SharingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = .none
        }
    }

    func makeNSView(context: Context) -> SharingView { SharingView() }
    func updateNSView(_ nsView: SharingView, context: Context) {}
}
#endif

#if os(iOS)
private struct CaptureBlurModifier: ViewModifier {
    @State private var isCaptured = UIScreen.main.isCaptured

    func body(content: Content) -> some View {
        content
            .overlay {
                if isCaptured {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Label("Hidden while the screen is recorded", systemImage: "eye.slash")
                            .font(AppFont.ui(14, weight: .medium))
                    }
                    .ignoresSafeArea()
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: UIScreen.capturedDidChangeNotification
                ) {
                    isCaptured = UIScreen.main.isCaptured
                }
            }
    }
}
#endif

extension View {
    /// macOS: excludes the hosting window from recordings/sharing.
    /// iOS: covers the content while a recording or mirror is active.
    @ViewBuilder
    func protectedFromCapture() -> some View {
#if os(macOS)
        background(WindowSharingDisabler())
#else
        modifier(CaptureBlurModifier())
#endif
    }
}
