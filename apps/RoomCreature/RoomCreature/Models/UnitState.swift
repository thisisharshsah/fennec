import Foundation

struct UnitState: Identifiable, Sendable {
    let id: String
    var isConnected = false
    var link: String?
    var samples: [StateSample] = []
    var body: BodyState?
    var wifi: WifiStatus?
    var firmware: String?
    var sensors: [String] = []
    var health: HealthMessage?
    /// When the bridge last heard from this unit (a state, body, hello or event).
    var lastSeen: Date?

    var hasMicrophone: Bool { sensors.contains("mac-microphone") }

    /// A creature has the body's motion sensor; hub-side helpers (mac-mic, ear, mac-voice) do not.
    var isCreature: Bool { sensors.contains("lsm6dsl") }

    var mood: Mood { Mood(rawValue: body?.mood ?? "") ?? .neutral }

    var signalDBm: Int? { latest?.rssi ?? wifi?.rssi }

    var latest: StateSample? { samples.last }

    mutating func append(_ sample: StateSample, window: TimeInterval) {
        if let last = samples.last, sample.time < last.time { return }
        samples.append(sample)
        let cutoff = sample.time.addingTimeInterval(-window)
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }
}
