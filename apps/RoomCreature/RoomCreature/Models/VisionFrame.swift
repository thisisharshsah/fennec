import CoreGraphics
import Foundation

/// The eye's live outline of what it sees, five times a second. Shapes and facts only: the
/// camera's pictures never leave the computer the eye runs on.
struct VisionMessage: Decodable, Sendable {
    var unit: String?
    /// The creature this eye stands in for.
    var forUnit: String?
    var people: Int?
    var looking: Bool?
    var present: Bool?
    /// [x, y, w, h], 0..1 of the picture, origin bottom left (as Vision reports them).
    var bodies: [[Double]]?
    /// [x, y, w, h, looking (1 or 0)].
    var faces: [[Double]]?
    var aspect: Double?
    /// Where the head points: -1 left .. +1 right of the picture.
    var aim: Double?
    /// The head turn in degrees, negative to the creature's left.
    var pan: Int?
    /// Unix time the person arrived.
    var since: Double?
    var ts: Double?

    enum CodingKeys: String, CodingKey {
        case unit, people, looking, present, bodies, faces, aspect, aim, pan, since, ts
        case forUnit = "for"
    }
}

/// One live picture from the eye, sent only to apps that asked for it and never kept by the hub.
struct PictureMessage: Decodable, Sendable {
    var forUnit: String?
    var jpeg: String?
    var ts: Double?

    enum CodingKeys: String, CodingKey {
        case jpeg, ts
        case forUnit = "for"
    }
}

struct LivePicture: Sendable {
    let jpeg: Data
    let receivedAt: Date
}

struct VisionFrame: Sendable {
    struct Face: Sendable {
        let rect: CGRect
        let looking: Bool
    }

    let people: Int
    let isLooking: Bool
    let isPresent: Bool
    let bodies: [CGRect]
    let faces: [Face]
    let aspect: Double
    let aim: Double?
    let pan: Int?
    let arrivedAt: Date?
    let receivedAt: Date

    init(_ message: VisionMessage, receivedAt now: Date = .now) {
        people = message.people ?? 0
        isLooking = message.looking ?? false
        isPresent = message.present ?? false
        bodies = (message.bodies ?? []).compactMap(Self.rect)
        faces = (message.faces ?? []).compactMap { values in
            Self.rect(values).map { Face(rect: $0, looking: values.count > 4 && values[4] > 0) }
        }
        aspect = message.aspect ?? 16.0 / 9.0
        aim = message.aim
        pan = message.pan
        arrivedAt = message.since.map { Date(timeIntervalSince1970: $0) }
        receivedAt = now
    }

    /// A frame older than this means the eye stopped sending.
    static let staleAfter: TimeInterval = 3

    func isStale(at now: Date) -> Bool { now.timeIntervalSince(receivedAt) > Self.staleAfter }

    private static func rect(_ v: [Double]) -> CGRect? {
        v.count >= 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
    }
}
