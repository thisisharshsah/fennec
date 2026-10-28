import SwiftUI

/// First launch, or no creatures yet: the creature, one line about it, whether the hub is found,
/// and the way in, "Add a creature".
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewMood: Mood = .curious

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                CreatureStage(state: previewState, animates: !reduceMotion, height: 280)
                    .padding(.top, Theme.Spacing.s)
                    .accessibilityLabel("Fennec is feeling \(previewMood.title.lowercased())")

                VStack(spacing: Theme.Spacing.s) {
                    Text("A little creature.\nA lot of personality.")
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("A curious little bot for your desk. It notices the room and comes to life with expressive antenna ears, a wiggly tail and glowing cheeks.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                moodPreview

                HubStatusRow()
                    .frame(maxWidth: 420)

                Button {
                    Haptics.medium()
                    model.navigator.startAdding()
                } label: {
                    Label("Add a creature", systemImage: "plus")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)

                Spacer(minLength: Theme.Spacing.l)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .screenBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.navigator.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var previewState: BodyState {
        var state = BodyState()
        state.mood = previewMood.rawValue
        state.cheekHex = Theme.MoodColor.hex(for: previewMood)
        switch previewMood {
        case .curious:
            state.earLeft = 20
            state.earRight = 5
            state.tilt = 8
            state.pan = -8
            state.tail = 16
        case .pleased:
            state.earLeft = 12
            state.earRight = 12
            state.tail = 25
        case .sleepy:
            state.earLeft = -22
            state.earRight = -22
            state.tilt = -10
        default:
            break
        }
        return state
    }

    private var moodPreview: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text("Try a mood")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
            FlowLayout(spacing: Theme.Spacing.s) {
                previewButton(.curious, title: "Curious", symbol: "sparkles")
                previewButton(.pleased, title: "Happy", symbol: "heart.fill")
                previewButton(.sleepy, title: "Sleepy", symbol: "moon.zzz.fill")
            }
        }
        .frame(maxWidth: 420)
    }

    private func previewButton(_ mood: Mood, title: String, symbol: String) -> some View {
        let selected = previewMood == mood
        return Button {
            Haptics.light()
            previewMood = mood
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.Text.chip)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .background(selected ? Theme.tintFill(mood.color) : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? mood.color.opacity(0.6) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(title.lowercased()) mood")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selected)
    }
}

/// "Looking for your hub…" → "Hub found on <name>", or after a while "No hub found" with a way to
/// type the address.
struct HubStatusRow: View {
    @Environment(AppModel.self) private var model
    @State private var gaveUp = false

    private enum Phase { case looking, found(String), missing }

    private var phase: Phase {
        if let name = model.hubName { return .found(name) }
        return gaveUp ? .missing : .looking
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            switch phase {
            case .looking:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                Text("Looking for your hub…")
                    .font(Theme.Text.callout)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            case .found(let name):
                IconBadge(systemName: "checkmark", tint: Theme.positive, size: 28)
                Text("Hub found on \(name)")
                    .font(Theme.Text.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            case .missing:
                IconBadge(systemName: "exclamationmark", tint: Theme.warning, size: 28)
                Text("No hub found: make sure the hub is running on your Mac")
                    .font(Theme.Text.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Manual address") { model.navigator.isShowingSettings = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Theme.accent)
            }
        }
        .card(padding: Theme.Spacing.m, radius: Theme.Radius.m)
        .animation(.easeInOut(duration: 0.3), value: model.hubName)
        .animation(.easeInOut(duration: 0.3), value: gaveUp)
        .task {
            try? await Task.sleep(for: .seconds(10))
            gaveUp = true
        }
    }
}
