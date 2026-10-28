import Foundation
import Observation

@MainActor @Observable
final class RoomStore {
    static let sampleWindow: TimeInterval = 10 * 60
    static let eventLimit = 500

    private(set) var unitsByID: [String: UnitState] = [:]
    private(set) var events: [RoomEvent] = []
    private(set) var bridgeVersion: String?
    /// The hub's daily-life rules (greetings, break reminders, goodnight); nil until the hub says.
    private(set) var lifeEnabled: Bool?
    /// The hub's answering brain (who replies when the owner writes), nil until the hub says.
    private(set) var brain: BrainStatus?
    /// Called with each live event as it arrives (the notifier listens).
    @ObservationIgnored var onEvent: ((RoomEvent) -> Void)?
    private(set) var bridgeLanIP: String?
    private(set) var bridgeUnitPort: Int?
    private(set) var wifiRequests: [String: Date] = [:]
    /// History answers from the hub, keyed by the request id the view chose.
    private(set) var series: [String: [(time: Date, value: Double)]] = [:]
    /// The latest outline from each creature's eye, keyed by the creature.
    private(set) var vision: [String: VisionFrame] = [:]
    /// The latest live picture from each creature's eye, while one is asked for. Memory only.
    private(set) var pictures: [String: LivePicture] = [:]
    /// When the camera eye runs; nil from a hub without one.
    private(set) var eye: EyeStatus?
    /// The safety watch; nil from a hub without one.
    private(set) var safety: SafetyStatus?
    /// Creatures known to this app, persisted across launches.
    let registry = CreatureRegistry()
    /// What the creatures said and the owner's replies.
    let messages = MessageStore()

    var units: [UnitState] {
        unitsByID.values.sorted { $0.id < $1.id }
    }

    func apply(_ message: BridgeMessage) {
        switch message {
        case .series(let reply):
            if let key = reply.request {
                series[key] = (reply.points ?? []).compactMap { pair in
                    pair.count == 2 ? (Date(timeIntervalSince1970: pair[0]), pair[1]) : nil
                }
            }
        case .messages(let items):
            messages.ingest(items.compactMap(CreatureMessage.init))
        case .life(let enabled):
            lifeEnabled = enabled
        case .vision(let outline):
            if let id = outline.forUnit {
                vision[registry.currentID(for: id)] = VisionFrame(outline)
            }
        case .eye(let status):
            eye = status
        case .safety(let status):
            safety = status
        case .picture(let picture):
            if let id = picture.forUnit, let base64 = picture.jpeg, let jpeg = Data(base64Encoded: base64) {
                pictures[registry.currentID(for: id)] = LivePicture(jpeg: jpeg, receivedAt: .now)
            }
        case .brain(let status):
            brain = status
        case .authRequired, .paired, .pairRefused, .pairing, .devices:
            break                                   // the connection's business: BridgeClient handles them
        case .hello(let hello):
            bridgeVersion = hello.bridge
            lifeEnabled = hello.life ?? lifeEnabled
            eye = hello.eye ?? eye
            safety = hello.safety ?? safety
            bridgeLanIP = hello.lanIP
            bridgeUnitPort = hello.unitPort
            for summary in hello.units ?? [] {
                update(summary.unit) { unit in
                    unit.isConnected = summary.connected ?? true
                    unit.sensors = summary.sensors ?? summary.hello?.sensors ?? unit.sensors
                    unit.link = summary.link ?? unit.link
                    unit.firmware = summary.hello?.fw ?? unit.firmware
                    if let wifi = summary.hello?.wifi {
                        unit.wifi = WifiStatus(wifi, previous: unit.wifi, at: Self.time(summary.hello?.ts))
                    }
                    if let last = summary.lastState {
                        let sample = StateSample(last)
                        unit.append(sample, window: Self.sampleWindow)
                        unit.health = last.health ?? unit.health
                        unit.lastSeen = max(unit.lastSeen ?? .distantPast, sample.time)
                        if let body = last.body {
                            unit.body = BodyState(body, previous: unit.body)
                        }
                    }
                }
            }
        case .history(let history):
            merge(history.map { RoomEvent($0) })
            messages.ingest(history.compactMap(CreatureMessage.init))
        case .state(let state):
            update(state.unit ?? "unknown") { unit in
                unit.isConnected = true
                unit.link = state.link ?? unit.link
                let sample = StateSample(state)
                unit.append(sample, window: Self.sampleWindow)
                unit.lastSeen = sample.time
                unit.health = state.health ?? unit.health
                if let body = state.body {
                    unit.body = BodyState(body, previous: unit.body)
                }
            }
        case .event(let event):
            if let id = event.unit, id != "hub" {        // the hub's own events (device_paired) are not a unit
                update(id) { unit in
                    unit.link = event.link ?? unit.link
                    unit.lastSeen = Self.time(event.ts)
                }
            }
            let roomEvent = RoomEvent(event)
            merge([roomEvent])
            if let message = CreatureMessage(event) { messages.ingest([message]) }
            onEvent?(roomEvent)
        case .unitStatus(let status):
            update(status.unit, announced: status.connected) { unit in
                unit.isConnected = status.connected
                unit.link = status.link ?? unit.link
            }
        case .unitHello(let hello):
            let id = hello.unit ?? "unknown"
            update(id, isHello: true, announced: true) { unit in
                unit.isConnected = true
                unit.lastSeen = Self.time(hello.ts)
                unit.link = hello.link ?? unit.link
                unit.firmware = hello.fw ?? unit.firmware
                unit.sensors = hello.sensors ?? unit.sensors
                if let wifi = hello.wifi {
                    unit.wifi = WifiStatus(wifi, previous: unit.wifi, at: Self.time(hello.ts))
                }
            }
            wifiRequests[id] = nil
        case .status(let status):
            let id = status.unit ?? "unknown"
            update(id) { unit in
                unit.link = status.link ?? unit.link
                unit.wifi = WifiStatus(status, previous: unit.wifi, at: Self.time(status.ts))
            }
            wifiRequests[id] = nil
        case .body(let body):
            update(body.unit ?? "unknown") { unit in
                unit.link = body.link ?? unit.link
                unit.body = BodyState(body, previous: unit.body)
                unit.lastSeen = Self.time(body.ts)
            }
        }
    }

