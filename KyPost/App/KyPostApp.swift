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
    @State private var router = NavigationRouter(
        deepLinkHandler: SingletonGraph.shared.deepLinkHandler
    )

    private var graph: SingletonGraph { .shared }

    var body: some Scene {
#if os(macOS)
        mainWindow
            .commands {
                KyPostCommands(router: router)
            }

        // Pop-out reader: one window per email, keyed by relay server id.
        WindowGroup("Email", id: "email", for: String.self) { $serverId in
            EmailWindowView(serverId: serverId ?? "")
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
        }
        .defaultSize(width: 680, height: 620)

        // Compose in its own resizable window (⌘N / toolbar); reply/forward
        // pass a prefill draft, plain compose opens with none.
        WindowGroup("New Email", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft)
                .environment(themeManager)
                .environment(router)
                .environment(\.theme, themeManager.palette)
                .preferredColorScheme(themeManager.palette.preferredColorScheme)
                .background(themeManager.palette.bg.ignoresSafeArea())
                .overlay { LockedOverlay().environment(\.theme, themeManager.palette) }
        }
        .defaultSize(width: 640, height: 560)

        Settings {
            MacPreferencesView()
                .environment(themeManager)
                .environment(router)
        }
#else
        mainWindow
#endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            rootView
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
        }
        .modelContainer(graph.database.container)
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
