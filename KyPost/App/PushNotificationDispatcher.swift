//
//  PushNotificationDispatcher.swift
//  KyPost
//
//  UNUserNotificationCenter integration (spec §3, §5): category setup
//  (MAIL_NOTIFICATION, MFA_CHALLENGE with Approve/Deny), incoming payload
//  handling, local presentation for pull-mode arrivals, and routing taps to
//  NavigationActions for the UI layer (Phase 6 sets `onNavigate`).
//

import Foundation
import os
import UserNotifications

@MainActor
final class PushNotificationDispatcher: NSObject {
    static let mailCategoryId = "MAIL_NOTIFICATION"
    // Nonisolated: read from the nonisolated willPresent delegate callback.
    nonisolated static let mfaCategoryId = "MFA_CHALLENGE"
    static let approveActionId = "APPROVE"
    static let denyActionId = "DENY"

    private let pushRepository: PushRepository
    private let approveMfaChallenge: ApproveMfaChallengeUseCase
    private let pushSettingsStore: PushSettingsStore

    /// Set by the UI layer to route notification taps.
    var onNavigate: ((NavigationAction) -> Void)?

    init(
        pushRepository: PushRepository,
        approveMfaChallenge: ApproveMfaChallengeUseCase,
        pushSettingsStore: PushSettingsStore
    ) {
        self.pushRepository = pushRepository
        self.approveMfaChallenge = approveMfaChallenge
        self.pushSettingsStore = pushSettingsStore
    }

    // MARK: - Setup

    /// Registers categories and takes over as the center's delegate.
    /// Call once at launch, before any notification can arrive.
    func configure(center: UNUserNotificationCenter = .current()) {
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    /// Exposed as a pure value (rather than built inline inside `configure`)
    /// so its action options — notably that Approve requires device
    /// authentication — are directly testable without touching the real
    /// notification center.
    static var categories: Set<UNNotificationCategory> {
        let mailCategory = UNNotificationCategory(
            identifier: Self.mailCategoryId,
            actions: [], // no direct actions; tap opens inbox (spec §3)
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let mfaCategory = UNNotificationCategory(
            identifier: Self.mfaCategoryId,
            actions: [
                // Deny only. Approving now means picking the number the browser
                // is showing (the backend verifies it and refuses an approval
                // without it), and a banner cannot present that choice — an
                // Approve button here could only ever send a blind approval,
                // which the server rejects and which is precisely the tap an
                // MFA-fatigue attack harvests. Body tap opens the approval
                // screen instead.
                //
                // Deny stays: the safe answer must remain one tap away, because
                // the person most likely to press it is someone being fatigued,
                // looking at a number they cannot match.
                UNNotificationAction(identifier: Self.denyActionId, title: "Deny", options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        return [mailCategory, mfaCategory]
    }

    /// Spec §3: request at first app launch. Denial is fine — payloads are
    /// still parsed into in-app history.
    @discardableResult
    func requestAuthorization(center: UNUserNotificationCenter = .current()) async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if !granted {
                Log.push.warning("Notification authorization not granted — pushes will be delivered silently")
            }
            return granted
        } catch {
            Log.push.error("Notification authorization request failed: \(error)")
            return false
        }
    }

    // MARK: - Incoming payloads

    /// Processes a remote payload (APNs wake or `xcrun simctl push`).
    func handleIncoming(userInfo: [AnyHashable: Any]) async {
        guard let payload = PushPayloadMapper.map(userInfo: userInfo) else {
            Log.push.warning("Ignoring unrecognized push payload")
            return
        }
        switch payload {
        case .mail(let mail):
            // APNs already showed the system banner (aps.alert); record history.
            do {
                try await pushRepository.recordPushArrival(mail)
            } catch {
                Log.push.error("Failed to record push arrival: \(error)")
            }
        case .mfaChallenge:
            // Alert + action buttons come from the aps payload's category;
            // nothing to persist (spec §5: don't retain challenge data).
            break
        }
    }

    /// Presents a local notification for a pull-mode arrival (the server
    /// never contacted APNs in pull mode, spec §3).
    ///
    /// While the app lock is engaged the sender and subject are withheld:
    /// "Require Unlock to Open" is the toggle a user reads as "nobody sees my
    /// mail without authenticating", and putting a subject line on the lock
    /// screen is the most visible way to break that promise. The full entry is
    /// still recorded in history and shows once the app is unlocked.
    func presentLocally(
        _ notification: PushNotification,
        center: UNUserNotificationCenter = .current(),
        redactContent: Bool? = nil
    ) async {
        guard pushSettingsStore.systemNotificationsEnabled else { return }
        let redact = redactContent ?? SingletonGraph.shared.appLockManager.isLocked

        let content = UNMutableNotificationContent()
        content.title = redact
            ? String(localized: "KyPost")
            : notification.senderName
        content.body = redact
            ? String(localized: "New mail — unlock KyPost to read it")
            : notification.emailSubject
        content.sound = .default
        content.categoryIdentifier = Self.mailCategoryId
        content.userInfo = [
            "messageId": notification.messageId,
            "senderName": notification.senderName,
            "emailSubject": notification.emailSubject,
            "Keywords": notification.keywords,
        ]
        let request = UNNotificationRequest(
            identifier: "pull-\(notification.seq)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.push.error("Failed to present local notification: \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationDispatcher: UNUserNotificationCenterDelegate {
    /// Foreground presentation: MFA challenges are high priority (banner +
    /// sound, spec §3); mail shows a banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == Self.mfaCategoryId
            ? [.banner, .sound]
            : [.banner]
    }

    /// Action buttons and body taps.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case Self.approveActionId:
            // No longer registered (see `categories`), but a notification
            // delivered before this build was installed can still carry it.
            // Route it to the approval screen rather than sending a blind
            // approval the server would refuse.
            switch PushPayloadMapper.map(userInfo: userInfo) {
            case .mfaChallenge(let challenge):
                onNavigate?(.openMfaApproval(challenge))
            default:
                break
            }

        case Self.denyActionId:
            guard let challengeId = userInfo["challengeId"] as? String else { return }
            // Deny needs no number — the backend ignores matchDigits on a deny.
            let outcome = await approveMfaChallenge(challengeId: challengeId, approved: false)
            Log.push.info("MFA deny outcome: \(String(describing: outcome))")

        case UNNotificationDefaultActionIdentifier:
            // Body tap: MFA → in-app approval screen (spec §5); mail → inbox.
            switch PushPayloadMapper.map(userInfo: userInfo) {
            case .mfaChallenge(let challenge):
                onNavigate?(.openMfaApproval(challenge))
            case .mail(let mail):
                onNavigate?(.openEmail(messageId: mail.messageId))
            case nil:
                break
            }

        default:
            break
        }
    }
}
