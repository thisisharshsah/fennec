import SwiftUI

/// First launch, or no creatures yet: the creature, one line about it, whether the hub is found,
/// and the way in, "Add a creature".
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                Spacer(minLength: Theme.Spacing.xl)
                ZStack {
                    MoodGlow(color: Theme.MoodColor.color(for: .neutral), animates: !reduceMotion, diameter: 300)
                    CreatureFace(state: BodyState())
                        .frame(width: 240, height: 240)
                }
                .frame(height: 260)
                .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.s) {
                    Text("Meet your creature")
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("A small desk companion that hears, sees and feels the room, and shows how it feels with its ears, tail and glowing cheeks.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

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
