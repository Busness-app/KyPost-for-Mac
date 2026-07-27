//
//  KyPostApp.swift
//  KyPost
//
//  App entry point: platform delegate, dependency graph, theme, router,
//  deep links, and notification-tap routing. iOS gets the tab layout;
//  macOS gets the split-view window + Preferences + menu commands.
//

import SwiftUI
import SwiftData

@main
struct KyPostApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif

    @State private var themeManager = ThemeManager()
    // The router deliberately outlives graph rebuilds (it holds navigation
    // state, not graph state); DeepLinkHandler is a stateless parser.
    @State private var router = NavigationRouter()

    private var graph: SingletonGraph { .shared }
    private var environment: AppEnvironment { .shared }

    var body: some Scene {
#if os(macOS)
        mainWindow
            .commands {
                KyPostCommands(router: router)
            }

        // Pop-out reader: one window per email, keyed by relay server id.
        WindowGroup("Email", id: "email", for: String.self) { $serverId in
            EmailWindowView(serverId: serverId ?? "")
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
        }
        .defaultSize(width: 680, height: 620)

        // Compose in its own resizable window (⌘N / toolbar); reply/forward
        // pass a prefill draft, plain compose opens with none.
        WindowGroup("New Email", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft)
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
                .modifier(CloseOnHostileLocationProtection(draft: $draft))
        }
        .defaultSize(width: 640, height: 560)

        Settings {
            MacPreferencesView()
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                // AGENTS.md: every scene carries the lock cover. This one did
                // not, so ⌘, reached Remove Pairing (which clears the pinned
                // SPKI hash) and the Hostile Location Protection toggle while
                // the app was locked.
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
        }
#else
        mainWindow
#endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            rootView
                // Rebuilds (Hostile Location Protection) tear down the whole
                // tree, so no view model outlives its graph.
                .id(environment.generation)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .onOpenURL { url in
                    router.handleURL(url)
                }
                .onAppear {
                    // Notification taps (mail body / MFA fallback) route here.
                    graph.pushNotificationDispatcher.onNavigate = { [weak router] action in
                        router?.handle(action)
                    }
                }
                .task {
                    await graph.runStartupMigrationsIfNeeded()
                }
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
                .protectedFromCapture()
        }
        .modelContainer(environment.graph.database.container)
    }

    @ViewBuilder
    private var rootView: some View {
#if os(macOS)
        MacRootView()
#else
        MainTabView()
#endif
    }
}

#if os(macOS)
/// Closes a compose window when Hostile Location Protection is toggled.
///
/// Two things have to happen and only one of them is the visible one: the
/// scene value is archived for state restoration, and a reply's draft body is
/// the full quoted plaintext of the received message — so clearing the binding
/// is what actually removes mail text from disk. `dismissWindow` lives in the
/// SwiftUI environment and is only reachable from a View, which is why this is
/// a modifier rather than a call in `AppEnvironment`.
private struct CloseOnHostileLocationProtection: ViewModifier {
    @Binding var draft: ComposeDraft?
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .kyPostCloseComposeWindows)
        ) { _ in
            draft = nil
            dismissWindow(id: "compose")
        }
    }
}
#endif
