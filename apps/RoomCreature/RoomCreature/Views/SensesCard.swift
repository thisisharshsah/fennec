import SwiftUI

/// One creature's live readings as stat tiles with ten-minute sparklines.
struct SensesCard: View {
    let unit: UnitState
    /// On the creature page the section switcher already names it: drop the card and the title.
    var embedded = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: Theme.Spacing.m)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if !embedded {
                CardHeader("Senses", systemImage: "sensor") { updatedNote }
            }
            if unit.latest == nil {
                EmptyLine(unit.isConnected ? "Waiting for the first reading…" : "No readings while it is offline.", systemImage: "sensor")
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                    ForEach(Metric.allCases) { metric in
                        StatTile(
                            title: metric.title,
                            value: Formatting.number(unit.latest.flatMap(metric.value(in:)), digits: metric.fractionDigits),
                            unit: metric.unit,
                            history: unit.samples.compactMap { sample in
                                metric.value(in: sample).map { (sample.time, $0) }
                            }
                        )
                    }
                    StatTile(
                        title: "Heading",
                        value: Formatting.number(unit.latest?.heading, digits: 0),
                        unit: Formatting.compassPoint(unit.latest?.heading),
                        history: []
                    )
                    StatTile(
                        title: "Motion",
                        value: unit.latest.map { $0.isMoving ? "Moving" : "Still" } ?? "—",
                        unit: "",
                        history: []
                    )
                }
            }
        }
        .modifier(CardIf(enabled: !embedded))
    }

    @ViewBuilder
    private var updatedNote: some View {
        if let latest = unit.latest {
            Text("updated \(Text(latest.time, style: .relative)) ago")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }
}

struct CardIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.card() } else { content }
    }
}
