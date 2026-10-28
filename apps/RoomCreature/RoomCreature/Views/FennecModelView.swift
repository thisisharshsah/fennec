import SwiftUI
import RealityKit
import simd
#if os(macOS)
import AppKit
private typealias BotColor = NSColor
#else
import UIKit
private typealias BotColor = UIColor
#endif

/// A live ceramic desk bot with articulated antenna fins and a luminous screen face.
struct FennecModelView: View {
    let state: BodyState
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var rig: CreatureBotRig?

    private var motionAllowed: Bool { animates && !reduceMotion && scenePhase == .active }
    private var animationKey: String { "\(motionAllowed)-\(rig != nil)" }

    var body: some View {
        GeometryReader { geometry in
            RealityView { content in
                content.camera = .virtual
                let character = CreatureBotRig()
                content.add(character.scene)
                character.frameCamera(aspect: geometry.size.width / max(geometry.size.height, 1))
                character.apply(state, animated: false)
                rig = character
            } update: { _ in
                rig?.frameCamera(aspect: geometry.size.width / max(geometry.size.height, 1))
                rig?.apply(state, animated: motionAllowed)
            }
            .realityViewCameraControls(.none)
        }
        .task(id: animationKey) {
            guard motionAllowed, let rig else { return }
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                rig.idle(at: Float(seconds))
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { break }
            }
            rig.rest()
        }
        .onChange(of: motionAllowed) { _, allowed in
            if !allowed { rig?.rest() }
        }
        .onDisappear { rig?.rest() }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

@MainActor
private final class CreatureBotRig {
    let scene = Entity()
    private let body = Entity()
    private let headJoint = Entity()
    private let head = Entity()
    private let leftFin = Entity()
    private let rightFin = Entity()
    private let tail = Entity()
    private let camera = PerspectiveCamera()
    private let smile = Entity()
    private let surprise = Entity()
    private let sphere = MeshResource.generateSphere(radius: 1)
    private var eyes: [Entity] = []
    private var cheeks: [ModelEntity] = []
    private var lastState: BodyState?
    private var lastAnimated = false
    private var eyeHeight: Float = 1
    private var gestureTime: Float = 10
    private var currentGesture = ""
    private var lastIdleTime: Float = 0
    private var tailRotation = simd_quatf()
    private var finRotations: [simd_quatf] = []
    private var headPose = Transform()

    private let ivory = BotColor(red: 0.98, green: 0.94, blue: 0.86, alpha: 1)
    private let lilac = BotColor(red: 0.66, green: 0.57, blue: 0.85, alpha: 1)
    private let lilacLight = BotColor(red: 0.80, green: 0.73, blue: 0.98, alpha: 1)
    private let navy = BotColor(red: 0.025, green: 0.040, blue: 0.105, alpha: 1)
    private let cyan = BotColor(red: 0.22, green: 0.85, blue: 1.0, alpha: 1)
    private let jointColor = BotColor(red: 0.31, green: 0.27, blue: 0.44, alpha: 1)

    init() {
        scene.name = "creature-bot-studio"
        body.name = "bot-body"
        head.name = "bot-head"
        headJoint.name = "bot-neck-joint"
        leftFin.name = "bot-antenna-left"
        rightFin.name = "bot-antenna-right"
        tail.name = "bot-cable-tail"
        scene.addChild(body)
        buildBody()
        buildHead()
        buildTail()
        lightStudio()
        camera.name = "portrait-camera"
        camera.camera.fieldOfViewInDegrees = 31
        scene.addChild(camera)
        rest()
    }

    func frameCamera(aspect: CGFloat) {
        let aspect = max(Float(aspect), 0.4)
        let height: Float = max(2.87, 2.28 / aspect)
        let distance = height / (2 * tan(31 * .pi / 360))
        camera.look(at: [0.05, 1.19, 0], from: [0.10, 1.55, distance], relativeTo: nil)
    }

    private func ceramic(_ color: BotColor, roughness: Float = 0.30, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        material.clearcoat = 0.45
        material.clearcoatRoughness = 0.22
        return material
    }

    private func luminous(_ color: BotColor, intensity: Float = 0.8) -> PhysicallyBasedMaterial {
        var material = ceramic(color, roughness: 0.22)
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = intensity
        return material
    }

