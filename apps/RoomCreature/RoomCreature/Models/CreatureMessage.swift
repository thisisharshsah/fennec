import Foundation

/// What a message is about, for the conversation filter and the per-kind notification switches.
enum MessageTopic: String, CaseIterable, Identifiable, Sendable {
    case said, greetings, breaks, wellbeing, room, night, safety

    /// Topics the owner can switch off; safety alarms always come through.
    static var switchable: [MessageTopic] { allCases.filter { $0 != .safety } }

    var id: String { rawValue }

    /// Notice kinds from the hub: say, greet, morning, break, posture, tired, warm, goodnight. Unknown kinds count as said.
    init(kind: String?) {
        switch kind {
        case "greet", "morning": self = .greetings
        case "break": self = .breaks
        case "posture", "tired": self = .wellbeing
        case "checkin", "alarm": self = .safety
        case "warm": self = .room
        case "goodnight": self = .night
        default: self = .said
        }
    }

    /// Short name for the filter menu.
    var filterTitle: String {
        switch self {
        case .said: "Said"
        case .greetings: "Greetings"
        case .breaks: "Breaks"
        case .wellbeing: "Posture"
        case .room: "Room"
        case .night: "Night"
        case .safety: "Safety"
        }
    }

    /// Name of the switch in Settings.
    var settingTitle: String {
        switch self {
        case .said: "Things it says"
        case .greetings: "Greetings and good morning"
        case .breaks: "Break reminders"
        case .wellbeing: "Posture and tiredness"
        case .room: "Room alerts"
        case .night: "Goodnight"
        case .safety: "Safety alarms"
        }
    }

    var systemImage: String {
        switch self {
        case .said: "bubble.left"
        case .greetings: "hand.wave"
        case .breaks: "cup.and.saucer"
        case .wellbeing: "figure.stand"
        case .room: "thermometer.sun"
        case .night: "moon.zzz"
        case .safety: "exclamationmark.shield"
        }
    }
}

/// One line of a creature's conversation: something it said (a notice) or the owner's reply.
struct CreatureMessage: Identifiable, Hashable, Sendable {
    enum Sender: String, Sendable { case creature, owner }
    enum Delivery: Sendable { case delivered, sending, failed }

    /// The hub's id, `unit|ts|notice` or `unit|ts|reply`; `local|uuid` while a reply is on its way.
    let id: String
    let unit: String
    let time: Date
    let sender: Sender
    let kind: String
    let text: String
    var delivery: Delivery = .delivered

    var isFromCreature: Bool { sender == .creature }
    var topic: MessageTopic { MessageTopic(kind: kind) }

    /// The small icon beside the creature's bubble.
    var symbolName: String {
        switch kind {
        case "greet": "hand.wave"
        case "morning": "sun.max"
        case "break": "cup.and.saucer"
        case "posture": "figure.stand"
        case "tired": "zzz"
        case "checkin": "questionmark.bubble"
        case "alarm": "exclamationmark.triangle"
        case "warm": "thermometer.sun"
        case "goodnight": "moon.zzz"
        default: "bubble.left"
        }
    }

    init(id: String, unit: String, time: Date, sender: Sender, kind: String, text: String, delivery: Delivery = .delivered) {
        self.id = id
        self.unit = unit
        self.time = time
        self.sender = sender
        self.kind = kind
        self.text = text
        self.delivery = delivery
    }

    /// From the hub's `messages` answer.
    init?(_ item: MessageItem) {
        guard let unit = item.unit, let text = item.text, !text.isEmpty else { return nil }
        let sender: Sender = item.from == "owner" ? .owner : .creature
        self.init(
            id: item.id,
            unit: unit,
            time: Date(timeIntervalSince1970: item.ts),
            sender: sender,
            kind: item.kind ?? (sender == .owner ? "reply" : "say"),
            text: text
        )
    }

    /// From a live event: a notice, or speech that came in as a reply to a notification.
    /// The id is built the way the hub builds it so the history answer dedupes against it.
    init?(_ event: EventMessage) {
        guard let unit = event.unit, let ts = event.ts,
              let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if event.name == "notice" {
            self.init(id: "\(unit)|\(ts)|notice", unit: unit, time: Date(timeIntervalSince1970: ts),
                      sender: .creature, kind: event.kind ?? "say", text: text)
        } else if event.name == "speech", event.via == "notification" || event.via == "gesture" {
            self.init(id: "\(unit)|\(ts)|reply", unit: unit, time: Date(timeIntervalSince1970: ts),
                      sender: .owner, kind: "reply", text: text)
        } else {
            return nil
        }
    }
}
