import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the creature's eye sees right now, drawn as an outline: people, faces, hands, and where the
/// head points, over the live picture when the owner turns it on. Drawn from the creature's point of
/// view (not mirrored), so "left" is left on the card too. The header's menu sets when the eye runs.
struct VisionCard: View {
    @Environment(AppModel.self) private var model
    let frame: VisionFrame?
    let eye: EyeStatus?
    let name: String
    let unitID: String
    /// Off by default: the picture is sent only while this is on and the card is on screen.
    @State private var showsPicture = Self.launchShowsPicture

    /// Debug builds accept `-showPicture 1` so screenshots can show the picture without a tap.
    private static var launchShowsPicture: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "showPicture")
        #else
        false
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = frame.flatMap { $0.isStale(at: context.date) ? nil : $0 }
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                CardHeader("What \(name) sees", systemImage: "eye") { modeMenu(live: live != nil) }
                if let live {
                    scene(live)
                    facts(live, at: context.date)
                    Toggle(isOn: $showsPicture) {
                        Label("Show picture", systemImage: "video")
                            .font(Theme.Text.callout)
                    }
                    .tint(Theme.accent)
                    SecondaryText(showsPicture
                        ? "Live from the camera, to this device only while this is on. The hub never keeps pictures."
                        : "An outline only. Turn on the picture to see the camera itself.")
                } else {
                    EmptyLine(waitingText, systemImage: waitingSymbol)
                }
            }
            .card()
        }
        .onChange(of: showsPicture) { _, on in
            model.client.send(.picture(on))
            if !on { model.store.dropPicture(for: unitID) }
        }
        .onChange(of: model.isHubConnected) { _, connected in
            if connected && showsPicture { model.client.send(.picture(true)) }   // a new connection starts unsubscribed
        }
        .onAppear {
            if showsPicture { model.client.send(.picture(true)) }
        }
        .onDisappear {
            if showsPicture { model.client.send(.picture(false)) }
            showsPicture = false
            model.store.dropPicture(for: unitID)
        }
    }

    // MARK: When the eye runs

    private var mode: EyeStatus.Mode { eye?.mode ?? .off }

    private func modeMenu(live: Bool) -> some View {
        Menu {
            Picker("Eye", selection: Binding(get: { mode }, set: { model.client.send(.eye(mode: $0)) })) {
                ForEach(EyeStatus.Mode.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            Divider()
            Text(mode.explanation)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                StatusDot(color: live ? Theme.positive : Theme.inactive, size: 6)
                Text(live ? "\(mode.title) · live" : mode.title)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(Theme.Text.chip)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .disabled(!model.isHubConnected)
        .accessibilityLabel("Eye: \(mode.title)")
    }

    private var waitingText: String {
        switch mode {
        case .off: "The eye is off. The camera is not in use."
        case .auto: eye?.running == true ? "Starting the camera…" : "Waiting for someone at the desk. The camera turns on when \(name) feels you there."
        case .on: eye?.running == true ? "Starting the camera…" : "The eye could not start. Check the camera on the computer it runs on."
        }
    }

    private var waitingSymbol: String {
        switch mode {
        case .off: "eye.slash"
        case .auto: "person.crop.circle.badge.clock"
        case .on: "video"
        }
    }

    // MARK: The live picture

    @ViewBuilder
    private var picture: some View {
        if showsPicture, let live = model.store.pictures[unitID], let image = Self.image(live.jpeg) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if showsPicture {
            ProgressView()
        }
    }

    private static func image(_ jpeg: Data) -> Image? {
        #if os(iOS)
        UIImage(data: jpeg).map { Image(uiImage: $0) }
        #else
        NSImage(data: jpeg).map { Image(nsImage: $0) }
        #endif
    }

    // MARK: The outline

    private func scene(_ frame: VisionFrame) -> some View {
        Canvas { context, size in
            func place(_ r: CGRect) -> CGRect {
                // Vision: 0..1, origin bottom left. Drawn with origin top left.
                CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height,
                       width: r.width * size.width, height: r.height * size.height)
            }
            for body in frame.bodies {
                let path = Path(roundedRect: place(body), cornerRadius: Theme.Radius.s)
                context.fill(path, with: .color(Theme.positive.opacity(0.12)))
                context.stroke(path, with: .color(Theme.positive), lineWidth: 2)
            }
            for hand in frame.hands {
                context.stroke(Path(roundedRect: place(hand), cornerRadius: Theme.Radius.s),
                               with: .color(Theme.MoodColor.color(for: .curious)), lineWidth: 2)
            }
            for face in frame.faces {
                let path = Path(ellipseIn: place(face.rect))
                let looking = face.looking && frame.isLooking         // the eye's steady decision, as in the chip
                context.stroke(path, with: .color(looking ? Theme.warning : Theme.inactive), lineWidth: 2)
            }
            if let aim = frame.aim, frame.isPresent {
                let x = (aim + 1) / 2 * size.width
                var line = Path()
                line.move(to: CGPoint(x: size.width / 2, y: size.height))
                line.addLine(to: CGPoint(x: x, y: size.height * 0.1))
                context.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                context.fill(Path(ellipseIn: CGRect(x: x - 5, y: size.height * 0.1 - 5, width: 10, height: 10)), with: .color(Theme.accent))
            }
            // the creature, at the bottom middle, where the eye looks out from
            let base = CGRect(x: size.width / 2 - 7, y: size.height - 14, width: 14, height: 14)
            context.fill(Path(ellipseIn: base), with: .color(Theme.accent))
        }
        .aspectRatio(frame.aspect, contentMode: .fit)
        .background { picture }
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .center) {
            if frame.people == 0 && !showsPicture {
                SecondaryText("Nobody in view", font: Theme.Text.callout)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary(frame))
    }

    // MARK: Facts under the outline

    /// One row of chips, or a column when the row does not fit (narrow phones, large text).
    private func facts(_ frame: VisionFrame, at now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                chips(frame, at: now)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                chips(frame, at: now)
            }
        }
    }

    @ViewBuilder
    private func chips(_ frame: VisionFrame, at now: Date) -> some View {
        fact(frame.isLooking ? "Looking" : (frame.isPresent ? "Not looking" : "Away"),
             systemImage: frame.isLooking ? "eye.fill" : (frame.isPresent ? "eye.slash" : "person.fill.xmark"),
             tint: frame.isLooking ? Theme.warning : Theme.textSecondary)
        if frame.isPresent, let pan = frame.pan {
            fact(headTurn(pan), systemImage: pan < 0 ? "arrow.turn.up.left" : "arrow.turn.up.right", tint: Theme.accent)
        }
        if frame.isPresent, let since = frame.arrivedAt {
            fact(Formatting.duration(now.timeIntervalSince(since)), systemImage: "clock", tint: Theme.textSecondary)
        }
        if frame.isPresent, frame.posture == "slouching" {
            fact("Slouching", systemImage: "arrow.down.to.line", tint: Theme.MoodColor.color(for: .alert))
        } else if frame.isPresent, frame.posture == "close" {
            fact("Close to screen", systemImage: "arrow.down.right.and.arrow.up.left", tint: Theme.MoodColor.color(for: .alert))
        }
        if frame.isPresent, frame.isTired {
            fact("Tired", systemImage: "zzz", tint: Theme.MoodColor.color(for: .sleepy))
        }
        if let sign = frame.sign.flatMap(Self.signs) {
            fact(sign.text, systemImage: sign.symbol, tint: Theme.MoodColor.color(for: .curious))
        }
    }

    private func fact(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Text.chip)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(Theme.tintFill(tint), in: Capsule())
    }

    private static func signs(_ name: String) -> (text: String, symbol: String)? {
        switch name {
        case "waved": ("Wave", "hand.wave.fill")
        case "thumbs_up": ("Yes", "hand.thumbsup.fill")
        case "open_palm": ("Not now", "hand.raised.fill")
        case "nodded": ("Nod: yes", "checkmark.circle.fill")
        case "shook_head": ("Shake: no", "xmark.circle.fill")
        case "stretched": ("Stretch", "figure.arms.open")
        case "yawned": ("Yawn", "zzz")
        case "eyes_heavy": ("Heavy eyes", "zzz")
        default: nil
        }
    }

    private func headTurn(_ pan: Int) -> String {
        abs(pan) < 3 ? "Ahead" : "\(abs(pan))° \(pan < 0 ? "left" : "right")"
    }

    private func accessibilitySummary(_ frame: VisionFrame) -> String {
        if frame.people == 0 { return "Nobody in view" }
        let who = frame.people == 1 ? "One person" : "\(frame.people) people"
        return "\(who) in view, \(frame.isLooking ? "looking at \(name)" : "not looking at \(name)")"
    }
}
