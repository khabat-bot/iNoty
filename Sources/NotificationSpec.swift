import Foundation

struct SpecError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct NotificationAction {
    let id: String
    let title: String
    let destructive: Bool
    let foreground: Bool
    let authRequired: Bool
    let url: String?

    /// What defines the button itself (the url is per notification and not part of the category).
    var descriptor: [String: Any] {
        ["id": id, "title": title, "destructive": destructive, "foreground": foreground, "auth": authRequired]
    }
}

/// Everything a request can control about a notification.
struct NotificationSpec {
    var id: String?
    var title = ""
    var subtitle: String?
    var body = ""
    var sound = "default"                 // default | none | ringtone
    var badge: Int?
    var interruptionLevel: String?        // passive | active | timeSensitive
    var relevanceScore: Double?
    var threadId: String?
    var summaryArgument: String?
    var summaryArgumentCount: Int?
    var targetContentId: String?
    var url: String?                      // opened when the notification is tapped
    var imageURL: String?
    var imageBase64: String?
    var delay: Double?                    // seconds
    var repeats = false
    var at: Date?
    var actions: [NotificationAction] = []
    var data: [String: Any] = [:]
}

extension NotificationSpec {
    static func from(_ raw: [String: Any]) throws -> NotificationSpec {
        var s = NotificationSpec()

        s.id = raw.string("id", "identifier")
        s.title = String((raw.string("title") ?? "").prefix(200))
        s.subtitle = raw.string("subtitle").map { String($0.prefix(200)) }
        s.body = String((raw.string("body", "message", "text") ?? "").prefix(2000))
        guard !s.title.isEmpty || !s.body.isEmpty else { throw SpecError("need title or body") }

        if let snd = raw.string("sound") {
            let v = snd.lowercased()
            guard ["default", "none", "ringtone"].contains(v) else {
                throw SpecError("sound must be default, none or ringtone")
            }
            s.sound = v
        }

        if raw["badge"] != nil {
            guard let b = raw.int("badge") else { throw SpecError("badge must be a number") }
            s.badge = max(b, 0)
        }

        if let lvl = raw.string("level", "interruptionLevel", "interruption") {
            let v = lvl.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            switch v {
            case "passive": s.interruptionLevel = "passive"
            case "active": s.interruptionLevel = "active"
            case "timesensitive": s.interruptionLevel = "timeSensitive"
            default: throw SpecError("level must be passive, active or timeSensitive")
            }
        }

        if raw["relevance"] != nil || raw["relevanceScore"] != nil {
            guard let r = raw.double("relevance", "relevanceScore") else { throw SpecError("relevance must be a number") }
            s.relevanceScore = min(max(r, 0), 1)
        }

        s.threadId = raw.string("thread", "threadId", "group")
        s.summaryArgument = raw.string("summary", "summaryArgument")
        s.summaryArgumentCount = raw.int("summaryCount", "summaryArgumentCount")
        s.targetContentId = raw.string("target", "targetContentId")

        s.url = raw.string("url", "open")
        if let u = s.url, URL(string: u) == nil { throw SpecError("url is not valid") }

        s.imageURL = raw.string("image", "imageURL")
        s.imageBase64 = raw.string("imageBase64")
        if let u = s.imageURL {
            guard let parsed = URL(string: u), parsed.scheme?.lowercased() == "https" else {
                throw SpecError("image must be an https URL (or use imageBase64)")
            }
        }

        // Timing
        if raw["delay"] != nil {
            guard let d = raw.double("delay"), d > 0, d <= 31_536_000 else {
                throw SpecError("delay must be a number of seconds greater than 0")
            }
            s.delay = d
        }
        s.repeats = raw.bool("repeat", "repeats") ?? false
        if s.repeats {
            guard let d = s.delay, d >= 60 else { throw SpecError("repeat needs delay of at least 60 seconds") }
        }
        if let a = raw.string("at", "time", "date") {
            guard s.delay == nil else { throw SpecError("use either delay or at, not both") }
            guard let d = parseDate(a) else {
                throw SpecError("at must be an ISO 8601 date (2026-11-21T18:30:00+03:00) or a unix timestamp")
            }
            guard d > Date() else { throw SpecError("at is in the past") }
            s.at = d
        }

        // Buttons
        if let list = raw["actions"] {
            guard let arr = list as? [[String: Any]] else { throw SpecError("actions must be a list of objects") }
            guard arr.count <= 10 else { throw SpecError("at most 10 actions") }
            var seen = Set<String>()
            for (i, a) in arr.enumerated() {
                guard let title = a.string("title"), !title.isEmpty else {
                    throw SpecError("action \(i + 1) needs a title")
                }
                let id = a.string("id") ?? "action\(i + 1)"
                guard !seen.contains(id) else { throw SpecError("duplicate action id \(id)") }
                seen.insert(id)
                let url = a.string("url")
                if let u = url, URL(string: u) == nil { throw SpecError("action \(id) has an invalid url") }
                s.actions.append(NotificationAction(
                    id: id,
                    title: String(title.prefix(40)),
                    destructive: a.bool("destructive") ?? false,
                    // Opening a URL needs the app in the foreground.
                    foreground: url != nil ? true : (a.bool("foreground") ?? false),
                    authRequired: a.bool("auth", "authRequired") ?? false,
                    url: url
                ))
            }
        }

        // Custom payload
        if let d = raw["data"] ?? raw["userInfo"] {
            guard let dict = d as? [String: Any] else { throw SpecError("data must be an object") }
            s.data = dict
        }

        return s
    }

    private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // The last two have no time zone and are read in this phone's time zone.
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: string) { return d }
        }
        if let t = Double(string) { return Date(timeIntervalSince1970: t) }
        return nil
    }
}

// MARK: - Loose value coercion (query strings give strings, JSON gives real types)

private extension Dictionary where Key == String, Value == Any {
    func string(_ keys: String...) -> String? {
        for k in keys {
            guard let v = self[k] else { continue }
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        for k in keys {
            guard let v = self[k] else { continue }
            if let d = v as? Double { return d }
            if let s = v as? String, let d = Double(s) { return d }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for k in keys {
            guard let v = self[k] else { continue }
            if let i = v as? Int { return i }
            if let s = v as? String, let i = Int(s) { return i }
            if let d = v as? Double, d == d.rounded() { return Int(d) }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for k in keys {
            guard let v = self[k] else { continue }
            if let b = v as? Bool { return b }
            if let s = v as? String {
                switch s.lowercased() {
                case "1", "true", "yes", "on": return true
                case "0", "false", "no", "off": return false
                default: break
                }
            }
        }
        return nil
    }
}
