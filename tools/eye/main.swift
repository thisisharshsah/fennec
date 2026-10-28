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
    var fov = 60.0
    /// The hub says an app is watching the live picture; only then are pictures encoded and sent.
    var wantPicture = false
    let jpegContext = CIContext()

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
        post("hello", ["unit": "eye", "fw": "eye 0.1 (Mac test rig)", "sensors": ["camera-on-mac", "vision-person", "vision-face"], "hfov": fov])
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= 0.2, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }  // 5 per second
        lastFrame = now
        if lastReport == .distantPast { describe(pixels) }
        frames += 1
        if snap && frames == 10 { save(pixels) }                    // two seconds in, after the camera settles
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true            // a desk view shows the upper body only
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([bodies, faces])
        let found = bodies.results ?? []
        people = found.count
        if let nearest = found.max(by: { $0.boundingBox.height < $1.boundingBox.height }) {
            let seen = Double(nearest.boundingBox.midX) * 2 - 1    // -1 left .. +1 right of the picture
            x = seenFrames == 0 ? seen : x * 0.6 + seen * 0.4      // smoothed, so the head glides
            size = Double(nearest.boundingBox.height)              // 0..1, bigger is closer
        }
        let faceList = faces.results ?? []
        facing = faceList.contains { abs($0.yaw?.doubleValue ?? 1) < 0.35 }
        report(now)
        looks(now)
        let r = { (v: CGFloat) in (Double(v) * 1000).rounded() / 1000 }
        let box = { (b: CGRect) in [r(b.minX), r(b.minY), r(b.width), r(b.height)] }
        var outline: [String: Any] = ["unit": "eye", "people": people, "looking": lookingShown, "present": present,
                                      "bodies": found.map { box($0.boundingBox) },
                                      "faces": faceList.map { box($0.boundingBox) + [abs($0.yaw?.doubleValue ?? 1) < 0.35 ? 1 : 0] },
                                      "aspect": Double(CVPixelBufferGetWidth(pixels)) / Double(max(CVPixelBufferGetHeight(pixels), 1))]
        if present { outline["aim"] = (x * 100).rounded() / 100; outline["pan"] = pan(x) }
        if let since = arrivedAt { outline["since"] = since.timeIntervalSince1970 }
        post("vision", outline) { [weak self] answer in                // the apps draw this; the hub does not keep it
            let want = answer["picture"] as? Bool ?? false
            self?.queue.async { self?.wantPicture = want }
        }
        if wantPicture { sendPicture(pixels) }
        if watch {
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            let shapes = Shapes(size: size, bodies: found.map(\.boundingBox),
                                faces: faceList.map { ($0.boundingBox, abs($0.yaw?.doubleValue ?? 1) < 0.35) },
                                aim: present ? x : nil, lines: readout(now))
            DispatchQueue.main.async { viewer?.show(shapes) }
        }
    }

    /// The head turn the hub makes for x (the hub's eye_pan, repeated here for the window).
    func pan(_ x: Double) -> Int {
        Int((atan(x * tan(fov * .pi / 360)) * 180 / .pi).rounded())
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
        print("eye: people \(people)  x \(String(format: "%+.2f", x))  facing \(facing)")
    }
}

/// What one analysed frame shows, for the window. Rects are Vision's: 0..1, origin bottom left.
struct Shapes {
    let size: CGSize
    let bodies: [CGRect]
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
