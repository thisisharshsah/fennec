import Foundation
import Observation
import UserNotifications

/// The creature's voice while it has no speaker: what it says (and its daily-life notes) arrive as
/// notifications, and the Reply action sends the owner's answer back to the hub as speech.
/// Everything is kept in Messages either way; the options here only decide how loudly it arrives.
@MainActor @Observable
final class CreatureNotifier: NSObject {
    nonisolated static let category = "CREATURE_MESSAGE"
    nonisolated static let replyAction = "REPLY"

    enum Permission: Equatable {
        case unknown, granted, denied, notAsked
    }

    private enum Key {
        static let enabled = "notifications.enabled"
        static let sound = "notifications.sound"
        static let focus = "notifications.focus"
        static let quietHours = "notifications.quietHours"
        static let quietStart = "notifications.quietStart"
        static let quietEnd = "notifications.quietEnd"
        static func topic(_ topic: MessageTopic) -> String { "notifications.topic.\(topic.rawValue)" }
    }

    private(set) var permission: Permission = .unknown

    /// "Notify me": the master switch.
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var playsSound: Bool { didSet { defaults.set(playsSound, forKey: Key.sound) } }
    /// Deliver to Notification Center only: no banner, no sound.
    var isFocused: Bool { didSet { defaults.set(isFocused, forKey: Key.focus) } }
    var usesQuietHours: Bool { didSet { defaults.set(usesQuietHours, forKey: Key.quietHours) } }
    /// Minutes after midnight.
    var quietStart: Int { didSet { defaults.set(quietStart, forKey: Key.quietStart) } }
    var quietEnd: Int { didSet { defaults.set(quietEnd, forKey: Key.quietEnd) } }
    private(set) var topics: [MessageTopic: Bool]

    /// Only live messages become notifications, never the history replayed on connect.
    private static let freshness: TimeInterval = 90

    @ObservationIgnored private weak var client: BridgeClient?
    @ObservationIgnored private var posted = Set<String>()
    /// Opens a creature's conversation (set by the app model to the navigator).
    @ObservationIgnored var onOpenConversation: ((String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(client: BridgeClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        playsSound = defaults.object(forKey: Key.sound) as? Bool ?? true
        isFocused = defaults.bool(forKey: Key.focus)
        usesQuietHours = defaults.object(forKey: Key.quietHours) as? Bool ?? true
        quietStart = defaults.object(forKey: Key.quietStart) as? Int ?? 22 * 60
        quietEnd = defaults.object(forKey: Key.quietEnd) as? Int ?? 7 * 60
        var topics: [MessageTopic: Bool] = [:]
        for topic in MessageTopic.allCases {
            topics[topic] = defaults.object(forKey: Key.topic(topic)) as? Bool ?? true
        }
        self.topics = topics
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Say something back"
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reply], intentIdentifiers: [], options: [])
        ])
    }

    // MARK: Options

    func isOn(_ topic: MessageTopic) -> Bool { topics[topic] ?? true }

    func set(_ topic: MessageTopic, on: Bool) {
        topics[topic] = on
        defaults.set(on, forKey: Key.topic(topic))
    }

    /// Whether `date` falls inside quiet hours (the range may cross midnight).
    func isQuiet(at date: Date = .now) -> Bool {
        guard usesQuietHours, quietStart != quietEnd else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if quietStart < quietEnd { return minute >= quietStart && minute < quietEnd }
        return minute >= quietStart || minute < quietEnd
    }

    // MARK: Permission

    func requestAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshPermission()
        }
    }

    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permission = switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }

    /// The app icon badge: unread messages across every creature.
    func setBadge(_ count: Int) {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }

    // MARK: Posting

    /// Called for every event the app receives; posts the ones that are the creature talking.
    func handle(_ event: RoomEvent, creatureName: String) {
        guard event.isNotice, let text = event.text, !text.isEmpty else { return }
        let urgent = MessageTopic(kind: event.kind) == .safety
        guard urgent || (isEnabled && isOn(MessageTopic(kind: event.kind))) else { return }   // alarms always
        guard Date.now.timeIntervalSince(event.time) < Self.freshness, posted.insert(event.id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title(for: event, name: creatureName)
        content.body = text
        content.categoryIdentifier = Self.category
        content.threadIdentifier = event.unit
        content.userInfo = ["unit": event.unit]
        if urgent {
            content.interruptionLevel = .timeSensitive
            content.sound = .default
        } else if isFocused || isQuiet() {
            content.interruptionLevel = .passive
            content.sound = nil
        } else {
            content.sound = playsSound ? .default : nil
        }
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func title(for event: RoomEvent, name: String) -> String {
        switch event.kind {
        case "say": "\(name) says"
        case "greet": "\(name) is happy to see you"
        case "morning": "Good morning from \(name)"
        case "break": "\(name) thinks you need a break"
        case "posture": "\(name) noticed your posture"
        case "tired": "\(name) thinks you look tired"
        case "checkin": "\(name) is checking on you"
        case "alarm": "⚠️ \(name): alarm"
        case "warm": "\(name) feels warm"
        case "goodnight": "\(name) is going to sleep"
        default: name
        }
    }

    fileprivate func sendReply(_ text: String, unit: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client?.send(.reply(trimmed, unit: unit))
    }

    fileprivate func openConversation(_ unit: String) {
        onOpenConversation?(unit)
    }
}

extension CreatureNotifier: UNUserNotificationCenterDelegate {
    /// Show it even while the app is open (the notification is the creature's voice), except the
    /// passive ones (Focus, quiet hours), which only go to the list.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if content.interruptionLevel == .passive { return [.list] }
        return content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let unit = response.notification.request.content.userInfo["unit"] as? String ?? "phone"
        switch response.actionIdentifier {
        case Self.replyAction:
            guard let input = response as? UNTextInputNotificationResponse else { return }
            let text = input.userText
            await MainActor.run { self.sendReply(text, unit: unit) }
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run { self.openConversation(unit) }
        default:
            break
        }
    }
}
