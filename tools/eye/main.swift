// Fennec "eye" (test rig): a camera on the Mac stands in for the creature's future camera.
// Frames are analysed on the Mac with Apple's Vision framework and thrown away; only facts
// (how many people, where the nearest one is, whether they face the camera) go to the hub,
// as the unit "eye" through the hub's HTTP ingest on this Mac.
//
//   swiftc -O tools/eye/main.swift -o tools/eye/eye && tools/eye/eye            (first camera named Osmo)
//   tools/eye/eye Osmo        part of the camera's name
//   tools/eye/eye Osmo snap   also save one frame to data/eye.jpg (on this Mac only), to check the aim
//   tools/eye/eye Brio 52     the lens's horizontal field of view in degrees, if not in the table below
//   tools/eye/eye Brio view   also open a window with the picture and what the eye makes of it
import AppKit
import AVFoundation
import CoreImage
import Foundation
import Vision

setvbuf(stdout, nil, _IOLBF, 0)                                // line by line, also into a log file
let hub = URL(string: "http://127.0.0.1:8776")!
let wanted = CommandLine.arguments.dropFirst().first ?? "Osmo"
let snap = CommandLine.arguments.contains("snap")
let watch = CommandLine.arguments.contains("view")
// Horizontal field of view at 16:9 (macOS does not report it). The hub turns the head by it.
let knownFov: [String: Double] = ["Brio 101": 52, "MacBook Pro Camera": 60]
let givenFov = CommandLine.arguments.dropFirst().compactMap { Double($0) }.first

func post(_ path: String, _ body: [String: Any], reply: (@Sendable ([String: Any]) -> Void)? = nil) {
    var req = URLRequest(url: hub.appendingPathComponent(path))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 2
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let reply, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        reply(json)
    }.resume()
}

/// Hand signals from Vision's hand joints: a thumbs-up, an open palm held still, or a wave
/// (an open palm moving side to side). Coordinates are in picture heights, so distances compare.
struct HandReader {
    enum Sign: String {
        case thumbsUp = "thumbs_up", palm = "open_palm", wave = "waved"
        var label: String {
            switch self {
            case .thumbsUp: "thumbs-up"
            case .palm: "open palm (not now)"
            case .wave: "wave"
            }
        }
    }

    struct Shape {
        let sign: Sign?
        let wrist: CGPoint
        let box: CGRect          // 0..1 of the picture, origin bottom left, for drawing
    }

    private var palmXs: [(t: Date, x: Double)] = []
    private var held: Sign?
    private var heldSince = Date.distantFuture
    private var lastSent: [Sign: Date] = [:]

    /// The shape one hand makes in this frame.
    static func shape(_ hand: VNHumanHandPoseObservation, aspect: Double) -> Shape? {
        guard let points = try? hand.recognizedPoints(.all) else { return nil }
        let sure = points.values.filter { $0.confidence > 0.3 }.map(\.location)
        guard sure.count >= 8, let minX = sure.map(\.x).min(), let maxX = sure.map(\.x).max(),
              let minY = sure.map(\.y).min(), let maxY = sure.map(\.y).max() else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        func at(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[joint], p.confidence > 0.3 else { return nil }
            return CGPoint(x: p.location.x * aspect, y: p.location.y)
        }
        guard let wrist = at(.wrist) else { return nil }
        func reach(_ p: CGPoint) -> Double { hypot(p.x - wrist.x, p.y - wrist.y) }
        func extended(_ tip: VNHumanHandPoseObservation.JointName, _ pip: VNHumanHandPoseObservation.JointName) -> Bool? {
            guard let t = at(tip), let p = at(pip) else { return nil }
            return reach(t) > reach(p) * 1.2
        }
        let fingers = [extended(.indexTip, .indexPIP), extended(.middleTip, .middlePIP),
                       extended(.ringTip, .ringPIP), extended(.littleTip, .littlePIP)]
        guard fingers.allSatisfy({ $0 != nil }) else { return Shape(sign: nil, wrist: wrist, box: box) }
        var sign: Sign?
        if fingers.allSatisfy({ $0 == true }), let middle = at(.middleTip), middle.y > wrist.y + 0.05 {
            sign = .palm                                              // all four fingers out, pointing up
        } else if fingers.allSatisfy({ $0 == false }), let thumb = at(.thumbTip), let ip = at(.thumbIP),
                  let knuckle = at(.indexMCP), thumb.y > ip.y, thumb.y > knuckle.y + 0.04 {
            sign = .thumbsUp                                          // a fist with the thumb above it
        }
        return Shape(sign: sign, wrist: wrist, box: box)
    }

