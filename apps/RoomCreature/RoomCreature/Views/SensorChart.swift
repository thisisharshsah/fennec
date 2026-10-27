import Charts
import SwiftUI

/// One metric over a time range: current value, the chart, and min / average / max underneath.
struct SensorChart: View {
    enum Axis: Equatable {
        case minutes(Int), hours(Int), days
    }

    let metric: Metric
    let points: [(time: Date, value: Double)]
    let events: [RoomEvent]
    let range: ClosedRange<Date>
    var isLoading = false
    var axis: Axis = .minutes(15)

    @State private var selected: (time: Date, value: Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            header
            Group {
                if points.count >= 2 {
                    chart
                } else {
                    VStack(spacing: Theme.Spacing.s) {
                        if isLoading { ProgressView().controlSize(.small) }
                        SecondaryText(isLoading ? "Loading history…" : "No \(metric.title.lowercased()) readings in this range yet.", font: Theme.Text.callout)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 220)
            if points.count >= 2 {
                stats
            }
        }
        .padding(Theme.Spacing.l)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Label(metric.title, systemImage: metric.symbolName)
                    .font(Theme.Text.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .labelStyle(.titleAndIcon)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Formatting.number(shown?.value, digits: metric.fractionDigits))
                        .font(Theme.Text.display)
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(metric.unit)
                        .font(Theme.Text.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            Text(shownTimeText)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    private var shown: (time: Date, value: Double)? { selected ?? points.last }

    /// A centred moving average for drawing only (sensors step in 0.1 units); stats use the raw points.
    private var smoothed: [(time: Date, value: Double)] {
        let half = max(1, points.count / 120)
        guard points.count > 2 * half + 1 else { return points }
        let values = points.map(\.value)
        var prefix = [0.0]
        for v in values { prefix.append(prefix.last! + v) }
        return points.indices.map { i in
            let lo = max(0, i - half), hi = min(points.count - 1, i + half)
            return (points[i].time, (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1))
        }
    }

    private var shownTimeText: String {
        guard let selected else { return "Now" }
        return selected.time.formatted(axis == .days ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute())
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(events) { event in
                RuleMark(x: .value("Event", event.time))
                    .foregroundStyle(Theme.textSecondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(Array(smoothed.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("Time", point.time),
                    yStart: .value("Base", yDomain.lowerBound),
                    yEnd: .value(metric.title, point.value)
                )
                .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", point.time), y: .value(metric.title, point.value))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.time))
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
                PointMark(x: .value("Selected", selected.time), y: .value(metric.title, selected.value))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: yDomain)
        .chartXAxis { xAxis }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().foregroundStyle(Theme.textSecondary)
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                                let x = drag.location.x - frame.origin.x
                                guard let time: Date = proxy.value(atX: x) else { return }
                                selected = points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
                            }
                            .onEnded { _ in selected = nil }
                    )
            }
        }
    }

    @AxisContentBuilder
    private var xAxis: some AxisContent {
        switch axis {
        case .minutes(let step):
            AxisMarks(values: .stride(by: .minute, count: step)) {
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.textSecondary)
            }
        case .hours(let step):
            AxisMarks(values: .stride(by: .hour, count: step)) {
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.textSecondary)
            }
        case .days:
            AxisMarks(values: .stride(by: .day)) {
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel(format: .dateTime.weekday(.abbreviated)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.25, metric.minimumSpan / 2)
        return (low - pad)...(high + pad)
    }

    // MARK: Stats

    private var stats: some View {
        let values = points.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)
        return HStack(spacing: 0) {
            stat("Min", values.min())
            Divider().frame(height: 28)
            stat("Average", average)
            Divider().frame(height: 28)
            stat("Max", values.max())
        }
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    private func stat(_ title: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("\(Formatting.number(value, digits: metric.fractionDigits)) \(metric.unit)")
                .font(Theme.Text.callout.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension Metric {
    /// Smallest y span worth showing, so flat lines do not exaggerate noise.
    var minimumSpan: Double {
        switch self {
        case .temperature: 1
        case .humidity: 4
        case .pressure: 2
        case .distance: 200
        case .soundLevel: 10
        }
    }
}
