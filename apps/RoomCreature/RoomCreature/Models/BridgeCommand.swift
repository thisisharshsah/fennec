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
    var dailyCapUsd: Double?
    var days: Int?
    var kind: String?
    var revoke: String?
    var mode: String?
    var describe: Int?
    var away: Int?
    var checkin: Int?

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

    /// The creature's answering brain: ask for its status, or change it.
    static func brain(on: Bool? = nil, dailyCapUsd: Double? = nil) -> BridgeCommand {
        BridgeCommand(cmd: "brain", unit: "", on: on.map { $0 ? 1 : 0 }, dailyCapUsd: dailyCapUsd)
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

    /// Asks the hub for a device token (only accepted while its pairing window is open).
    static func pair(deviceName: String) -> BridgeCommand {
        BridgeCommand(cmd: "pair", unit: "", name: deviceName, kind: "app")
    }

    /// Opens the hub's pairing window for 60 s so another device can pair (trusted clients only).
    static func pairOpen() -> BridgeCommand {
        BridgeCommand(cmd: "pair_open", unit: "")
    }

    /// Lists the paired devices, revoking one first when an id is given.
    static func devices(revoke: String? = nil) -> BridgeCommand {
        BridgeCommand(cmd: "devices", unit: "", revoke: revoke)
    }

    /// When the camera eye runs: off, auto (while someone is at the desk) or on.
    static func eye(mode: EyeStatus.Mode) -> BridgeCommand {
        BridgeCommand(cmd: "eye", unit: "", mode: mode.rawValue)
    }

    /// Turns the local model that describes the scene on or off (it runs only while the eye does).
    static func eyeDescribes(_ on: Bool) -> BridgeCommand {
        BridgeCommand(cmd: "eye", unit: "", describe: on ? 1 : 0)
    }

    /// The safety watch: away mode, and checking on the owner when they are slumped and still.
    static func safety(away: Bool? = nil, checkin: Bool? = nil) -> BridgeCommand {
        BridgeCommand(cmd: "safety", unit: "", away: away.map { $0 ? 1 : 0 }, checkin: checkin.map { $0 ? 1 : 0 })
    }

    /// Starts or stops the eye's live picture for this app.
    static func picture(_ on: Bool) -> BridgeCommand {
        BridgeCommand(cmd: "picture", unit: "", on: on ? 1 : 0)
    }

    static func speak(_ text: String, unit: String, voice: String? = nil) -> BridgeCommand {
        BridgeCommand(cmd: "speak", unit: unit, text: text, voice: voice)
    }
}
