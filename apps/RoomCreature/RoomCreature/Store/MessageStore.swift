import Foundation
import Observation

/// The conversation with every creature: the hub's history merged with live notices and replies.
/// Read state and deletions belong to this device and are kept in UserDefaults.
@MainActor @Observable
final class MessageStore {
    static let historyDays = 14
    private static let hiddenLimit = 2000
    private static let sendTimeout: Duration = .seconds(8)

    private enum Key {
        static let lastRead = "messages.lastRead"
        static let hidden = "messages.hidden"
    }

    /// Every visible message, oldest first.
    private(set) var items: [CreatureMessage] = []
    /// Per creature: messages at or before this time count as read.
    private(set) var lastRead: [String: Date]
    @ObservationIgnored private var hidden: [String]
    @ObservationIgnored private var hiddenSet: Set<String>
    /// Called with the total unread count whenever it may have changed (the app icon badge).
    @ObservationIgnored var onUnreadChange: ((Int) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Key.lastRead) as? [String: Double] ?? [:]
        lastRead = stored.mapValues { Date(timeIntervalSince1970: $0) }
        hidden = defaults.stringArray(forKey: Key.hidden) ?? []
        hiddenSet = Set(hidden)
    }

    // MARK: Reading

    func messages(for unit: String) -> [CreatureMessage] {
        items.filter { $0.unit == unit }
    }

    func lastMessage(for unit: String) -> CreatureMessage? {
        items.last { $0.unit == unit && !$0.isThought }
    }

    /// Creatures with at least one message, most recent conversation first.
    var unitsByRecency: [String] {
        var seen = Set<String>()
        return items.reversed().compactMap { seen.insert($0.unit).inserted ? $0.unit : nil }
    }

    func unreadCount(for unit: String) -> Int {
        let since = lastRead[unit] ?? .distantPast
        return items.reduce(0) { $0 + ($1.unit == unit && $1.isFromCreature && !$1.isThought && $1.time > since ? 1 : 0) }
    }

    var totalUnread: Int {
        items.reduce(0) { count, item in
            count + (item.isFromCreature && !item.isThought && item.time > (lastRead[item.unit] ?? .distantPast) ? 1 : 0)
        }
    }

    // MARK: Incoming

    func ingest(_ incoming: [CreatureMessage]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for message in incoming where !hiddenSet.contains(message.id) {
            if message.sender == .owner,
               let local = byID.values.first(where: { $0.delivery != .delivered && $0.unit == message.unit && $0.text == message.text }) {
                byID[local.id] = nil            // the hub's echo of a reply shown optimistically
            }
            byID[message.id] = message
        }
        items = byID.values.sorted { $0.time < $1.time }
        reportUnread()
    }

    // MARK: Actions

    /// Shows a reply at once; the hub's echo replaces it. Marked failed if no echo arrives in time.
    func addPendingReply(_ text: String, unit: String) {
        let message = CreatureMessage(
            id: "local|\(UUID().uuidString)", unit: unit, time: .now,
            sender: .owner, kind: "reply", text: text, delivery: .sending
        )
        items.append(message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.sendTimeout)
            guard let self, let index = self.items.firstIndex(where: { $0.id == message.id }) else { return }
            self.items[index].delivery = .failed
        }
    }

    func markRead(_ unit: String) {
        guard unreadCount(for: unit) > 0 else { return }
        let latest = items.last { $0.unit == unit && $0.isFromCreature }?.time ?? .now
        lastRead[unit] = max(latest, lastRead[unit] ?? .distantPast)
        saveLastRead()
        reportUnread()
    }

    func markAllRead() {
        for unit in Set(items.map(\.unit)) { markRead(unit) }
    }

    /// Hides a message on this device only; the hub keeps it.
    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        guard !id.hasPrefix("local|"), hiddenSet.insert(id).inserted else {
            reportUnread()
            return
        }
        hidden.append(id)
        if hidden.count > Self.hiddenLimit {
            let dropped = hidden.prefix(hidden.count - Self.hiddenLimit)
            hiddenSet.subtract(dropped)
            hidden.removeFirst(dropped.count)
        }
        defaults.set(hidden, forKey: Key.hidden)
        reportUnread()
    }

    private func saveLastRead() {
        defaults.set(lastRead.mapValues(\.timeIntervalSince1970), forKey: Key.lastRead)
    }

    private func reportUnread() {
        onUnreadChange?(totalUnread)
    }
}