    /// Feed every analysed frame. Returns a sign once when it is made, then not again for 4 s.
    mutating func update(_ shapes: [Shape], now: Date) -> Sign? {
        if let palm = shapes.first(where: { $0.sign == .palm }) { palmXs.append((now, palm.wrist.x)) }
        palmXs.removeAll { now.timeIntervalSince($0.t) > 2.5 }
        // a wave: the open hand turns back at least twice, across a tenth of the picture's height or more
        let xs = palmXs.map(\.x)
        var turns = 0, direction = 0.0
        for (a, b) in zip(xs, xs.dropFirst()) where abs(b - a) > 0.012 {
            let d: Double = b > a ? 1 : -1
            if direction != 0 && d != direction { turns += 1 }
            direction = d
        }
        if turns >= 2, let lo = xs.min(), let hi = xs.max(), hi - lo > 0.1 {
            palmXs.removeAll()
            held = nil
            return send(.wave, now)
        }
        let current = shapes.compactMap(\.sign).first
        if current != held {
            held = current
            heldSince = now
            return nil
        }
        guard let sign = current, now.timeIntervalSince(heldSince) >= (sign == .palm ? 1.2 : 0.7) else { return nil }
        if sign == .palm {                                            // held still, so not the start of a wave
            let recent = palmXs.filter { now.timeIntervalSince($0.t) <= 1.2 }.map(\.x)
            guard let lo = recent.min(), let hi = recent.max(), hi - lo < 0.05 else { return nil }
        }
        heldSince = .distantFuture                                    // once per hold
        return send(sign, now)
    }

    private mutating func send(_ sign: Sign, _ now: Date) -> Sign? {
        if let last = lastSent[sign], now.timeIntervalSince(last) < 4 { return nil }
        lastSent[sign] = now
        return sign
    }
}

/// How many times a series turns back by at least `minLeg` (a zigzag filter, so jitter smaller than
/// a leg never counts). A nod, down, up and down again, is 2.
func reversals(_ values: [Double], minLeg: Double) -> Int {
    guard var high = values.first else { return 0 }
    var low = high
    var direction = 0                     // 1 rising, -1 falling, 0 not yet moving
    var count = 0
    for v in values.dropFirst() {
        switch direction {
        case 0:
            high = max(high, v)
            low = min(low, v)
            if high - low >= minLeg { direction = v == high ? 1 : -1 }
        case 1:
            if v > high { high = v } else if high - v >= minLeg { direction = -1; low = v; count += 1 }
        default:
            if v < low { low = v } else if v - low >= minLeg { direction = 1; high = v; count += 1 }
        }
    }
    return count
}

/// Each value averaged with the one before: takes the frame to frame jitter out of Vision's angles.
func smoothed(_ values: [Double]) -> [Double] {
    zip(values, values.dropFirst()).map { ($0 + $1) / 2 }
}

/// The p-th fraction of a list (0.8: higher than 80 % of it).
func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// Head gestures from the face's angles, 10 times a second: a nod says yes, a shake says no.
struct HeadReader {
    enum Sign: String { case nod = "nodded", shake = "shook_head" }
    private var pitches: [(t: Date, v: Double)] = []
    private var yaws: [(t: Date, v: Double)] = []
    private var lastSent = Date.distantPast

