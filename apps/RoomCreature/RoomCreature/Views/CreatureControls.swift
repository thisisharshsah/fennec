import SwiftUI

struct CreatureControls: View {
    @Environment(AppModel.self) private var model
    let unitID: String
    let state: BodyState

    @State private var pan: Double = 0
    @State private var tilt: Double = 0
    @State private var isDragging = false
    @State private var lastGesture: Gesture?

    private var isConnected: Bool { model.client.status == .connected }
    private var currentMood: Mood { Mood(rawValue: state.mood) ?? .neutral }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            moodRow
            gestureRow
            lookCard
                .padding(.horizontal, Theme.Spacing.l)
        }
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.2), value: isConnected)
        .onAppear(perform: syncSliders)
        .onChange(of: state.pan) { syncSliders() }
        .onChange(of: state.tilt) { syncSliders() }
    }

    // MARK: Mood chips

    private var moodRow: some View {
        FlowLayout(spacing: Theme.Spacing.s) {
            ForEach(Mood.allCases) { mood in
                MoodChip(mood: mood, isSelected: mood == currentMood) {
                    guard mood != currentMood else { return }
                    Haptics.light()
                    model.client.send(.express(mood, unit: unitID))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: currentMood)
        .accessibilityLabel("Mood")
    }

    // MARK: Gesture buttons

    private var gestureRow: some View {
        HStack(spacing: 0) {
            ForEach(Gesture.allCases) { gesture in
                GestureButton(gesture: gesture, isActive: state.gesture == gesture.rawValue) {
                    Haptics.light()
                    lastGesture = gesture
                    model.client.send(.gesture(gesture, unit: unitID))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .accessibilityLabel("Gestures")
    }

    // MARK: Look sliders

    private var lookCard: some View {
        VStack(spacing: Theme.Spacing.m) {
            CardHeader("Look", systemImage: "eyes") {
                if !state.hasServos {
                    SecondaryText("virtual servos")
                }
            }
            lookSlider("Pan", value: $pan, range: -60...60)
            lookSlider("Tilt", value: $tilt, range: -30...30)
        }
        .card()
    }

    private func lookSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(title)
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 36, alignment: .leading)
            Slider(value: value, in: range, step: 1) { editing in
                isDragging = editing
                if !editing {
                    model.client.send(.lookAt(pan: pan, tilt: tilt, unit: unitID))
                }
            }
            .tint(Theme.accent)
            .accessibilityLabel(title)
            Text("\(Int(value.wrappedValue))°")
                .font(Theme.Text.callout)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
    }

    private func syncSliders() {
        guard !isDragging else { return }
        pan = state.pan
        tilt = state.tilt
    }
}

/// A pill with the mood's colour dot; filled with the mood tint when selected.
private struct MoodChip: View {
    let mood: Mood
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusDot(color: mood.color, size: 8)
                Text(mood.title)
                    .font(Theme.Text.chip)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(isSelected ? Theme.tintFill(mood.color) : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? mood.color.opacity(0.55) : Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mood.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// An icon in a circle with a caption underneath.
private struct GestureButton: View {
    let gesture: Gesture
    let isActive: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 48

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs + 2) {
                Image(systemName: gesture.symbolName)
                    .font(.system(size: side * 0.38, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textPrimary)
                    .frame(width: side, height: side)
                    .background(isActive ? Theme.tintFill(Theme.accent) : Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                Text(gesture.title)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gesture.title)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: isActive)
    }
}


/// Lays children out left to right, wrapping to new lines, each line centred.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