    /// The live state of a unit, or an empty offline one for a creature the hub has not reported yet.
    func unit(_ id: String) -> UnitState {
        unitsByID[id] ?? UnitState(id: id)
    }

    /// Units that are not creatures (the Mac's microphone, the ear, the voice helper).
    var otherDevices: [UnitState] {
        units.filter { !$0.isCreature && !registry.isKnown($0.id) }
    }

    var speechUnit: UnitState? {
        units.first(where: \.hasMicrophone) ?? unitsByID["mac-mic"]
    }

    func events(for unitID: String, since: Date) -> [RoomEvent] {
        events.filter { $0.unit == unitID && $0.time >= since }
    }

    func noteWifiRequest(for unitID: String) {
        wifiRequests[unitID] = .now
    }

    func dismissWifiRequest(for unitID: String) {
        wifiRequests[unitID] = nil
    }

    private static func time(_ ts: Double?) -> Date {
        ts.map { Date(timeIntervalSince1970: $0) } ?? .now
    }

    /// Forgets the live picture when the owner turns it off.
    func dropPicture(for unitID: String) {
        pictures[unitID] = nil
    }

    func clearHistory() {
        events.removeAll()
        for id in unitsByID.keys {
            unitsByID[id]?.samples.removeAll()
        }
    }

    private func update(_ id: String, isHello: Bool = false, announced: Bool = false, _ change: (inout UnitState) -> Void) {
        var unit = unitsByID[id] ?? UnitState(id: id)
        change(&unit)
        unitsByID[id] = unit
        if let oldID = registry.observe(unit, isHello: isHello, announced: announced) {
            unitsByID[oldID] = nil           // renamed: the old id is only a ghost on the hub now
        }
    }

    private func merge(_ incoming: [RoomEvent]) {
        let known = Set(events.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        events = (events + fresh)
            .sorted { $0.time > $1.time }
            .prefix(Self.eventLimit)
            .map { $0 }
    }
}