    @discardableResult
    private func oval(_ name: String, at position: SIMD3<Float>, size: SIMD3<Float>, material: any RealityKit.Material, parent: Entity) -> ModelEntity {
        let entity = ModelEntity(mesh: sphere, materials: [material])
        entity.name = name
        entity.position = position
        entity.scale = size
        parent.addChild(entity)
        return entity
    }

    @discardableResult
    private func rounded(_ name: String, at position: SIMD3<Float>, size: SIMD3<Float>, radius: Float, material: any RealityKit.Material, parent: Entity) -> ModelEntity {
        // Keep the front silhouette rounded even for very shallow screen and LED panels.
        let meshDepth = max(size.z, radius * 2 + 0.001)
        let meshSize = SIMD3<Float>(size.x, size.y, meshDepth)
        let entity = ModelEntity(mesh: .generateBox(size: meshSize, cornerRadius: radius), materials: [material])
        entity.name = name
        entity.position = position
        entity.scale.z = size.z / meshDepth
        parent.addChild(entity)
        return entity
    }

    private func buildBody() {
        rounded("lilac-torso", at: [0, 0.62, 0], size: [0.65, 0.66, 0.45], radius: 0.20, material: ceramic(lilacLight), parent: body)
        rounded("ivory-chest-panel", at: [0, 0.53, 0.22], size: [0.53, 0.43, 0.13], radius: 0.17, material: ceramic(ivory), parent: body)
        oval("chest-light-rim", at: [0, 0.78, 0.234], size: [0.088, 0.088, 0.03], material: ceramic(jointColor, metallic: 0.35), parent: body)
        oval("chest-status-light", at: [0, 0.78, 0.258], size: [0.063, 0.063, 0.022], material: luminous(cyan), parent: body)
        for side: Float in [-1, 1] {
            oval("ankle-hinge", at: [side * 0.205, 0.30, 0.015], size: [0.115, 0.13, 0.105], material: ceramic(jointColor, metallic: 0.35), parent: body)
            rounded("lilac-sole", at: [side * 0.23, 0.10, 0.11], size: [0.36, 0.14, 0.45], radius: 0.065, material: ceramic(lilac), parent: body)
            rounded("ivory-boot", at: [side * 0.23, 0.19, 0.10], size: [0.34, 0.25, 0.43], radius: 0.12, material: ceramic(ivory), parent: body)
            oval("boot-light-rim", at: [side * 0.395, 0.20, 0.12], size: [0.022, 0.065, 0.065], material: ceramic(jointColor, metallic: 0.5), parent: body)
            oval("boot-light", at: [side * 0.413, 0.20, 0.12], size: [0.012, 0.043, 0.043], material: luminous(cyan), parent: body)
            oval("shoulder-hinge", at: [side * 0.365, 0.83, 0], size: [0.105, 0.115, 0.12], material: ceramic(jointColor, metallic: 0.4), parent: body)
            oval("shoulder-cap", at: [side * 0.405, 0.83, 0.025], size: [0.105, 0.105, 0.115], material: ceramic(ivory), parent: body)
            let arm = Entity()
            arm.name = "bot-arm"
            arm.position = [side * 0.48, 0.63, 0.045]
            arm.orientation = simd_quatf(angle: side * 0.42, axis: [0, 0, 1])
            body.addChild(arm)
            rounded("ceramic-arm-shell", at: .zero, size: [0.21, 0.34, 0.23], radius: 0.10, material: ceramic(ivory), parent: arm)
            rounded("lilac-wrist-cap", at: [0, -0.145, 0], size: [0.17, 0.08, 0.19], radius: 0.04, material: ceramic(lilac), parent: arm)
            oval("wrist-light", at: [0, -0.07, 0.119], size: [0.059, 0.071, 0.013], material: luminous(cyan, intensity: 0.5), parent: arm)
        }
        oval("neck-ring", at: [0, 1.0, 0], size: [0.22, 0.072, 0.18], material: ceramic(jointColor, metallic: 0.45), parent: body)
        oval("neck-lilac-trim", at: [0, 1.045, 0], size: [0.21, 0.037, 0.18], material: ceramic(lilac), parent: body)
        headJoint.position = [0, 1.46, 0]
        body.addChild(headJoint)
        headJoint.addChild(head)
    }

