import Foundation

struct BridgeCommand: Encodable, Sendable {
    let cmd: String
    let unit: String
    var mood: String?
    var name: String?
    var pan: Double?
    var tilt: Double?
    var color: String?
    var ssid: String?
    var pass: String?
    var host: String?
    var port: Int?
    var text: String?
    var voice: String?
    var field: String?
    var seconds: Double?
    var request: String?
    var on: Int?
    var days: Int?

    static func express(_ mood: Mood, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "express", unit: unit, mood: mood.rawValue)
    }

    static func gesture(_ gesture: Gesture, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "gesture", unit: unit, name: gesture.rawValue)
    }

    static func lookAt(pan: Double, tilt: Double, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "look_at", unit: unit, pan: pan.rounded(), tilt: tilt.rounded())
    }

    static func wifi(ssid: String, password: String, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "wifi", unit: unit, ssid: ssid, pass: password)
    }

    static func bridge(host: String, port: Int, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "bridge", unit: unit, host: host, port: port)
    }

    static func status(unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "status", unit: unit)
    }

    static func rename(_ name: String, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "name", unit: unit, name: name)
    }

    static func chirp(_ name: String, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "chirp", unit: unit, name: name)
    }

    static func restart(unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "restart", unit: unit)
    }

    static func forgetWifi(unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "forget_wifi", unit: unit)
    }

    /// The owner's answer to something the creature said; the hub turns it into a speech event.
    static func reply(_ text: String, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "reply", unit: unit, text: text)
    }

    /// Makes the creature "say" something (a notification on the phone until it has a speaker).
    static func say(_ text: String, unit: String) -> BridgeCommand {
        BridgeCommand(cmd: "say", unit: unit, text: text)
    }

    /// Turns the hub's daily-life rules on or off (answered by the hub, not a unit).
    static func life(_ enabled: Bool) -> BridgeCommand {
        BridgeCommand(cmd: "life", unit: "", on: enabled ? 1 : 0)
    }

    /// Asks the hub for the conversation of the last `days` days (all creatures).
    static func messages(days: Int) -> BridgeCommand {
        BridgeCommand(cmd: "messages", unit: "", days: days)
    }

    /// Asks the hub (not the unit) for one field's history from its log.
    static func series(field: String, seconds: Double, unit: String, request: String) -> BridgeCommand {
        BridgeCommand(cmd: "series", unit: unit, field: field, seconds: seconds, request: request)
    }

    static func speak(_ text: String, unit: String, voice: String? = nil) -> BridgeCommand {
        BridgeCommand(cmd: "speak", unit: unit, text: text, voice: voice)
    }
}