    mutating func update(pitch: Double?, yaw: Double?, now: Date) -> Sign? {
        if let pitch { pitches.append((now, pitch)) }
        if let yaw { yaws.append((now, yaw)) }
        pitches.removeAll { now.timeIntervalSince($0.t) > 1.6 }
        yaws.removeAll { now.timeIntervalSince($0.t) > 1.6 }
        guard now.timeIntervalSince(lastSent) > 3 else { return nil }
        // down, up, down again (or left, right, left), each leg at least 9° for a nod, 13° for a shake
        let nod = reversals(smoothed(pitches.map(\.v)), minLeg: 0.16) >= 2
        let shake = reversals(smoothed(yaws.map(\.v)), minLeg: 0.22) >= 2
        guard nod != shake else { return nil }                       // neither, or a wobble in both
        lastSent = now
        pitches.removeAll()
        yaws.removeAll()
        return nod ? .nod : .shake
    }
}

/// Posture from the body skeleton, against the owner's own upright baseline learned as they sit.
struct PostureReader {
    enum State: String { case upright, slouching, close }
    private var ratios: [Double] = []         // head height over shoulder width, once a second, last 20 min
    private var widths: [Double] = []
    private var lastSample = Date.distantPast
    private var slouchSince: Date?
    private var uprightSince: Date?
    private var armsUpSince: Date?
    private var lastStretch = Date.distantPast
    private(set) var reported = false         // a slouch was announced and not yet ended
    private(set) var state: State?

    /// Returns the events to send: slouching (a minute of it), sat_up, stretched.
    mutating func update(_ body: VNHumanBodyPoseObservation?, aspect: Double, now: Date) -> [String] {
        guard let body, let points = try? body.recognizedPoints(.all) else { state = nil; return [] }
        func at(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = points[joint], p.confidence > 0.3 else { return nil }
            return CGPoint(x: p.location.x * aspect, y: p.location.y)
        }
        guard let left = at(.leftShoulder), let right = at(.rightShoulder), let nose = at(.nose) else { state = nil; return [] }
        let width = hypot(left.x - right.x, left.y - right.y)
        guard width > 0.05 else { state = nil; return [] }
        let ratio = (nose.y - (left.y + right.y) / 2) / width
        var events: [String] = []

        if now.timeIntervalSince(lastSample) >= 1 {
            lastSample = now
            ratios.append(ratio)
            widths.append(width)
            if ratios.count > 1200 { ratios.removeFirst(); widths.removeFirst() }
        }
        // both wrists above the head for a second: a stretch, which counts as a short break
        if let lw = at(.leftWrist), let rw = at(.rightWrist), lw.y > nose.y, rw.y > nose.y {
            if armsUpSince == nil { armsUpSince = now }
            if let since = armsUpSince, now.timeIntervalSince(since) >= 1, now.timeIntervalSince(lastStretch) > 60 {
                lastStretch = now
                events.append("stretched")
            }
        } else {
            armsUpSince = nil
        }
        guard ratios.count >= 30, let upright = percentile(ratios, 0.8), let usual = percentile(widths, 0.5) else {
            state = .upright
            return events
        }
        let slouched = ratio < upright * 0.72
        state = slouched ? .slouching : (width > usual * 1.35 ? .close : .upright)
        if slouched {
            uprightSince = nil
            if slouchSince == nil { slouchSince = now }
            if !reported, let since = slouchSince, now.timeIntervalSince(since) >= 60 {
                reported = true
                events.append("slouching")
            }
        } else {
            slouchSince = nil
            if uprightSince == nil { uprightSince = now }
            if reported, let since = uprightSince, now.timeIntervalSince(since) >= 10 {
                reported = false
                events.append("sat_up")
            }
        }
        return events
    }
}

