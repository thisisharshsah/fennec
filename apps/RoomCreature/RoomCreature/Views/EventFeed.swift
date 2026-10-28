import SwiftUI

struct EventFeed: View {
    let events: [RoomEvent]
    /// nil hides the header and the card (on the creature page the section switcher names it).
    var title: String? = "Events"
    /// Off on a creature's own page, where every row is that creature.
    var showsUnit = true
    var limit = 100

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let title {
                CardHeader(title, systemImage: "clock") {
                    if !events.isEmpty {
                        SecondaryText("latest first")
                    }
                }
            }
            if events.isEmpty {
                EmptyLine("Nothing has happened yet. Clap, knock or walk past.", systemImage: "moon.zzz")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events.prefix(limit)) { event in
                        EventRow(event: event, showsUnit: showsUnit)
                    }
                }
            }
        }
        .card()
    }
}

private struct EventRow: View {
    let event: RoomEvent
    let showsUnit: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text(event.time, format: .dateTime.hour().minute())
                .font(Theme.Text.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 42, alignment: .leading)
                .padding(.top, Theme.Spacing.s)
            IconBadge(systemName: event.symbolName, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(mainLine)
                    .font(Theme.Text.body.weight(event.text == nil ? .regular : .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detailLine)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private var mainLine: String {
        if let text = event.text, !text.isEmpty { return event.isNotice ? text : "“\(text)”" }
        return event.title
    }

    private var detailLine: String {
        var parts: [String] = []
        if event.text != nil { parts.append(event.title) }
        if showsUnit { parts.append(event.unit) }
        if let mm = event.distanceMm { parts.append("\(Formatting.number(mm, digits: 0)) mm") }
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        if event.isNotice { return Theme.MoodColor.color(for: .pleased) }
        return switch event.name {
        case "speech", "spoke": Theme.MoodColor.color(for: .curious)
        case "someone_in_front", "someone_left": Theme.MoodColor.color(for: .listening)
        case "looked_at", "looked_away": Theme.MoodColor.color(for: .surprised)
        case "waved", "thumbs_up", "open_palm", "nodded", "shook_head", "stretched": Theme.MoodColor.color(for: .curious)
        case "slouching", "sat_up": Theme.MoodColor.color(for: .alert)
        case "yawned", "eyes_heavy": Theme.MoodColor.color(for: .sleepy)
        case "clap", "knock", "moved": Theme.MoodColor.color(for: .alert)
        case "wifi_disconnected": Theme.negative
        case "wifi_connected", "boot": Theme.positive
        default: Theme.accent
        }
    }
}
