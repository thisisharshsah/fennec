import SwiftUI

/// Where a unit is connected, as an icon only: Wi-Fi (its bars show the signal), a USB cable, or
/// offline. The words ("Wi-Fi · ATT3arfv3R · strong") are for VoiceOver and the hover tip; Manage
/// shows the network itself.
struct ConnectionPill: View {
    let unit: UnitState
    /// Kept for callers that dropped the signal word on narrow cards; the icon carries it now.
    var showsQuality = true
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 28

    var body: some View {
        Image(systemName: symbol, variableValue: level)
            .symbolRenderingMode(.hierarchical)
            .font(Theme.Text.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.12), in: Circle())
            .help(text)
            .accessibilityElement()
            .accessibilityLabel(text)
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
            if let quality { parts.append(quality) }
            return parts.joined(separator: " · ")
        }
        return "USB cable"
    }

    private var tint: Color {
        if !unit.isConnected { return Theme.textSecondary }
        return onWifi ? Theme.positive : Theme.accent
    }
}