/// Signs of tiredness from face landmarks: eyes closed for a while, and yawns.
struct TiredReader {
    private var openings: [Double] = []       // eye openness when looking ahead, last few minutes
    private var closedSince: Date?
    private var yawnSince: Date?
    private var lastHeavy = Date.distantPast
    private var lastYawn = Date.distantPast
    private(set) var signs: [Date] = []       // tired signs in the last 15 min
    private(set) var eyesClosed = false

    var isTired: Bool { signs.count >= 2 }

    static func openness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
        guard let points = region?.normalizedPoints, points.count >= 4 else { return nil }
        let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
        guard let w = xs.max().flatMap({ m in xs.min().map { m - $0 } }), w > 0,
              let h = ys.max().flatMap({ m in ys.min().map { m - $0 } }) else { return nil }
        return h / w
    }

    /// Returns the events to send: eyes_heavy, yawned.
    /// `pitch` is the head's tilt: looking down at a keyboard lowers the eyelids, which is not tiredness.
    mutating func update(_ face: VNFaceObservation?, pitch: Double?, now: Date) -> [String] {
        signs.removeAll { now.timeIntervalSince($0) > 15 * 60 }
        guard let face, let marks = face.landmarks, abs(face.yaw?.doubleValue ?? 1) < 0.35,
              abs(pitch ?? 1) < 0.25 else {
            closedSince = nil; yawnSince = nil; eyesClosed = false
            return []
        }
        var events: [String] = []
        let eyes = [Self.openness(marks.leftEye), Self.openness(marks.rightEye)].compactMap { $0 }
        if eyes.count == 2 {
            let eye = (eyes[0] + eyes[1]) / 2
            openings.append(eye)
            if openings.count > 900 { openings.removeFirst() }
            if openings.count >= 50, let open = percentile(openings, 0.7) {
                eyesClosed = eye < open * 0.45
                if eyesClosed {
                    if closedSince == nil { closedSince = now }
                    if let since = closedSince, now.timeIntervalSince(since) >= 1.0, now.timeIntervalSince(lastHeavy) > 20 {
                        lastHeavy = now                       // longer than a blink
                        signs.append(now)
                        events.append("eyes_heavy")
                    }
                } else {
                    closedSince = nil
                }
            }
        }
        if let mouth = Self.openness(marks.innerLips), mouth > 0.55 {
            if yawnSince == nil { yawnSince = now }
            if let since = yawnSince, now.timeIntervalSince(since) >= 2.0, now.timeIntervalSince(lastYawn) > 15 {
                lastYawn = now                                // held wide open: a yawn, not talking
                signs.append(now)
                events.append("yawned")
            }
        } else {
            yawnSince = nil
        }
        return events
    }
}

/// Things in the owner's hands (a phone, a drink, food, a book) and pets in view. Classifying the
/// whole picture would name the room (a bed, a shelf), so only the area around the hands is read.
struct ThingReader {
    static let groups: [String: String] = [
        "phone": "phone",
        "cup": "drink", "mug": "drink", "drinking_glass": "drink", "bottle": "drink", "coffee": "drink",
        "tea_drink": "drink", "drink": "drink",
        "food": "food", "sandwich": "food", "pizza": "food", "fruit": "food", "banana": "food", "apple": "food",
        "bowl": "food", "plate": "food",
        "book": "book", "newspaper": "book",
        "headphones": "headphones", "gamepad": "game controller",
    ]
    private var seen: [String: Date] = [:]

    /// What was seen in the last 4 s (classification runs every 2 s and is not sure every time).
    func things(at now: Date) -> [String] {
        seen.filter { now.timeIntervalSince($0.value) < 4 }.map(\.key).sorted()
    }

