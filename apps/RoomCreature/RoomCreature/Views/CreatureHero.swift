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
        let cheek = Color(hex: state.cheekHex, fallback: Theme.MoodColor.color(for: .neutral))
        return VStack(spacing: compact ? Theme.Spacing.m : Theme.Spacing.l) {
            ZStack {
                MoodGlow(color: cheek, animates: !reduceMotion, diameter: compact ? 200 : 340)
                CreatureFace(state: state)
                    .frame(height: compact ? 150 : 280)
                    .frame(maxWidth: compact ? 210 : 380)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 160 : nil)
            .padding(.top, compact ? 0 : Theme.Spacing.s)
            VStack(spacing: Theme.Spacing.s) {
                if !compact {
                    Text(name)
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                }
                ConnectionPill(unit: unit)
                Text(statusLine(unit: unit, state: state))
                    .font(Theme.Text.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                if !compact, let why = state.why, !why.isEmpty {
                    Text("because \(why)")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .animation(.spring(duration: 0.4, bounce: 0.1), value: state)
        }
        .accessibilityElement(children: .combine)
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
        .animation(.spring(duration: 0.7, bounce: 0.1), value: color)
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
