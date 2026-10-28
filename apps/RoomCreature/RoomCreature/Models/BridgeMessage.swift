import Foundation

enum BridgeMessage: Sendable {
    case hello(HelloMessage)
    case history([EventMessage])
    case state(StateMessage)
    case event(EventMessage)
    case unitStatus(UnitStatusMessage)
    case body(BodyMessage)
    case unitHello(HelloMessage)
    case status(StatusMessage)
    case series(SeriesMessage)
    case life(Bool)
    /// The conversation from the hub's log (notices and the owner's replies), oldest first.
    case messages([MessageItem])
    case brain(BrainStatus)
    /// On a network connection without a valid token: only pairing is possible.
    case authRequired(AuthRequiredMessage)
    case paired(PairedMessage)
    case pairRefused(reason: String)
    /// A trusted client opened the pairing window; it closes at this Unix time.
    case pairing(openUntil: Double)
    case devices([PairedDevice])
    /// The eye's live outline of what it sees (not logged by the hub).
    case vision(VisionMessage)
    /// The eye's live picture, while this app asked for it.
    case picture(PictureMessage)
    /// When the eye runs, and whether the camera is in use.
    case eye(EyeStatus)
    /// The safety watch's settings and state.
    case safety(SafetyStatus)
}

struct BridgeMessageError: Error {
    let type: String
}

extension BridgeMessage {
    private struct Envelope: Decodable {
        let type: String
    }

    private struct HistoryPayload: Decodable {
        let events: [EventMessage]
    }

    private struct MessagesPayload: Decodable {
        let items: [MessageItem]
    }

    private struct PairRefusedPayload: Decodable {
        let reason: String?
    }

    private struct PairingPayload: Decodable {
        let openUntil: Double?
        enum CodingKeys: String, CodingKey { case openUntil = "open_until" }
    }

    private struct DevicesPayload: Decodable {
        let items: [PairedDevice]?
    }

    static func decode(_ data: Data) throws -> BridgeMessage {
        let decoder = JSONDecoder()
        let type = try decoder.decode(Envelope.self, from: data).type
        switch type {
        case "hello":
            let hello = try decoder.decode(HelloMessage.self, from: data)
            return hello.isFromUnit ? .unitHello(hello) : .hello(hello)
        case "status": return .status(try decoder.decode(StatusMessage.self, from: data))
        case "history": return .history(try decoder.decode(HistoryPayload.self, from: data).events)
        case "state": return .state(try decoder.decode(StateMessage.self, from: data))
        case "event": return .event(try decoder.decode(EventMessage.self, from: data))
        case "unit_status": return .unitStatus(try decoder.decode(UnitStatusMessage.self, from: data))
        case "body": return .body(try decoder.decode(BodyMessage.self, from: data))
        case "series": return .series(try decoder.decode(SeriesMessage.self, from: data))
        case "brain": return .brain(try decoder.decode(BrainStatus.self, from: data))
        case "life": return .life(try decoder.decode(LifeMessage.self, from: data).enabled ?? false)
        case "messages": return .messages(try decoder.decode(MessagesPayload.self, from: data).items)
        case "auth_required": return .authRequired(try decoder.decode(AuthRequiredMessage.self, from: data))
        case "paired": return .paired(try decoder.decode(PairedMessage.self, from: data))
        case "pair_refused": return .pairRefused(reason: try decoder.decode(PairRefusedPayload.self, from: data).reason ?? "")
        case "pairing": return .pairing(openUntil: try decoder.decode(PairingPayload.self, from: data).openUntil ?? 0)
        case "devices": return .devices(try decoder.decode(DevicesPayload.self, from: data).items ?? [])
        case "vision": return .vision(try decoder.decode(VisionMessage.self, from: data))
        case "picture": return .picture(try decoder.decode(PictureMessage.self, from: data))
        case "eye": return .eye(try decoder.decode(EyeStatus.self, from: data))
        case "safety": return .safety(try decoder.decode(SafetyStatus.self, from: data))
        default: throw BridgeMessageError(type: type)
        }
    }
}

struct HelloMessage: Decodable, Sendable {
    var bridge: String?
    var lanIP: String?
    var unitPort: Int?
    var units: [UnitSummary]?
    /// Whether the hub's daily-life rules are on.
    var life: Bool?
    /// When the camera eye runs (hub 0.5+).
    var eye: EyeStatus?
    /// The safety watch (hub 0.5+).
    var safety: SafetyStatus?
    var unit: String?
    var fw: String?
    var sensors: [String]?
    var wifi: WifiInfoMessage?
    var link: String?
    var ts: Double?

    enum CodingKeys: String, CodingKey {
        case bridge, units, unit, fw, sensors, wifi, link, ts, life, eye, safety
        case lanIP = "lan_ip"
        case unitPort = "unit_port"
    }

    var isFromUnit: Bool { units == nil && unit != nil }
}

struct WifiInfoMessage: Decodable, Sendable {
    var module: String?
    var ssid: String?
    var joined: Bool?
    var ip: String?
    var bridge: Bool?
}

struct StatusMessage: Decodable, Sendable {
    var unit: String?
    var link: String?
    var ts: Double?
    var ssid: String?
    var joined: Bool?
    var ip: String?
    var rssi: Double?
    var bridgeHost: String?
    var bridgePort: Int?
    var bridge: Bool?

    enum CodingKeys: String, CodingKey {
        case unit, link, ts, ssid, joined, ip, rssi, bridge
        case bridgeHost = "bridge_host"
        case bridgePort = "bridge_port"
    }
}