    mutating func update(_ handler: VNImageRequestHandler, hands: [CGRect], now: Date) {
        if let area = Self.around(hands) {
            let classify = VNClassifyImageRequest()
            classify.regionOfInterest = area
            try? handler.perform([classify])
            for c in classify.results ?? [] where c.confidence > 0.25 {
                if let group = Self.groups[c.identifier] { seen[group] = now }
            }
        }
        let animals = VNRecognizeAnimalsRequest()
        try? handler.perform([animals])
        for a in animals.results ?? [] {
            if let label = a.labels.first, label.confidence > 0.6 { seen[label.identifier.lowercased()] = now }
        }
    }

    /// The hands' boxes together, twice as large (what is held sticks out of the hand), in the picture.
    static func around(_ hands: [CGRect]) -> CGRect? {
        guard let first = hands.first else { return nil }
        let union = hands.dropFirst().reduce(first) { $0.union($1) }
        let grown = union.insetBy(dx: -union.width / 2, dy: -union.height / 2)
        let clipped = grown.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.width < 0.02 || clipped.height < 0.02 ? nil : clipped
    }
}

final class Eye: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "fennec.eye")
    var lastFrame = Date.distantPast
    var lastReport = Date.distantPast
    var present = false
    var absentSince: Date?
    var people = 0, x = 0.0, size = 0.0, facing = false
    var frames = 0
    var seenFrames = 0
    var facingFrames = 0, awayFrames = 0, lookingShown = false
    var arrivedAt: Date?
    var notes: [String] = []
    var lastPrinted = ""
    var fov = 60.0
    /// The hub says an app is watching the live picture; only then are pictures encoded and sent.
    var wantPicture = false
    let jpegContext = CIContext()
    var handReader = HandReader()
    var headReader = HeadReader()
    var postureReader = PostureReader()
    var tiredReader = TiredReader()
    var thingReader = ThingReader()
    var handBoxes: [CGRect] = []
    var lastSign: (name: String, at: Date)?

    func start() throws {
        let types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(wanted) }) else {
            print("no camera matching \"\(wanted)\"; found: \(devices.map(\.localizedName))")
            exit(1)
        }
        fov = givenFov ?? knownFov[device.localizedName] ?? 60
        print("eye: using \(device.localizedName), field of view \(Int(fov))°")
        // 16:9 keeps the lens's full width; 4:3 crops the sides of most webcams
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .vga640x480
        session.addInput(try AVCaptureDeviceInput(device: device))
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.startRunning()
        post("hello", ["unit": "eye", "fw": "eye 0.1 (Mac test rig)", "sensors": ["camera-on-mac", "vision-person", "vision-face", "vision-hand", "vision-pose"], "hfov": fov])
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        // hands and face angles 10 times a second (a wave or a nod is quick); people, posture and
        // face landmarks on every second frame, 5 a second
        guard now.timeIntervalSince(lastFrame) >= 0.1, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        lastFrame = now
        if frames == 0 { describe(pixels) }
        frames += 1
        if snap && frames == 20 { save(pixels) }                    // two seconds in, after the camera settles
        let full = frames % 2 == 0
        let aspect = Double(CVPixelBufferGetWidth(pixels)) / Double(max(CVPixelBufferGetHeight(pixels), 1))
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true            // a desk view shows the upper body only
        let faces = VNDetectFaceRectanglesRequest()
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        let pose = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])
        try? handler.perform(full ? [hands, faces, bodies, pose] : [hands, faces])
        let handShapes = (hands.results ?? []).compactMap { HandReader.shape($0, aspect: aspect) }
        handBoxes = handShapes.map(\.box)
        if let sign = handReader.update(handShapes, now: now) { signal(sign.rawValue, sign.label, now) }
        let faceList = faces.results ?? []
        let nearestFace = faceList.max { $0.boundingBox.height < $1.boundingBox.height }
        if let sign = headReader.update(pitch: nearestFace?.pitch?.doubleValue, yaw: nearestFace?.yaw?.doubleValue, now: now) {
            signal(sign.rawValue, sign == .nod ? "nod (yes)" : "head shake (no)", now)
        }
        guard full else { return }
        let skeleton = (pose.results ?? []).max { $0.confidence < $1.confidence }
        for event in postureReader.update(skeleton, aspect: aspect, now: now) {
            signal(event, ["slouching": "slouching", "sat_up": "sat up", "stretched": "stretch"][event] ?? event, now)
        }
        var landmarked: VNFaceObservation?
        if let nearestFace {
            let marks = VNDetectFaceLandmarksRequest()
            marks.inputFaceObservations = [nearestFace]
            try? handler.perform([marks])
            landmarked = marks.results?.first
        }
        for event in tiredReader.update(landmarked, pitch: nearestFace?.pitch?.doubleValue, now: now) {
            signal(event, event == "yawned" ? "yawn" : "heavy eyes", now)
        }
        if frames % 20 == 0 { thingReader.update(handler, hands: handBoxes, now: now) }   // every 2 s
        let found = bodies.results ?? []
        people = found.count
        if let nearest = found.max(by: { $0.boundingBox.height < $1.boundingBox.height }) {
            let seen = Double(nearest.boundingBox.midX) * 2 - 1    // -1 left .. +1 right of the picture
            x = seenFrames == 0 ? seen : x * 0.6 + seen * 0.4      // smoothed, so the head glides
            size = Double(nearest.boundingBox.height)              // 0..1, bigger is closer
        }
        facing = faceList.contains { abs($0.yaw?.doubleValue ?? 1) < 0.35 }
        report(now)
        looks(now)
        let r = { (v: CGFloat) in (Double(v) * 1000).rounded() / 1000 }
        let box = { (b: CGRect) in [r(b.minX), r(b.minY), r(b.width), r(b.height)] }
        var outline: [String: Any] = ["unit": "eye", "people": people, "looking": lookingShown, "present": present,
                                      "bodies": found.map { box($0.boundingBox) },
                                      "faces": faceList.map { box($0.boundingBox) + [abs($0.yaw?.doubleValue ?? 1) < 0.35 ? 1 : 0] },
                                      "hands": handBoxes.map(box), "aspect": aspect]
        if let shown = lastSign, now.timeIntervalSince(shown.at) < 2 { outline["sign"] = shown.name }
        if present, let posture = postureReader.state { outline["posture"] = posture.rawValue }
        if present { outline["tired"] = tiredReader.isTired }
        let things = thingReader.things(at: now)
        if !things.isEmpty { outline["things"] = things }
        if present { outline["aim"] = (x * 100).rounded() / 100; outline["pan"] = pan(x) }
        if let since = arrivedAt { outline["since"] = since.timeIntervalSince1970 }
        post("vision", outline) { [weak self] answer in                // the apps draw this; the hub does not keep it
            let want = answer["picture"] as? Bool ?? false
            self?.queue.async { self?.wantPicture = want }
        }
        if wantPicture { sendPicture(pixels) }
        if watch {
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            let shapes = Shapes(size: size, bodies: found.map(\.boundingBox), hands: handBoxes,
                                faces: faceList.map { ($0.boundingBox, abs($0.yaw?.doubleValue ?? 1) < 0.35) },
                                aim: present ? x : nil, lines: readout(now))
            DispatchQueue.main.async { viewer?.show(shapes) }
        }
    }

    /// The head turn the hub makes for x (the hub's eye_pan, repeated here for the window).
    func pan(_ x: Double) -> Int {
        Int((atan(x * tan(fov * .pi / 360)) * 180 / .pi).rounded())
    }

    /// Something the eye read: noted in the window, shown on the card for 2 s, sent to the hub.
    func signal(_ name: String, _ label: String, _ now: Date) {
        lastSign = (name, now)
        note(label, now)
        post("event", ["unit": "eye", "name": name])
    }

    func note(_ text: String, _ now: Date) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        notes.append("\(f.string(from: now))  \(text)")
        if notes.count > 6 { notes.removeFirst() }
    }

    /// Looking at Crawl counts after 3 frames in a row and ends after 10 without (2 s), so a glance does not flicker.
    func looks(_ now: Date) {
        facingFrames = facing ? facingFrames + 1 : 0
        awayFrames = facing ? 0 : awayFrames + 1
        if present && facingFrames >= 3 && !lookingShown {
            lookingShown = true
            note("looked at Crawl", now)
            post("event", ["unit": "eye", "name": "looked_at"])
        }
        if lookingShown && (!present || awayFrames >= 10) {
            lookingShown = false
            note("looked away", now)
            post("event", ["unit": "eye", "name": "looked_away"])
        }
    }

    func readout(_ now: Date) -> [String] {
        var lines = [people == 0 ? "nobody in view" : "\(people) \(people == 1 ? "person" : "people") in view"]
        if present {
            let p = pan(x)
            let side = abs(p) < 3 ? "straight ahead" : "\(abs(p))° to its \(p < 0 ? "left" : "right")"
            lines.append(lookingShown ? "looking at Crawl" : "not looking at Crawl")
            lines.append("Crawl's head turns \(side)")
            lines.append(String(format: "closeness %.2f (bigger is closer)", size))
            if let posture = postureReader.state { lines.append("posture: \(posture.rawValue)") }
            if tiredReader.isTired { lines.append("looks tired") }
            let things = thingReader.things(at: now)
            if !things.isEmpty { lines.append("sees: \(things.joined(separator: ", "))") }
            if let since = arrivedAt { lines.append("here for \(Int(now.timeIntervalSince(since)) / 60) min \(Int(now.timeIntervalSince(since)) % 60) s") }
        } else {
            lines.append("away")
        }
        return lines + [""] + notes
    }

    /// Once at start: frame size and mean brightness, so a black or frozen feed is obvious.
    func describe(_ pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        var sum = 0, n = 0
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) ?? CVPixelBufferGetBaseAddress(pixels) {
            let row = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: min(w, row), by: 16) { sum += Int(p[y * row + x]); n += 1 } }
        }
        print("eye: frames \(w)x\(h), brightness \(n > 0 ? sum / n : -1) of 255")
    }

    /// A small JPEG of the frame for the app watching (480 wide, about 20 KB). Sent, never written to disk.
    func sendPicture(_ pixels: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixels)
        let scale = 480 / max(image.extent.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = jpegContext.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                        options: [quality: 0.55]) else { return }
        post("picture", ["unit": "eye", "jpeg": data.base64EncodedString()])
    }

    func save(_ pixels: CVPixelBuffer) {
        let url = URL(fileURLWithPath: "data/eye.jpg")
        let image = CIImage(cvPixelBuffer: pixels)
        try? CIContext().writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        print("eye: saved one frame to \(url.path)")
    }

    func report(_ now: Date) {
        // A person must be seen in 3 frames in a row to arrive, and missed for 5 s to leave:
        // leaning or turning away loses them for a few frames and is not leaving.
        seenFrames = people > 0 ? seenFrames + 1 : 0
        if people > 0 {
            absentSince = nil
            if !present && seenFrames >= 3 {
                present = true
                arrivedAt = now
                note("arrived", now)
                post("event", ["unit": "eye", "name": "person_appeared", "x": x])
            }
        } else if present {
            if absentSince == nil { absentSince = now }
            if let since = absentSince, now.timeIntervalSince(since) > 5 {
                present = false
                arrivedAt = nil
                note("left", now)
                post("event", ["unit": "eye", "name": "person_left"])
            }
        }
        guard now.timeIntervalSince(lastReport) >= 1 else { return }
        lastReport = now
        var state: [String: Any] = ["unit": "eye", "people": people, "facing": facing]
        if people > 0 { state["x"] = (x * 100).rounded() / 100; state["size"] = (size * 100).rounded() / 100 }
        post("state", state)
        let line = "eye: people \(people)  facing \(facing)"     // the log gets changes, not a line a second
        if line != lastPrinted {
            lastPrinted = line
            print("\(line)  x \(String(format: "%+.2f", x))")
        }
    }
}

