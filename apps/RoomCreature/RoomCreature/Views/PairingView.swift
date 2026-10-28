import SwiftUI

/// Shown when the hub answers over the network but does not know this device yet: press the
/// creature's blue button, then Pair within a minute.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var autoPairTried = false
    #endif

    private var client: BridgeClient { model.client }
    private var canPair: Bool { client.status == .needsPairing && !client.pairing.isWaiting }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                ZStack {
                    MoodGlow(color: Theme.MoodColor.color(for: .listening), animates: !reduceMotion, diameter: 220)
                    CreatureFace(state: BodyState())
                        .frame(width: 170, height: 170)
                }
                .frame(height: 190)
                .accessibilityHidden(true)

                VStack(spacing: Theme.Spacing.s) {
                    Text("Pair this device")
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Press the blue button on your creature. Its ears perk up. Then tap Pair within a minute.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                statusCard
                    .frame(maxWidth: 420)

                Button {
                    Haptics.medium()
                    client.pair()
                } label: {
                    if client.pairing.isWaiting {
                        HStack(spacing: Theme.Spacing.s) {
                            ProgressView()
                                .tint(.white)
                            Text("Pairing…")
                        }
                    } else {
                        Label("Pair", systemImage: "link")
                    }
                }
                .buttonStyle(.primary)
                .disabled(!canPair)
                .keyboardShortcut(.defaultAction)

                Button("Not now") {
                    client.pairingPromptDismissed = true
                    dismiss()
                }
                .font(Theme.Text.callout)
                .tint(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.xxl)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .screenBackground()
        .interactiveDismissDisabled(client.pairing.isWaiting)
        #if DEBUG
        // `-autoPair 1` taps Pair once the hub asks for it (headless tests cannot tap).
        .task(id: client.status) {
            guard UserDefaults.standard.bool(forKey: "autoPair"), !autoPairTried, client.status == .needsPairing else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, client.status == .needsPairing else { return }
            autoPairTried = true
            client.pair()
        }
        #endif
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                if let refusal = client.pairing.refusal {
                    IconBadge(systemName: client.pairing.wrongHub ? "xmark.shield" : "exclamationmark", tint: client.pairing.wrongHub ? Theme.negative : Theme.warning, size: 28)
                    Text(refusal)
                        .font(Theme.Text.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if client.status != .needsPairing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                    Text("Reaching your hub… (\(client.status.text.lowercased()))")
                        .font(Theme.Text.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else if client.pairing.windowOpen {
                    IconBadge(systemName: "ear", tint: Theme.positive, size: 28)
                    Text("Your creature is listening for this device")
                        .font(Theme.Text.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    IconBadge(systemName: "hand.tap", tint: Theme.accent, size: 28)
                    Text("Waiting for the blue button")
                        .font(Theme.Text.callout)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
            }
            if let fingerprint = client.observedFingerprint {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "lock")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    Text("Hub \(client.target?.label ?? "") · \(HubCredentials.shortFingerprint(fingerprint))")
                        .font(Theme.Text.mono)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Encrypted connection to the hub")
            }
        }
        .card(padding: Theme.Spacing.m, radius: Theme.Radius.m)
        .animation(.easeInOut(duration: 0.3), value: client.pairing)
    }
}
