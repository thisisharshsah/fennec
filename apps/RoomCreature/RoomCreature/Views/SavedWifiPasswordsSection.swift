import SwiftUI

/// Settings section listing the Wi-Fi passwords remembered from creature setups, with per-item delete.
/// Reloads whenever `reloadKey` changes (the parent flips it when the setup sheet closes).
struct SavedWifiPasswordsSection: View {
    var reloadKey: Bool = false
    @State private var saved: [SavedWifiPassword] = []

    var body: some View {
        Section {
            if saved.isEmpty {
                SecondaryText("No saved passwords yet", font: Theme.Text.body)
            }
            ForEach(saved) { item in
                HStack(spacing: Theme.Spacing.m) {
                    IconBadge(systemName: "key.fill", tint: Theme.textSecondary, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.ssid)
                            .foregroundStyle(Theme.textPrimary)
                        if let date = item.savedAt {
                            SecondaryText("Saved \(date.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        forget(item)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Forget password for \(item.ssid)")
                }
                .swipeActions(edge: .trailing) {
                    Button("Forget", role: .destructive) { forget(item) }
                }
            }
        } header: {
            Label("Saved Wi-Fi passwords", systemImage: "key")
        } footer: {
            Text("Kept in this device's Keychain after a creature joins a network, so the next creature can reuse them. They never leave the device except to the creature you are setting up.")
        }
        .task(id: reloadKey) { saved = WifiPasswordStore.all() }
    }

    private func forget(_ item: SavedWifiPassword) {
        WifiPasswordStore.forget(item.ssid)
        saved.removeAll { $0.ssid == item.ssid }
    }
}
