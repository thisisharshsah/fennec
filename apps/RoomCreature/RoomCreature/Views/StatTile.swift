import Charts
import SwiftUI

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    /// Recent samples for the sparkline; empty hides it.
    let history: [(time: Date, value: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Text.statValue)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Group {                                   // same height with or without a sparkline, so rows align
                if history.count >= 2 {
                    Sparkline(points: history)
                } else {
                    Color.clear
                }
            }
            .frame(height: Theme.sparklineHeight)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value) \(unit)")
    }
}

/// A tiny axis-free line of the last ten minutes.
private struct Sparkline: View {
    let points: [(time: Date, value: Double)]

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Value", point.value))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: Theme.chartLineWidth, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .accessibilityHidden(true)
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 0.5)
        return (low - pad)...(high + pad)
    }
}