    private func buildHead() {
        rounded("ivory-head-shell", at: .zero, size: [1.38, 1.08, 0.65], radius: 0.27, material: ceramic(ivory), parent: head)
        rounded("lavender-screen-rim", at: [0, 0, 0.305], size: [1.22, 0.90, 0.13], radius: 0.23, material: ceramic(lilac, roughness: 0.25, metallic: 0.25), parent: head)
        rounded("navy-glass-screen", at: [0, 0, 0.365], size: [1.16, 0.84, 0.10], radius: 0.21, material: ceramic(navy, roughness: 0.16), parent: head)
        let reflection = rounded("screen-soft-reflection", at: [-0.28, 0.305, 0.417], size: [0.30, 0.017, 0.004], radius: 0.008, material: ceramic(BotColor(red: 0.22, green: 0.25, blue: 0.38, alpha: 1), roughness: 0.3), parent: head)
        reflection.orientation = simd_quatf(angle: -0.08, axis: [0, 0, 1])
        for (index, side) in [Float(-1), Float(1)].enumerated() {
            let fin = index == 0 ? leftFin : rightFin
            fin.position = [side * 0.47, 0.43, -0.015]
            head.addChild(fin)
            oval("antenna-hinge", at: [0, 0.03, 0], size: [0.115, 0.11, 0.095], material: ceramic(jointColor, metallic: 0.4), parent: fin)
            oval("hinge-ring", at: [0, 0.035, 0.07], size: [0.095, 0.085, 0.032], material: ceramic(lilac, metallic: 0.25), parent: fin)
            let finHeight: Float = index == 0 ? 0.55 : 0.42
            rounded("ivory-antenna-fin", at: [0, finHeight * 0.5 + 0.09, 0], size: [0.23, finHeight, 0.13], radius: 0.105, material: ceramic(ivory), parent: fin)
            rounded("luminous-fin-panel", at: [0, finHeight * 0.5 + 0.09, 0.066], size: [0.15, finHeight - 0.10, 0.024], radius: 0.070, material: luminous(lilacLight, intensity: 0.3), parent: fin)
            let eye = Entity()
            eye.name = "led-eye-\(index)"
            eye.position = [side * 0.245, 0.06, 0.426]
            head.addChild(eye)
            rounded("cyan-eye-pill", at: .zero, size: [0.155, 0.285, 0.025], radius: 0.072, material: luminous(cyan, intensity: 1.1), parent: eye)
            eyes.append(eye)
            let cheek = rounded("cheek-pixel-\(index)", at: [side * 0.405, -0.175, 0.425], size: [0.12, 0.047, 0.018], radius: 0.022, material: cheekMaterial("#6ea8ff"), parent: head)
            cheeks.append(cheek)
        }
        smile.name = "led-smile"
        head.addChild(smile)
        let smilePoints: [SIMD3<Float>] = (0...24).map { index in
            let t = Float(index) / 24
            let x: Float = (t - 0.5) * 0.23
            let y: Float = -0.18 - sin(t * .pi) * 0.055
            return SIMD3<Float>(x, y, 0.428)
        }
        let smileMesh = BotGeometry.tube(points: smilePoints, radii: smilePoints.map { _ in 0.011 })
        smile.addChild(ModelEntity(mesh: smileMesh, materials: [luminous(cyan, intensity: 1.0)]))
        surprise.name = "surprised-led-mouth"
        head.addChild(surprise)
        oval("small-o-mouth", at: [0, -0.21, 0.426], size: [0.034, 0.044, 0.014], material: luminous(cyan, intensity: 1), parent: surprise)
        surprise.isEnabled = false
    }

    private func buildTail() {
        tail.position = [0.28, 0.44, -0.12]
        body.addChild(tail)
        var points: [SIMD3<Float>] = []
        for index in 0...28 {
            let t = Float(index) / 28
            let x: Float = 0.08 + sin(t * 1.6) * 0.62
            let y: Float = -0.09 * sin(t * .pi) + t * t * 0.33
            points.append(SIMD3<Float>(x, y, -0.06))
        }
        let cable = ModelEntity(mesh: BotGeometry.tube(points: points, radii: points.map { _ in 0.034 }), materials: [ceramic(lilac, roughness: 0.4)])
        cable.name = "curved-flexible-cable"
        tail.addChild(cable)
        for index in [5, 12, 19, 25] {
            oval("cable-connector", at: points[index], size: [0.045, 0.043, 0.043], material: ceramic(jointColor, metallic: 0.3), parent: tail)
        }
        if let end = points.last {
            oval("tail-tip-shell", at: end, size: [0.105, 0.10, 0.09], material: ceramic(ivory), parent: tail)
            oval("tail-tip-beacon", at: end + SIMD3<Float>(0, 0.012, 0.044), size: [0.075, 0.075, 0.052], material: luminous(lilacLight, intensity: 0.65), parent: tail)
        }
    }

