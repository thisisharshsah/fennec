import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the creature's eye sees right now, drawn as an outline: people, faces, and where the head
/// points, over the live picture when the owner turns it on. Drawn from the creature's point of view
/// (not mirrored), so "left" is left on the card too.
struct VisionCard: View {
    @Environment(AppModel.self) private var model
    let frame: VisionFrame
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
            let stale = frame.isStale(at: context.date)
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                CardHeader("What \(name) sees", systemImage: "eye") {
                    HStack(spacing: Theme.Spacing.xs) {
                        StatusDot(color: stale ? Theme.inactive : Theme.positive, size: 6)
                        SecondaryText(stale ? "eye offline" : "live")
                    }
                }
                scene
                    .opacity(stale ? 0.35 : 1)
                    .overlay {
                        if stale {
                            SecondaryText("The eye is not sending. Start it on the computer it runs on.", font: Theme.Text.callout)
                                .multilineTextAlignment(.center)
                                .padding(Theme.Spacing.l)
                        }
                    }
                facts(at: context.date)
                    .opacity(stale ? 0.5 : 1)
                Toggle(isOn: $showsPicture) {
                    Label("Show picture", systemImage: "video")
                        .font(Theme.Text.callout)
                }
                .tint(Theme.accent)
                SecondaryText(showsPicture
                    ? "Live from the camera, to this device only while this is on. The hub never keeps pictures."
                    : "An outline only. Turn on the picture to see the camera itself.")
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

    private var scene: some View {
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
            if frame.people == 0 && !frame.isStale(at: .now) && !showsPicture {
                SecondaryText("Nobody in view", font: Theme.Text.callout)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Facts under the outline

    /// One row of chips, or a column when the row does not fit (narrow phones, large text).
    private func facts(at now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                chips(at: now)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                chips(at: now)
            }
        }
    }

    @ViewBuilder
    private func chips(at now: Date) -> some View {
        fact(frame.isLooking ? "Looking" : (frame.isPresent ? "Not looking" : "Away"),
             systemImage: frame.isLooking ? "eye.fill" : (frame.isPresent ? "eye.slash" : "person.fill.xmark"),
             tint: frame.isLooking ? Theme.warning : Theme.textSecondary)
        if frame.isPresent, let pan = frame.pan {
            fact(headTurn(pan), systemImage: pan < 0 ? "arrow.turn.up.left" : "arrow.turn.up.right", tint: Theme.accent)
        }
        if frame.isPresent, let since = frame.arrivedAt {
            fact(Formatting.duration(now.timeIntervalSince(since)), systemImage: "clock", tint: Theme.textSecondary)
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

    private func headTurn(_ pan: Int) -> String {
        abs(pan) < 3 ? "Ahead" : "\(abs(pan))° \(pan < 0 ? "left" : "right")"
    }

    private var accessibilitySummary: String {
        if frame.people == 0 { return "Nobody in view" }
        let who = frame.people == 1 ? "One person" : "\(frame.people) people"
        return "\(who) in view, \(frame.isLooking ? "looking at \(name)" : "not looking at \(name)")"
    }
}
