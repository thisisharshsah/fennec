import SwiftUI

/// "Wi-Fi · ATT3arfv3R · strong" or "USB cable" or "Offline": where a unit is connected, at a glance.
struct ConnectionPill: View {
    let unit: UnitState
    /// Cards are narrow: drop the signal word there.
    var showsQuality = true

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol, variableValue: level)
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .lineLimit(1)
        }
        .font(Theme.Text.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var onWifi: Bool { unit.isConnected && unit.link == "wifi" }

    private var symbol: String {
        if !unit.isConnected { return "wifi.slash" }
        return onWifi ? "wifi" : "cable.connector"
    }

    private var level: Double {
        guard let dbm = unit.signalDBm else { return 1 }
        return min(1, max(0, Double(dbm + 90) / 50))
    }

    private var quality: String? {
        guard let dbm = unit.signalDBm else { return nil }
        switch dbm {
        case (-55)...: return "strong"
        case (-70)...: return "good"
        default: return "weak"
        }
    }

    private var text: String {
        if !unit.isConnected { return "Offline" }
        if onWifi {
            var parts = ["Wi-Fi"]
            if let ssid = unit.wifi?.ssid, !ssid.isEmpty { parts.append(ssid) }
            if showsQuality, let quality { parts.append(quality) }
            return parts.joined(separator: " · ")
        }
        return "USB cable"
    }

    private var tint: Color {
        if !unit.isConnected { return Theme.textSecondary }
        return onWifi ? Theme.positive : Theme.accent
    }
}