    private func lightStudio() {
        let key = DirectionalLight()
        key.name = "warm-studio-key"
        key.light.intensity = 2600
        key.light.color = BotColor(red: 1, green: 0.94, blue: 0.85, alpha: 1)
        key.look(at: [0, 1, 0], from: [-3, 5, 5], relativeTo: nil)
        scene.addChild(key)
        let fill = DirectionalLight()
        fill.name = "soft-studio-fill"
        fill.light.intensity = 1200
        fill.light.color = BotColor(red: 0.81, green: 0.88, blue: 1, alpha: 1)
        fill.look(at: [0, 1, 0], from: [4, 2, 3], relativeTo: nil)
        scene.addChild(fill)
        let rim = DirectionalLight()
        rim.name = "lavender-rim-light"
        rim.light.intensity = 1800
        rim.light.color = BotColor(red: 0.83, green: 0.77, blue: 1, alpha: 1)
        rim.look(at: [0, 1, 0], from: [1, 4, -4], relativeTo: nil)
        scene.addChild(rim)
    }

    func apply(_ state: BodyState, animated: Bool) {
        let wasAnimated = lastAnimated
        lastAnimated = animated
        if !animated && wasAnimated { rest() }
        let duration: TimeInterval = animated ? 0.32 : 0
        let motionChanged = wasAnimated != animated
        if lastState?.pan != state.pan || lastState?.tilt != state.tilt || motionChanged {
            let pan = bounded(state.pan, limit: 60) * .pi / 180
            let tilt = bounded(state.tilt, limit: 30) * .pi / 180
            headPose = headJoint.transform
            headPose.rotation = simd_quatf(angle: -pan * 0.48, axis: [0, 1, 0]) * simd_quatf(angle: -tilt * 0.55, axis: [1, 0, 0])
            move(headJoint, to: headPose, duration: duration)
        }
        if finRotations.count != 2 { finRotations = [simd_quatf(), simd_quatf()] }
        let fins = [(leftFin, Float(-1), state.earLeft), (rightFin, Float(1), state.earRight)]
        for (index, entry) in fins.enumerated() {
            let (fin, side, angle) = entry
            let previous = index == 0 ? lastState?.earLeft : lastState?.earRight
            if previous != angle || motionChanged {
                var transform = fin.transform
                let perk = bounded(angle, limit: 60) * .pi / 180
                let restAngle: Float = side < 0 ? 0.25 : -0.62
                transform.rotation = simd_quatf(angle: restAngle + side * perk * 0.23, axis: [0, 0, 1]) * simd_quatf(angle: perk * 0.44, axis: [1, 0, 0])
                finRotations[index] = transform.rotation
                move(fin, to: transform, duration: duration)
            }
        }
        if lastState?.tail != state.tail || motionChanged {
            tailRotation = simd_quatf(angle: bounded(state.tail, limit: 60) * .pi / 180 * 0.46, axis: [0, 0, 1])
            var tailTransform = tail.transform
            tailTransform.rotation = tailRotation
            move(tail, to: tailTransform, duration: duration)
        }
        if state.mood != lastState?.mood {
            switch state.mood {
            case "pleased": eyeHeight = 0.60
            case "sleepy": eyeHeight = 0.15
            case "surprised": eyeHeight = 1.20
            case "alert": eyeHeight = 1.08
            default: eyeHeight = 1
            }
            for (index, eye) in eyes.enumerated() {
                eye.scale = [1, eyeHeight * (state.mood == "curious" && index == 1 ? 0.68 : 1), 1]
                eye.orientation = simd_quatf(angle: state.mood == "listening" ? Float(index == 0 ? -0.08 : 0.08) : 0, axis: [0, 0, 1])
            }
            surprise.isEnabled = state.mood == "surprised"
            smile.isEnabled = !surprise.isEnabled
            smile.scale = state.mood == "pleased" ? [1.18, 1, 1] : [1, 1, 1]
        }
        if state.cheekHex != lastState?.cheekHex {
            let material = cheekMaterial(state.cheekHex)
            for cheek in cheeks { cheek.model?.materials = [material] }
        }
        if !state.gesture.isEmpty && state.gesture != lastState?.gesture {
            currentGesture = state.gesture
            gestureTime = 0
        } else if state.gesture.isEmpty {
            currentGesture = ""
        }
        lastState = state
    }