/// What one analysed frame shows, for the window. Rects are Vision's: 0..1, origin bottom left.
struct Shapes {
    let size: CGSize
    let bodies: [CGRect]
    let hands: [CGRect]
    let faces: [(CGRect, Bool)]
    let aim: Double?
    let lines: [String]
}

/// The window of `view`: the live picture, mirrored like a mirror, with the eye's findings on top.
final class Viewer: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    let preview: AVCaptureVideoPreviewLayer
    let marks = CALayer()
    let label = CATextLayer()
    var mirrored = false

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        for layer in [preview, marks] as [CALayer] {
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            root.addSublayer(layer)
        }
        preview.videoGravity = .resizeAspect
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
            mirrored = true
        }
        label.fontSize = 15
        label.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        label.cornerRadius = 8
        label.contentsScale = 2
        root.addSublayer(label)
        window.contentView = view
        window.title = "Fennec eye: test rig, nothing is saved"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.delegate = self
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Where the picture sits inside the window (aspect fit), in layer points.
    func pictureRect(_ size: CGSize) -> CGRect {
        let b = marks.bounds, aspect = size.width / max(size.height, 1)
        var w = b.width, h = w / aspect
        if h > b.height { h = b.height; w = h * aspect }
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    func place(_ r: CGRect, in pic: CGRect) -> CGRect {
        let x = mirrored ? 1 - r.maxX : r.minX
        return CGRect(x: pic.minX + x * pic.width, y: pic.minY + r.minY * pic.height, width: r.width * pic.width, height: r.height * pic.height)
    }

    func box(_ r: CGRect, _ color: NSColor, width: CGFloat = 3) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        s.strokeColor = color.cgColor
        s.fillColor = nil
        s.lineWidth = width
        return s
    }

    func show(_ shapes: Shapes) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.sublayers = nil
        let pic = pictureRect(shapes.size)
        for b in shapes.bodies { marks.addSublayer(box(place(b, in: pic), .systemGreen)) }       // a person
        for h in shapes.hands { marks.addSublayer(box(place(h, in: pic), .systemPurple)) }        // a hand
        for (f, looking) in shapes.faces {                                                       // a face, yellow when looking
            marks.addSublayer(box(place(f, in: pic), looking ? .systemYellow : .systemGray, width: 2))
        }
        if let aim = shapes.aim {                                                                // where the head points
            let u = mirrored ? (1 - aim) / 2 : (aim + 1) / 2
            let line = CGRect(x: pic.minX + u * pic.width - 1, y: pic.minY, width: 2, height: pic.height)
            marks.addSublayer(box(line, .systemOrange, width: 2))
        }
        label.string = shapes.lines.map { "  " + $0 }.joined(separator: "\n")
        let lineCount = CGFloat(shapes.lines.count)
        let h = lineCount * 19 + 16
        label.frame = CGRect(x: 12, y: marks.bounds.height - h - 12, width: 380, height: h)
        CATransaction.commit()
    }
}

var viewer: Viewer?
let eye = Eye()

func begin() {
    do { try eye.start() } catch { print("camera error: \(error)"); exit(1) }
    if watch { DispatchQueue.main.async { viewer = Viewer(session: eye.session) } }
}

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    begin()
case .notDetermined:
    print("eye: asking macOS for camera access (allow it in the dialog)")
    AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else { print("camera access denied"); exit(1) }
        begin()
    }
default:
    print("camera access is off for this app: System Settings > Privacy & Security > Camera")
    exit(1)
}
if watch {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
} else {
    RunLoop.main.run()
}
