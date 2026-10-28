import SwiftUI

struct ConnectionStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.client.status
        HStack(spacing: Theme.Spacing.xs + 2) {
            StatusDot(color: color(for: status))
            Text(status.text)
                .foregroundStyle(Theme.textPrimary)
            if let target = model.client.target {
                Text("· \(target.label)")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(Theme.Text.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hub \(status.text)")
    }

    private func color(for status: BridgeClient.Status) -> Color {
        switch status {
        case .connected: Theme.positive
        case .connecting: Theme.warning
        case .retrying: Theme.warning
        case .needsPairing: Theme.warning
        case .idle: Theme.inactive
        }
    }
}
