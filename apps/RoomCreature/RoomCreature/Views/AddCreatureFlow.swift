import SwiftUI

/// "Add creature": a short intro about what to do with the creature itself, then the Bluetooth
/// setup (CreatureSetupView, unchanged). When setup is done it closes and opens the new creature.
struct AddCreatureFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var introDone = false

    var body: some View {
        NavigationStack {
            Group {
                if introDone {
                    CreatureSetupView(onFinished: finished)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    AddCreatureIntro(reason: model.navigator.addReason) {
                        Haptics.medium()
                        withAnimation(.spring(duration: 0.4, bounce: 0.05)) { introDone = true }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 600, idealHeight: 680)
        #endif
    }

    private func finished(unitID: String?, ssid: String?) {
        Haptics.success()
        dismiss()
        if let unitID {
            model.navigator.open(unitID)
        } else {
            model.navigator.awaitArrival(onNetwork: ssid)
        }
    }
}

/// What to do physically before the app can find the creature.
private struct AddCreatureIntro: View {
    let reason: Navigator.AddReason
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                illustration
                    .padding(.top, Theme.Spacing.xl)

                VStack(spacing: Theme.Spacing.s) {
                    Text(headline)
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(subhead)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        IntroStep(number: index + 1, systemImage: step.symbol, text: step.text)
                    }
                }
                .card()

                Button(action: onContinue) {
                    Text("Continue")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .screenBackground()
        .navigationTitle("Add creature")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The creature with violet cheeks (setup mode) between a plug and Bluetooth waves.
    private var illustration: some View {
        let violet = Color(hex: "#b06cff")
        var setupFace = BodyState()
        setupFace.cheekHex = "#b06cff"
        setupFace.earLeft = 20
        setupFace.earRight = 20
        return HStack(spacing: Theme.Spacing.l) {
            IconBadge(systemName: "powerplug", tint: Theme.textSecondary, size: 48)
            ZStack {
                Circle().fill(Theme.tintFill(violet))
                CreatureFace(state: setupFace)
                    .frame(width: 130, height: 130)
            }
            .frame(width: 140, height: 140)
            IconBadge(systemName: "dot.radiowaves.left.and.right", tint: violet, size: 48)
        }
        .accessibilityHidden(true)
    }

    private var headline: String {
        switch reason {
        case .new: "Get it ready"
        case .changeWifi: "Choose a new network"
        }
    }

    private var subhead: String {
        switch reason {
        case .new: "Your creature needs to be in setup mode so this device can find it over Bluetooth."
        case .changeWifi(let name): "\(name) is restarting into setup mode. In a few seconds its cheeks turn violet."
        }
    }

    private var steps: [(symbol: String, text: String)] {
        switch reason {
        case .new:
            [
                ("powerplug", "Plug it in."),
                ("paintpalette", "If its cheeks are not violet, hold the blue button while pressing reset, for 3 seconds."),
                ("iphone.radiowaves.left.and.right", "Keep this device close by. Bluetooth needs to be on."),
            ]
        case .changeWifi:
            [
                ("paintpalette", "Wait for violet cheeks. If they do not turn violet within a minute, hold the blue button while pressing reset, for 3 seconds."),
                ("iphone.radiowaves.left.and.right", "Keep this device close by. Bluetooth needs to be on."),
            ]
        }
    }
}

private struct IntroStep: View {
    let number: Int
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            IconBadge(systemName: systemImage, tint: Theme.accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(number)")
                    .font(Theme.Text.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(text)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
