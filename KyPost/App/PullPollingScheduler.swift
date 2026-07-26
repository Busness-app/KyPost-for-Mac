//
//  PullPollingScheduler.swift
//  KyPost
//
//  Pull-mode polling cadence (spec §3): every 90 seconds while foregrounded,
//  immediately on foreground/pairing. Background: BGAppRefreshTask on iOS
//  (~15 min platform minimum); macOS resumes on wake and otherwise polls
//  full-time while running (spec FAQ).
//

import Foundation
import os

@MainActor
final class PullPollingScheduler {
    private let pushRepository: PushRepository
    private let pushSettingsStore: PushSettingsStore
    private let dispatcher: PushNotificationDispatcher
    private var pollingTask: Task<Void, Never>?

    init(
        pushRepository: PushRepository,
        pushSettingsStore: PushSettingsStore,
        dispatcher: PushNotificationDispatcher
    ) {
        self.pushRepository = pushRepository
        self.pushSettingsStore = pushSettingsStore
        self.dispatcher = dispatcher
    }

    /// Starts foreground polling (immediate poll, then every 90s).
    /// No-op unless delivery mode is pull.
    func startForegroundPolling() {
        guard pushSettingsStore.deliveryMode == .pull, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNow()
                try? await Task.sleep(for: .seconds(Config.foregroundRefreshInterval))
            }
        }
    }

    func stopForegroundPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Whether the 90s cadence is running (shutdown assertions in tests).
    var isPolling: Bool { pollingTask != nil }

    /// One poll: fetch, persist, present local notifications for new arrivals.
    func pollNow() async {
        guard pushSettingsStore.deliveryMode == .pull else { return }
        do {
            let delivered = try await pushRepository.pullOnce()
            for notification in delivered {
                await dispatcher.presentLocally(notification)
            }
        } catch MailSourceError.notPaired {
            // Not an error state; pairing just hasn't happened yet.
        } catch {
            Log.push.error("Pull poll failed: \(error)")
        }
    }
}
