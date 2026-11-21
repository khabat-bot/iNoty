import Foundation
import UIKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    // Notification categories (the button sets) registered so far, oldest first.
    // They are saved so buttons still work for notifications scheduled before a relaunch.
    private let lock = NSLock()
    private var categoryOrder: [String] = []
    private var categoryDescriptors: [String: [[String: Any]]] = [:]
    private static let savedKey = "inoty.categories"
    private static let maxCategories = 50

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        restoreCategories()
    }

    // MARK: Posting

    /// Builds and schedules the notification. `completion` gets the identifier used and an
    /// error message if something went wrong (it may run on any queue).
    func post(_ spec: NotificationSpec, completion: @escaping (_ identifier: String, _ error: String?) -> Void) {
        let identifier = spec.id ?? UUID().uuidString
        buildAttachment(spec) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                completion(identifier, err.description)
            case .success(let attachment):
                let request = self.makeRequest(spec, identifier: identifier, attachment: attachment)
                UNUserNotificationCenter.current().add(request) { error in
                    completion(identifier, error.map { Notifier.describe($0) })
                }
            }
        }
    }

    /// Removes one notification by id (pending and delivered), or everything when id is nil.
    func clear(id: String?) {
        let center = UNUserNotificationCenter.current()
        if let id = id, !id.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        } else {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
    }

    private func makeRequest(_ spec: NotificationSpec, identifier: String, attachment: UNNotificationAttachment?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = spec.title
        if let s = spec.subtitle { content.subtitle = s }
        content.body = spec.body

        switch spec.sound {
        case "none":
            content.sound = nil
        case "ringtone":
            if #available(iOS 15.2, *) {
                content.sound = UNNotificationSound.defaultRingtone
            } else {
                content.sound = UNNotificationSound.default
            }
        default:
            content.sound = UNNotificationSound.default
        }

        if let b = spec.badge { content.badge = NSNumber(value: b) }

        if let level = spec.interruptionLevel {
            switch level {
            case "passive": content.interruptionLevel = .passive
            case "timeSensitive": content.interruptionLevel = .timeSensitive
            default: content.interruptionLevel = .active
            }
        }
        if let r = spec.relevanceScore { content.relevanceScore = r }
        if let t = spec.threadId { content.threadIdentifier = t }
        if let s = spec.summaryArgument { content.summaryArgument = s }
        if let c = spec.summaryArgumentCount { content.summaryArgumentCount = max(c, 1) }
        if let t = spec.targetContentId { content.targetContentIdentifier = t }
        if let att = attachment { content.attachments = [att] }
        if let cat = categoryIdentifier(for: spec.actions) { content.categoryIdentifier = cat }

        var info: [String: Any] = (sanitize(spec.data) as? [String: Any]) ?? [:]
        if let u = spec.url { info["inoty_url"] = u }
        var actionURLs: [String: String] = [:]
        for a in spec.actions {
            if let u = a.url { actionURLs[a.id] = u }
        }
        if !actionURLs.isEmpty { info["inoty_action_urls"] = actionURLs }
        content.userInfo = info

        return UNNotificationRequest(identifier: identifier, content: content, trigger: makeTrigger(spec))
    }

    private func makeTrigger(_ spec: NotificationSpec) -> UNNotificationTrigger? {
        if let at = spec.at {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
            return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        }
        if let delay = spec.delay {
            // The spec parser guarantees delay > 0 and, when repeating, delay >= 60.
            return UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: spec.repeats)
        }
        return nil
    }

    /// UserInfo has to be property-list safe, so drop JSON nulls and anything odd.
    private func sanitize(_ value: Any) -> Any? {
        switch value {
        case is NSNull:
            return nil
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let clean = sanitize(v) { out[k] = clean }
            }
            return out
        case let array as [Any]:
            return array.compactMap { sanitize($0) }
        case let s as String:
            return s
        case let n as NSNumber:
            return n
        default:
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == UNErrorDomain && ns.code == UNError.Code.notificationsNotAllowed.rawValue {
            return "notifications not allowed (allow them in iOS settings; inside LiveContainer enable \"Fix Local Notification\")"
        }
        return ns.localizedDescription
    }

    // MARK: Image attachments

    private func buildAttachment(_ spec: NotificationSpec, completion: @escaping (Result<UNNotificationAttachment?, SpecError>) -> Void) {
        if let b64 = spec.imageBase64, !b64.isEmpty {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                completion(.failure(SpecError("imageBase64 is not valid base64")))
                return
            }
            completion(Notifier.attachment(from: data))
        } else if let urlString = spec.imageURL, let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(.failure(SpecError("image download failed: \(error.localizedDescription)")))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    completion(.failure(SpecError("image download failed: HTTP \(http.statusCode)")))
                    return
                }
                guard let data = data, !data.isEmpty else {
                    completion(.failure(SpecError("image download returned no data")))
                    return
                }
                completion(Notifier.attachment(from: data))
            }.resume()
        } else {
            completion(.success(nil))
        }
    }

    private static func attachment(from data: Data) -> Result<UNNotificationAttachment?, SpecError> {
        guard data.count <= 10_000_000 else { return .failure(SpecError("image is larger than 10 MB")) }

        let head = [UInt8](data.prefix(4))
        let ext: String
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            ext = "png"
        } else if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            ext = "jpg"
        } else if head.starts(with: [0x47, 0x49, 0x46]) {
            ext = "gif"
        } else {
            return .failure(SpecError("image must be PNG, JPEG or GIF"))
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inoty-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: file)
            // iOS moves the file into its own attachment store.
            let attachment = try UNNotificationAttachment(identifier: "image", url: file, options: nil)
            return .success(attachment)
        } catch {
            return .failure(SpecError("could not attach image: \(error.localizedDescription)"))
        }
    }

    // MARK: Buttons (categories)

    private static func categoryID(for descriptors: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: descriptors, options: [.sortedKeys])) ?? Data()
        var h: UInt64 = 5381
        for b in data { h = (h &* 33) &+ UInt64(b) }
        return "inoty." + String(h, radix: 16)
    }

    private static func makeCategory(id: String, descriptors: [[String: Any]]) -> UNNotificationCategory {
        let actions: [UNNotificationAction] = descriptors.map { d in
            var options: UNNotificationActionOptions = []
            if (d["destructive"] as? Bool) == true { options.insert(.destructive) }
            if (d["foreground"] as? Bool) == true { options.insert(.foreground) }
            if (d["auth"] as? Bool) == true { options.insert(.authenticationRequired) }
            return UNNotificationAction(
                identifier: (d["id"] as? String) ?? "",
                title: (d["title"] as? String) ?? "",
                options: options
            )
        }
        return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
    }

    private func buildCategoriesLocked() -> Set<UNNotificationCategory> {
        var set = Set<UNNotificationCategory>()
        for id in categoryOrder {
            if let d = categoryDescriptors[id] {
                set.insert(Notifier.makeCategory(id: id, descriptors: d))
            }
        }
        return set
    }

    private func categoryIdentifier(for actions: [NotificationAction]) -> String? {
        guard !actions.isEmpty else { return nil }
        let descriptors = actions.map { $0.descriptor }
        let id = Notifier.categoryID(for: descriptors)

        lock.lock()
        var categories: Set<UNNotificationCategory>?
        var saved: [String] = []
        if categoryDescriptors[id] == nil {
            categoryOrder.append(id)
            categoryDescriptors[id] = descriptors
            while categoryOrder.count > Notifier.maxCategories {
                let oldest = categoryOrder.removeFirst()
                categoryDescriptors[oldest] = nil
            }
            categories = buildCategoriesLocked()
            for cid in categoryOrder {
                if let d = categoryDescriptors[cid],
                   let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    saved.append(json)
                }
            }
        }
        lock.unlock()

        if let categories = categories {
            UNUserNotificationCenter.current().setNotificationCategories(categories)
            UserDefaults.standard.set(saved, forKey: Notifier.savedKey)
        }
        return id
    }

    private func restoreCategories() {
        let saved = UserDefaults.standard.stringArray(forKey: Notifier.savedKey) ?? []
        lock.lock()
        for json in saved {
            guard let data = json.data(using: .utf8),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            let id = Notifier.categoryID(for: list)
            if categoryDescriptors[id] == nil {
                categoryOrder.append(id)
                categoryDescriptors[id] = list
            }
        }
        let categories = buildCategoriesLocked()
        lock.unlock()
        if !categories.isEmpty {
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Show banners even while the app is considered "foreground" (common inside LiveContainer).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    // Tapping the notification (or one of its buttons) can open a URL.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        var target: String?
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            target = info["inoty_url"] as? String
        } else if let map = info["inoty_action_urls"] as? [String: String] {
            target = map[response.actionIdentifier]
        }
        if let target = target, let url = URL(string: target) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
        completionHandler()
    }
}