    func idle(at time: Float) {
        let delta = max(0, min(time - lastIdleTime, 0.1))
        lastIdleTime = time
        gestureTime += delta
        body.position.y = sin(time * 1.7) * 0.009
        body.orientation = simd_quatf(angle: -0.10 + sin(time * 0.75) * 0.016, axis: [0, 1, 0])
        let blinkTime = time.truncatingRemainder(dividingBy: 5.2)
        let blink: Float = blinkTime > 4.94 ? max(0.08, abs(blinkTime - 5.07) / 0.13) : 1
        for (index, eye) in eyes.enumerated() {
            let curious: Float = lastState?.mood == "curious" && index == 1 ? 0.68 : 1
            eye.scale.y = eyeHeight * blink * curious
        }
        let gesturing = gestureTime < 1.25
        if gesturing && currentGesture == "wag" {
            tail.orientation = tailRotation * simd_quatf(angle: sin(gestureTime * 18) * 0.23, axis: [0, 0, 1])
        } else {
            tail.orientation = tailRotation * simd_quatf(angle: sin(time * 1.7) * 0.018, axis: [0, 0, 1])
        }
        if gesturing && (currentGesture == "nod" || currentGesture == "shake") {
            let axis: SIMD3<Float> = currentGesture == "nod" ? [1, 0, 0] : [0, 1, 0]
            let amount = sin(gestureTime * 12) * 0.10 * max(0, 1 - gestureTime / 1.25)
            head.orientation = simd_quatf(angle: amount, axis: axis)
        } else {
            head.orientation = simd_quatf()
        }
    }

    func rest() {
        body.position.y = 0
        body.orientation = simd_quatf(angle: -0.10, axis: [0, 1, 0])
        head.orientation = simd_quatf()
        for entity in [headJoint, leftFin, rightFin, tail] { entity.stopAllAnimations(recursive: false) }
        if lastState != nil { headJoint.transform = headPose }
        for (index, fin) in [leftFin, rightFin].enumerated() where finRotations.indices.contains(index) { fin.orientation = finRotations[index] }
        tail.orientation = tailRotation
        for (index, eye) in eyes.enumerated() {
            let curious: Float = lastState?.mood == "curious" && index == 1 ? 0.68 : 1
            eye.scale.y = eyeHeight * curious
        }
        lastIdleTime = 0
    }

    private func move(_ entity: Entity, to transform: Transform, duration: TimeInterval) {
        if duration > 0 {
            entity.move(to: transform, relativeTo: entity.parent, duration: duration, timingFunction: .easeInOut)
        } else {
            entity.stopAllAnimations(recursive: false)
            entity.transform = transform
        }
    }

    private func bounded(_ value: Double, limit: Double) -> Float {
        Float(value.isFinite ? min(max(value, -limit), limit) : 0)
    }

    private func cheekMaterial(_ hex: String) -> PhysicallyBasedMaterial {
        let rgb = Color.rgb(hex: hex) ?? (red: 0.43, green: 0.66, blue: 1)
        let color = BotColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        return luminous(color, intensity: 0.9)
    }
}

@MainActor
private enum BotGeometry {
    static func tube(points: [SIMD3<Float>], radii: [Float]) -> MeshResource {
        let columns = 16
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in points.indices {
            let before = points[max(index - 1, 0)]
            let after = points[min(index + 1, points.count - 1)]
            let tangent = simd_normalize(after - before)
            let reference: SIMD3<Float> = abs(tangent.z) < 0.9 ? [0, 0, 1] : [0, 1, 0]
            let across = simd_normalize(simd_cross(tangent, reference))
            let normal = simd_normalize(simd_cross(across, tangent))
            for column in 0..<columns {
                let angle = Float(column) / Float(columns) * 2 * .pi
                let outward = cos(angle) * across + sin(angle) * normal
                vertices.append(points[index] + radii[index] * outward)
                normals.append(outward)
                if index < points.count - 1 {
                    let a = UInt32(index * columns + column)
                    let b = UInt32(index * columns + (column + 1) % columns)
                    let c = UInt32((index + 1) * columns + column)
                    let d = UInt32((index + 1) * columns + (column + 1) % columns)
                    indices += [a, c, b, b, c, d]
                }
            }
        }
        var descriptor = MeshDescriptor(name: "bot-cable-surface")
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: 0.01)
    }
}