struct UnitSummary: Decodable, Sendable {
    var unit: String
    var connected: Bool?
    var sensors: [String]?
    var link: String?
    var lastState: StateMessage?
    /// The unit's own last hello, as the hub stored it (firmware, Wi-Fi network).
    var hello: HelloMessage?

    enum CodingKeys: String, CodingKey {
        case unit, connected, sensors, link, hello
        case lastState = "last_state"
    }
}

struct StateMessage: Decodable, Sendable {
    var unit: String?
    var link: String?
    var ts: Double?
    var tempC: Double?
    var humPct: Double?
    var pressHpa: Double?
    var tofMm: Double?
    var headingDeg: Double?
    var motion: Int?
    var soundDb: Double?
    var soundDir: Double?
    var rssi: Double?
    var body: BodyMessage?
    var health: HealthMessage?

    enum CodingKeys: String, CodingKey {
        case unit, link, ts, motion, body, rssi, health
        case tempC = "temp_c"
        case humPct = "hum_pct"
        case pressHpa = "press_hpa"
        case tofMm = "tof_mm"
        case headingDeg = "heading_deg"
        case soundDb = "sound_db"
        case soundDir = "sound_dir"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        ts = try c.decodeIfPresent(Double.self, forKey: .ts)
        body = try c.decodeIfPresent(BodyMessage.self, forKey: .body)
        rssi = try c.decodeIfPresent(Double.self, forKey: .rssi)
        health = try? c.decodeIfPresent(HealthMessage.self, forKey: .health)   // firmware 0.5+; never fails the state
        tempC = try c.decodeIfPresent(Double.self, forKey: .tempC)
        humPct = try c.decodeIfPresent(Double.self, forKey: .humPct)
        pressHpa = try c.decodeIfPresent(Double.self, forKey: .pressHpa)
        tofMm = try c.decodeIfPresent(Double.self, forKey: .tofMm)
        headingDeg = try c.decodeIfPresent(Double.self, forKey: .headingDeg)
        soundDb = try c.decodeIfPresent(Double.self, forKey: .soundDb)
        soundDir = try c.decodeIfPresent(Double.self, forKey: .soundDir)
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .motion) {
            motion = flag ? 1 : 0
        } else {
            motion = try c.decodeIfPresent(Int.self, forKey: .motion)
        }
    }
}

struct EventMessage: Decodable, Sendable {
    var unit: String?
    var link: String?
    var ts: Double?
    var t: Int?
    var name: String
    var mm: Double?
    var text: String?
    /// For hub notices: greet, morning, break, warm, goodnight.
    var kind: String?
    /// "notification" on speech that is the owner's reply to a notification.
    var via: String?
    var durationS: Double?

    enum CodingKeys: String, CodingKey {
        case unit, link, ts, t, name, mm, text, kind, via
        case durationS = "duration_s"
    }
}

struct UnitStatusMessage: Decodable, Sendable {
    var unit: String
    var link: String?
    var connected: Bool
    var ts: Double?
}

/// The `health` block of a state line (firmware 0.5+). Every field is optional so older or partial
/// blocks still decode.
struct HealthMessage: Decodable, Equatable, Sendable {
    var uptimeS: Double?
    var boots: Int?
    var wdResets: Int?
    var reset: String?
    var freeRam: Int?
    var wifiReconnects: Int?
    var journal: Int?

    enum CodingKeys: String, CodingKey {
        case boots, reset, journal
        case uptimeS = "uptime_s"
        case wdResets = "wd_resets"
        case freeRam = "free_ram"
        case wifiReconnects = "wifi_reconnects"
    }
}


/// A field's history from the hub's log: [[unix_ts, value], ...], downsampled to a few hundred points.
struct SeriesMessage: Decodable, Sendable {
    var unit: String?
    var field: String?
    var request: String?
    var points: [[Double]]?
    var error: String?
}

struct LifeMessage: Decodable, Sendable {
    var enabled: Bool?
}

/// One line of the conversation as the hub keeps it: `from` is "creature" or "owner".
struct MessageItem: Decodable, Sendable {
    var id: String
    var unit: String?
    var ts: Double
    var from: String?
    var kind: String?
    var text: String?
}

/// The hub's answering brain: whether it can reply, and what it spent today.
struct BrainStatus: Decodable, Sendable, Equatable {
    var enabled: Bool?
    var hasKey: Bool?
    var dailyCapUsd: Double?
    var spentTodayUsd: Double?
    var model: String?
    /// "farhelm" (the owner's model hub), "own" (Crawl's own copy on the hub) or "anthropic".
    var provider: String?
    var local: Bool?
    /// What answers when the first model cannot, in order, if anything.
    var fallback: String?

    enum CodingKeys: String, CodingKey {
        case enabled, model, provider, local, fallback
        case hasKey = "has_key"
        case dailyCapUsd = "daily_cap_usd"
        case spentTodayUsd = "spent_today_usd"
    }
}

/// Sent by the hub to a network client that has no valid token.
struct AuthRequiredMessage: Decodable, Sendable {
    var pairingOpen: Bool?
    /// SHA-256 of the hub certificate's DER, hex (only on the first auth_required of a connection).
    var fingerprint: String?

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case pairingOpen = "pairing_open"
    }
}

/// The hub accepted this device: the token to present from now on. Secret, never log it.
struct PairedMessage: Decodable, Sendable {
    var deviceID: String
    var token: String
    var fingerprint: String?

    enum CodingKeys: String, CodingKey {
        case token, fingerprint
        case deviceID = "device_id"
    }
}

/// A device the hub has issued a token to.
struct PairedDevice: Decodable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String?
    var kind: String?
    var created: Double?
    var lastSeen: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, created
        case lastSeen = "last_seen"
    }
}
