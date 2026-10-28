import SwiftUI

/// The top of a creature's page: the live face in its mood glow, name, connection and status,
/// then the mood chips, gestures, Look sliders and the Say field.
struct CreatureHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let unit: UnitState
    let name: String
    /// Smaller face for the creature page, where sections sit below.
    var compact = false
    /// The live conversation beside the character (the creature page).
    var talks = false

    var body: some View {
        hero(unit: unit, state: unit.body ?? BodyState())
    }

    /// Mood chips, gestures, Look, and Say: the "Play" section of the creature page.
    struct Controls: View {
        @Environment(AppModel.self) private var model
        let unit: UnitState

        var body: some View {
            VStack(spacing: Theme.Spacing.l) {
                CreatureControls(unitID: unit.id, state: unit.body ?? BodyState())
                    .disabled(!unit.isConnected)
                if model.store.speechUnit != nil {
                    SayField()
                        .padding(.horizontal, Theme.Spacing.l)
                }
            }
        }
    }

    // MARK: Hero

    private func hero(unit: UnitState, state: BodyState) -> some View {
        let stage = CreatureStage(state: state, animates: unit.isConnected && !reduceMotion,
                                  height: talks ? 180 : compact ? 230 : 310)
            .saturation(unit.isConnected ? 1 : 0.25)
            .opacity(unit.isConnected ? 1 : 0.7)
        return VStack(spacing: compact ? Theme.Spacing.m : Theme.Spacing.l) {
            if talks {
                // the character on the left two fifths, the conversation on the rest
                GeometryReader { proxy in
                    let side = proxy.size.width * 0.4
                    HStack(alignment: .center, spacing: Theme.Spacing.s) {
                        stage
                            .frame(width: side, height: 250)
                            .clipped()
                            .accessibilityHidden(true)
                        LiveTalkPanel(unitID: unit.id, name: name, height: 250)
                            .frame(width: proxy.size.width - side - Theme.Spacing.s)
                    }
                }
                .frame(height: 250)
                .padding(.horizontal, Theme.Spacing.l)
            } else {
                stage
                    .padding(.top, compact ? 0 : Theme.Spacing.s)
            }
            VStack(spacing: Theme.Spacing.s) {
                if !compact {
                    Text(name)
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: Theme.Spacing.s) {
                    ConnectionPill(unit: unit)
                    Text(statusLine(unit: unit, state: state))
                        .font(Theme.Text.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .contentTransition(.numericText())
                }
                if !compact, let why = state.why, !why.isEmpty {
                    Text("because \(why)")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1), value: state)
        }
        .accessibilityElement(children: talks ? .contain : .combine)
        .accessibilityLabel("\(name). \(statusLine(unit: unit, state: state))")
    }

    // MARK: Status line  ("Listening · 27.6° · nobody in front")

    private func statusLine(unit: UnitState, state: BodyState) -> String {
        var parts: [String] = []
        if !unit.isConnected {
            if let seen = unit.lastSeen {
                return "Offline · last seen \(seen.formatted(.relative(presentation: .named)))"
            }
            return "Offline"
        }
        if unit.body == nil {
            parts.append("Waking up")
        } else {
            parts.append(state.mood.capitalized)
        }
        if let temperature = unit.latest?.temperature {
            parts.append("\(Formatting.number(temperature, digits: 1))°")
        }
        if let presence = presence(for: unit.id) {
            parts.append(presence)
        }
        return parts.joined(separator: " · ")
    }

    private func presence(for unitID: String) -> String? {
        let latest = model.store.events.first {
            $0.unit == unitID && ($0.name == "someone_in_front" || $0.name == "someone_left")
        }
        guard let latest else { return nil }
        return latest.name == "someone_in_front" ? "someone in front" : "nobody in front"
    }
}

/// A small stage keeps the character grounded while its cheek colour sets the mood.
struct CreatureStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let state: BodyState
    let animates: Bool
    let height: CGFloat

    private var motionAllowed: Bool { animates && !reduceMotion && scenePhase == .active }

    private var cheek: Color {
        Color(hex: state.cheekHex, fallback: Theme.MoodColor.color(for: .neutral))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, height * 1.2)
            ZStack {
                Circle()
                    .fill(Color.adaptive(light: "#EDE7FF", dark: "#27223C").opacity(0.65))
                    .frame(width: height * 0.76, height: height * 0.76)
                    .offset(y: height * 0.04)
                MoodGlow(color: cheek, animates: motionAllowed, diameter: height * 1.08)
                    .offset(y: height * 0.04)
                Ellipse()
                    .fill(Color.adaptive(light: "#746294", dark: "#000000").opacity(0.16))
                    .frame(width: height * 0.5, height: height * 0.055)
                    .blur(radius: height * 0.025)
                    .offset(y: height * 0.41)
                Image(systemName: "sparkle")
                    .font(.system(size: height * 0.055, weight: .medium))
                    .foregroundStyle(cheek.opacity(0.75))
                    .offset(x: width * 0.34, y: -height * 0.22)
                Circle()
                    .strokeBorder(cheek.opacity(0.4), lineWidth: 2)
                    .frame(width: height * 0.025, height: height * 0.025)
                    .offset(x: -width * 0.34, y: height * 0.12)
                CreatureFace(state: state, animates: motionAllowed)
                    .frame(width: width, height: height)
            }
            .frame(width: proxy.size.width, height: height)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fennec, feeling \(state.mood)")
    }
}

/// Soft radial glow behind the face in the creature's cheek colour. Breathes slowly unless motion is reduced.
struct MoodGlow: View {
    let color: Color
    let animates: Bool
    var diameter: CGFloat = 340

    var body: some View {
        Group {
            if animates {
                PhaseAnimator([false, true]) { phase in
                    glow.scaleEffect(phase ? 1.06 : 0.96)
                } animation: { _ in
                    .easeInOut(duration: 3.2)
                }
            } else {
                glow
            }
        }
        .animation(animates ? .spring(duration: 0.7, bounce: 0.1) : nil, value: color)
        .accessibilityHidden(true)
    }

    private var glow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.42), color.opacity(0.16), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.053)
    }
}
