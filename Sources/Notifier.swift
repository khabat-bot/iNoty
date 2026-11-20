import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Human-readable notification permission / settings summary.
    var onStatus: (String) -> Void = { _ in }
    /// Result of the most recent attempt to hand a notification to iOS (or a permission error).
    var onDelivery: (String) -> Void = { _ in }

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, error in
            if let error = error {
                self?.onDelivery("Permission error: \(error.localizedDescription)")
            }
            self?.refreshStatus()
        }
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let auth: String
            switch s.authorizationStatus {
            case .notDetermined: auth = "Not asked yet"
            case .denied: auth = "Denied"
            case .authorized: auth = "Allowed"
            case .provisional: auth = "Provisional"
            case .ephemeral: auth = "Ephemeral"
            @unknown default: auth = "Unknown"
            }
            func name(_ v: UNNotificationSetting) -> String {
                switch v {
                case .enabled: return "on"
                case .disabled: return "off"
                default: return "n/a"
                }
            }
            self?.onStatus(
                "\(auth) (alerts \(name(s.alertSetting)), sound \(name(s.soundSetting)), "
                + "notification center \(name(s.notificationCenterSetting)), lock screen \(name(s.lockScreenSetting)))"
            )
        }
    }

    func post(title: String, body: String, subtitle: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = .default

        // trigger: nil delivers immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.onDelivery("Failed: \(error.localizedDescription)")
            } else {
                self?.onDelivery("Handed to iOS OK")
            }
        }
    }

    // Show banners even while the app is considered "foreground" (common inside LiveContainer).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
