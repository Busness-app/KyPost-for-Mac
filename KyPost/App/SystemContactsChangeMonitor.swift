//
//  SystemContactsChangeMonitor.swift
//  KyPost
//
//  Sync-back trigger: CNContactStoreDidChange fires for any Contacts
//  database change while the app runs (including our own exports), so
//  reconciles are debounced and a relay sync only follows when something
//  was actually imported — that also breaks the notification feedback loop.
//

import Contacts
import Foundation

final class SystemContactsChangeMonitor {
    private let exporter: SystemContactsExporter
    private let repository: ContactSyncRepository
    private var observer: (any NSObjectProtocol)?
    private var debounce: Task<Void, Never>?

    init(exporter: SystemContactsExporter, repository: ContactSyncRepository) {
        self.exporter = exporter
        self.repository = repository
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.reconcileSoon()
            }
        }
    }

    /// Unregisters the observer and cancels any pending debounce
    /// (AppEnvironment.rebuild shutdown path).
    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        debounce?.cancel()
        debounce = nil
    }

    /// Immediate pass, used on launch/foreground to catch cards added while
    /// the app wasn't running.
    func reconcileNow() async {
        let summary = await exporter.reconcileAll()
        if summary.imported > 0 {
            // Imported contacts are queued (needsSync); push them right away.
            _ = try? await repository.sync()
        }
    }

    private func reconcileSoon() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.reconcileNow()
        }
    }
}
