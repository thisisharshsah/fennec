import Foundation

struct StateSample: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let temperature: Double?
    let humidity: Double?
    let pressure: Double?
    let distanceMm: Double?
    let heading: Double?
    let isMoving: Bool
    let soundLevel: Double?
    let soundDirection: Double?
    let rssi: Int?

    init(_ message: StateMessage, receivedAt now: Date = .now) {
        time = message.ts.map { Date(timeIntervalSince1970: $0) } ?? now
        temperature = message.tempC
        humidity = message.humPct
        pressure = message.pressHpa
        distanceMm = Self.validOrNil(message.tofMm)
        heading = Self.validOrNil(message.headingDeg)
        isMoving = (message.motion ?? 0) != 0
        soundLevel = message.soundDb
        soundDirection = message.soundDir
        rssi = message.rssi.map { Int($0.rounded()) }
    }

    private static func validOrNil(_ value: Double?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}
