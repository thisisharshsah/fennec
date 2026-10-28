import SwiftUI

/// A small live face in a disc tinted by the creature's mood. Offline creatures show a calm, greyed face.
struct CreatureThumbnail: View {
    let unit: UnitState
    var size: CGFloat = 64

    var body: some View {
        let state = unit.body ?? BodyState()
        let tint = unit.isConnected ? unit.mood.color : Theme.inactive
        ZStack {
            Circle()
                .fill(Theme.tintFill(tint))
            Circle()
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            CreatureFace(state: state, animates: unit.isConnected)
                .frame(width: size * 0.92, height: size * 0.92)
                .saturation(unit.isConnected ? 1 : 0.2)
                .opacity(unit.isConnected ? 1 : 0.7)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(.easeInOut(duration: 0.4), value: unit.mood)
        .accessibilityHidden(true)
    }
}

/// One known creature on Home: face, name, mood and where it is connected.
struct CreatureCard: View {
    let unit: UnitState
    let name: String
    /// From the persisted list, for creatures the hub has not reported this session.
    let lastSeen: Date?

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            CreatureThumbnail(unit: unit, size: 72)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(name)
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    ConnectionPill(unit: unit)
                }
                CreatureMoodLine(unit: unit, lastSeen: lastSeen)
            }
            Spacer(minLength: Theme.Spacing.s)
            Image(systemName: "chevron.right")
                .font(Theme.Text.callout.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        unit.isConnected ? "\(name), \(unit.mood.title), online" : "\(name), offline"
    }
}

/// "Pleased" with a mood dot, or "Offline · seen 5 minutes ago".
struct CreatureMoodLine: View {
    let unit: UnitState
    let lastSeen: Date?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs + 2) {
            if unit.isConnected {
                StatusDot(color: unit.mood.color, size: 8)
                Text(unit.body == nil ? "Waking up" : unit.mood.title)
            } else if let seen = unit.lastSeen ?? lastSeen {
                Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
            } else {
                Text("Not seen yet")
            }
        }
        .font(Theme.Text.callout)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// A compact sidebar row for the Mac.
struct CreatureSidebarRow: View {
    let unit: UnitState
    let name: String
    let lastSeen: Date?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            CreatureThumbnail(unit: unit, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Text.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                CreatureMoodLine(unit: unit, lastSeen: lastSeen)
                    .font(Theme.Text.caption)
            }
            Spacer(minLength: 0)
            StatusDot(color: unit.isConnected ? Theme.positive : Theme.inactive)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// A hub helper that is not a creature (microphone, ear, voice): one quiet line.
struct OtherDeviceRow: View {
    let unit: UnitState

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconBadge(systemName: symbol, tint: unit.isConnected ? Theme.accent : Theme.inactive, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.id)
                    .font(Theme.Text.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                SecondaryText(kind)
            }
            Spacer(minLength: Theme.Spacing.s)
            Text(unit.isConnected ? "Online" : "Offline")
                .font(Theme.Text.caption)
                .foregroundStyle(unit.isConnected ? Theme.positive : Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var kind: String {
        if unit.hasMicrophone { return "Microphone" }
        if unit.id.contains("voice") { return "Voice" }
        if unit.id.contains("ear") { return "Listener" }
        return "Device"
    }

    private var symbol: String {
        if unit.hasMicrophone || unit.id.contains("ear") { return "mic" }
        if unit.id.contains("voice") { return "speaker.wave.2" }
        return "cpu"
    }
}
