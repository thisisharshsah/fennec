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
    /// Hands, [x, y, w, h].
    var hands: [[Double]]?
    /// A sign read in the last 2 s: waved, thumbs_up, open_palm, nodded, shook_head, stretched, yawned...
    var sign: String?
    /// upright, slouching or close (leaning in to the screen), against the owner's own baseline.
    var posture: String?
    /// Yawns or heavy eyes lately.
    var tired: Bool?
    /// What is in the owner's hands (phone, drink, food, book, headphones) and pets in view.
    var things: [String]?
    var aspect: Double?
    /// Where the head points: -1 left .. +1 right of the picture.
    var aim: Double?
    /// The head turn in degrees, negative to the creature's left.
    var pan: Int?
    /// Unix time the person arrived.
    var since: Double?
    var ts: Double?

    enum CodingKeys: String, CodingKey {
        case unit, people, looking, present, bodies, faces, hands, sign, posture, tired, things, aspect, aim, pan, since, ts
        case forUnit = "for"
    }
}

/// When the eye runs (the hub starts and stops it) and whether the camera is in use now.
struct EyeStatus: Decodable, Sendable, Equatable {
    enum Mode: String, Decodable, Sendable, CaseIterable, Identifiable {
        case off, auto, on
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .auto: "Auto"
            case .on: "On"
            }
        }
        var symbol: String {
            switch self {
            case .off: "eye.slash"
            case .auto: "person.crop.circle.badge.checkmark"
            case .on: "eye"
            }
        }
        var explanation: String {
            switch self {
            case .off: "The camera is released."
            case .auto: "On while someone is at the desk, off two minutes after they leave."
            case .on: "The camera runs all the time."
            }
        }
    }

    var mode: Mode
    var running: Bool
    var camera: String?
    var here: Bool?

    enum CodingKeys: String, CodingKey { case mode, running, camera, here }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .off
        running = (try? c.decode(Bool.self, forKey: .running)) ?? false
        camera = try? c.decode(String.self, forKey: .camera)
        here = try? c.decode(Bool.self, forKey: .here)
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
    let hands: [CGRect]
    let sign: String?
    let posture: String?
    let isTired: Bool
    let things: [String]
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
        hands = (message.hands ?? []).compactMap(Self.rect)
        sign = message.sign
        posture = message.posture
        isTired = message.tired ?? false
        things = message.things ?? []
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
