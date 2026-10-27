import Foundation

struct BodyState: Equatable, Sendable {
    var earLeft: Double = 0
    var earRight: Double = 0
    var pan: Double = 0
    var tilt: Double = 0
    var tail: Double = 0
    var cheekHex: String = "#6ea8ff"
    var mood: String = "neutral"
    var gesture: String = ""
    var hasServos = false
    var why: String?
    var updatedAt: Date = .now

    init() {}

    init(_ message: BodyMessage, previous: BodyState?, receivedAt now: Date = .now) {
        earLeft = message.earL ?? previous?.earLeft ?? 0
        earRight = message.earR ?? previous?.earRight ?? 0
        pan = message.pan ?? previous?.pan ?? 0
        tilt = message.tilt ?? previous?.tilt ?? 0
        tail = message.tail ?? previous?.tail ?? 0
        cheekHex = message.cheek ?? previous?.cheekHex ?? "#6ea8ff"
        mood = message.mood ?? previous?.mood ?? "neutral"
        gesture = message.gesture ?? previous?.gesture ?? ""
        hasServos = message.servos ?? previous?.hasServos ?? false
        why = message.why ?? previous?.why
        updatedAt = message.ts.map { Date(timeIntervalSince1970: $0) } ?? now
    }
}

struct BodyMessage: Decodable, Sendable {
    var unit: String?
    var link: String?
    var ts: Double?
    var earL: Double?
    var earR: Double?
    var pan: Double?
    var tilt: Double?
    var tail: Double?
    var cheek: String?
    var mood: String?
    var gesture: String?
    var servos: Bool?
    var why: String?

    enum CodingKeys: String, CodingKey {
        case unit, link, ts, pan, tilt, tail, cheek, mood, gesture, servos, why
        case earL = "ear_l"
        case earR = "ear_r"
    }
}

enum Mood: String, CaseIterable, Identifiable {
    case neutral, listening, alert, curious, pleased, surprised, sleepy

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum Gesture: String, CaseIterable, Identifiable {
    case wag, nod, shake, perk, droop

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .wag: "wind"
        case .nod: "arrow.up.and.down"
        case .shake: "arrow.left.and.right"
        case .perk: "arrow.up.to.line"
        case .droop: "arrow.down.to.line"
        }
    }
}
