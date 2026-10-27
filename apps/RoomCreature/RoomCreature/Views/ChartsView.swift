import SwiftUI

/// One creature's history: a time range, a big chart with min / average / max, and the metrics to pick from.
/// Older data comes from the hub's log; the newest minutes are filled in live.
struct ChartsView: View {
    @Environment(AppModel.self) private var model
    let unitID: String
    @State private var metric: Metric = .temperature
    @State private var range: HistoryRange = .hour

    var body: some View {
        let unit = model.store.unitsByID[unitID]
        let points = points(unit: unit)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                SensorChart(
                    metric: metric,
                    points: points,
                    events: range == .hour ? model.store.events(for: unitID, since: rangeStart) : [],
                    range: rangeStart...Date.now,
                    isLoading: isLoading,
                    axis: range.axis
                )
                .animation(.easeInOut(duration: 0.25), value: metric)
                .animation(.easeInOut(duration: 0.25), value: range)

                metricList(unit: unit)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: Theme.contentMaxWidth + 160)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("History")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: requestKey) {
            // ask now, then every minute while the page is open
            while !Task.isCancelled {
                model.client.send(.series(field: metric.field, seconds: range.seconds, unit: unitID, request: requestKey))
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: range) { Haptics.light() }
    }

    // MARK: Data

    private var requestKey: String { "\(unitID)|\(metric.field)|\(Int(range.seconds))" }
    private var rangeStart: Date { Date.now.addingTimeInterval(-range.seconds) }
    private var isLoading: Bool { model.store.series[requestKey] == nil }

    /// The hub's history, then live samples newer than its last point.
    private func points(unit: UnitState?) -> [(time: Date, value: Double)] {
        let logged = model.store.series[requestKey] ?? []
        let after = logged.last?.time ?? rangeStart
        let live = (unit?.samples ?? []).compactMap { sample -> (time: Date, value: Double)? in
            guard sample.time > after, let value = metric.value(in: sample) else { return nil }
            return (sample.time, value)
        }
        return (logged + live).filter { $0.time >= rangeStart }
    }

    // MARK: Metric list

    private func metricList(unit: UnitState?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(Metric.allCases.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 26 + Theme.Spacing.m)
                }
                Button {
                    Haptics.light()
                    withAnimation(.spring(duration: 0.35, bounce: 0.1)) { metric = item }
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: item.symbolName)
                            .foregroundStyle(item == metric ? Theme.accent : Theme.textSecondary)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(Theme.Text.body.weight(item == metric ? .semibold : .regular))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: Theme.Spacing.s)
                        Text(latestText(item, in: unit))
                            .font(Theme.Text.callout)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: "checkmark")
                            .font(Theme.Text.callout.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .opacity(item == metric ? 1 : 0)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, Theme.Spacing.m)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(latestText(item, in: unit))")
                .accessibilityAddTraits(item == metric ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func latestText(_ metric: Metric, in unit: UnitState?) -> String {
        let value = unit?.latest.flatMap(metric.value(in:))
        return value == nil ? "—" : "\(Formatting.number(value, digits: metric.fractionDigits)) \(metric.unit)"
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour, sixHours, day, week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 d"
        }
    }

    var seconds: Double {
        switch self {
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }

    var axis: SensorChart.Axis {
        switch self {
        case .hour: .minutes(15)
        case .sixHours: .hours(1)
        case .day: .hours(6)
        case .week: .days
        }
    }
}
