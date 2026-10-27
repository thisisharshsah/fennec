import Foundation

struct RoomEvent: Identifiable, Hashable, Sendable {
    let id: String
    let unit: String
    let time: Date
    let name: String
    let distanceMm: Double?
    let text: String?

    init(_ message: EventMessage, receivedAt now: Date = .now) {
        unit = message.unit ?? "unknown"
        time = message.ts.map { Date(timeIntervalSince1970: $0) } ?? now
        name = message.name
        distanceMm = message.mm
        text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ts = message.ts {
            id = "\(unit)|\(ts)|\(message.name)"
        } else {
            id = UUID().uuidString
        }
    }

    var title: String {
        name.split(separator: "_").joined(separator: " ").capitalizedFirst
    }

    var symbolName: String {
        switch name {
        case "clap": "hands.clap"
        case "knock": "hand.tap"
        case "moved": "move.3d"
        case "someone_in_front": "person.fill"
        case "someone_left": "person.fill.xmark"
        case "sound_started": "speaker.wave.2.fill"
        case "sound_stopped": "speaker.slash.fill"
        case "boot": "power"
        case "speech": "mic.fill"
        case "spoke": "speaker.wave.3.fill"
        case "wifi_connected": "wifi"
        case "wifi_disconnected": "wifi.slash"
        default: "bolt.fill"
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
