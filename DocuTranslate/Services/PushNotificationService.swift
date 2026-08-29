import Foundation
import UIKit
import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

final class PushNotificationService: NSObject, ObservableObject {
    static let shared = PushNotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var fcmToken: String?

    private let promptedKey = "didPromptPushNotifications"

    private override init() {
        super.init()
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        #if canImport(FirebaseMessaging)
        if AppAnalytics.isConfigured {
            Messaging.messaging().delegate = self
        }
        #endif
        Task { @MainActor in
            await refreshStatus()
            if isAuthorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    @MainActor
    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        AppAnalytics.setUserProperty(isAuthorized ? "true" : "false", forName: "notifications_enabled")
    }

    /// Ask for permission once the user has completed a document, or from Settings.
    func requestAuthorizationIfNeeded(force: Bool = false) {
        Task { @MainActor in
            await refreshStatus()
            if authorizationStatus == .denied { return }
            if authorizationStatus == .authorized || authorizationStatus == .provisional {
                UIApplication.shared.registerForRemoteNotifications()
                return
            }
            let alreadyPrompted = UserDefaults.standard.bool(forKey: promptedKey)
            guard force || !alreadyPrompted else { return }
            UserDefaults.standard.set(true, forKey: promptedKey)

            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                await refreshStatus()
                AppAnalytics.log("notification_permission", [
                    "granted": granted ? "true" : "false"
                ])
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                AppAnalytics.log("notification_permission_failed")
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            requestAuthorizationIfNeeded(force: true)
        } else {
            UIApplication.shared.unregisterForRemoteNotifications()
            AppAnalytics.log("notifications_disabled")
        }
    }

    func didRegister(deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        if AppAnalytics.isConfigured {
            Messaging.messaging().apnsToken = deviceToken
        }
        #endif
        AppAnalytics.log("apns_registered", ["bytes": deviceToken.count])
    }

    func didFailToRegister(error: Error) {
        AppAnalytics.log("apns_register_failed")
        #if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
        #endif
    }
}

extension PushNotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AppAnalytics.log("notification_received", [
            "foreground": "true",
            "id": notification.request.identifier
        ])
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        AppAnalytics.log("notification_opened", [
            "id": response.notification.request.identifier,
            "action": response.actionIdentifier
        ])
        if userInfo["tab"] as? String == "history" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openHistoryTab, object: nil)
            }
        }
        completionHandler()
    }
}

#if canImport(FirebaseMessaging)
extension PushNotificationService: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        DispatchQueue.main.async {
            self.fcmToken = fcmToken
            if let fcmToken, !fcmToken.isEmpty {
                AppAnalytics.log("fcm_token_received")
            }
        }
    }
}
#endif

extension Notification.Name {
    static let openHistoryTab = Notification.Name("openHistoryTab")
}
