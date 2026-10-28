import SwiftUI

// MARK: - Page

/// One creature's conversation on its own page: bubbles, newest at the bottom, a composer below.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let initialID: String
    @State private var filter: MessageTopic?

    private var unitID: String { model.store.registry.currentID(for: initialID) }
    private var name: String { model.store.registry.name(for: unitID) }

    var body: some View {
        let messages = model.store.messages.messages(for: unitID)
        let shown = ConversationThread.filtered(messages, by: filter)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ConversationThread(messages: shown, name: name, filter: filter)
                    Color.clear.frame(height: 1).id(ConversationThread.endID)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.m)
                .frame(maxWidth: Theme.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refreshMessages() }
            .onChange(of: shown.last?.id) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ConversationThread.endID, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(unitID: unitID, name: name)
        }
        .screenBackground()
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                ConversationTitle(unit: model.store.unit(unitID), name: name)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                ConversationFilterMenu(filter: $filter)
            }
        }
        .onAppear { model.store.messages.markRead(unitID) }
        .onChange(of: model.store.messages.unreadCount(for: unitID)) { model.store.messages.markRead(unitID) }
    }
}

/// Face and name in the navigation bar of a conversation.
private struct ConversationTitle: View {
    let unit: UnitState
    let name: String

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            CreatureThumbnail(unit: unit, size: 28)
            Text(name)
                .font(Theme.Text.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Filter

/// All, or one kind of message. Owner replies show under All only.
struct ConversationFilterMenu: View {
    @Binding var filter: MessageTopic?

    var body: some View {
        Menu {
            Picker("Show", selection: $filter) {
                Label("All", systemImage: "tray").tag(MessageTopic?.none)
                ForEach(MessageTopic.allCases) { topic in
                    Label(topic.filterTitle, systemImage: topic.systemImage).tag(MessageTopic?.some(topic))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel(filter.map { "Filter: \($0.filterTitle)" } ?? "Filter: All")
        .help("Filter messages")
    }
}

// MARK: - Thread

/// The bubbles of one conversation, with day separators. No scroll view of its own, so the creature
/// page can place it under its hero.
struct ConversationThread: View {
    static let endID = "conversation.end"
    /// Messages closer than this from the same side share one timestamp.
    private static let groupGap: TimeInterval = 5 * 60

    @Environment(AppModel.self) private var model
    let messages: [CreatureMessage]
    let name: String
    var filter: MessageTopic?

    static func filtered(_ messages: [CreatureMessage], by filter: MessageTopic?) -> [CreatureMessage] {
        guard let filter else { return messages }
        return messages.filter { $0.isFromCreature && $0.topic == filter }
    }

    var body: some View {
        if messages.isEmpty {
            ConversationEmpty(name: name, filter: filter)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Self.days(messages), id: \.start) { day in
                    DaySeparator(date: day.start)
                        .padding(.top, Theme.Spacing.l)
                        .padding(.bottom, Theme.Spacing.xs)
                    ForEach(Array(day.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? day.messages[index - 1] : nil
                        let next = index + 1 < day.messages.count ? day.messages[index + 1] : nil
                        MessageRow(
                            message: message,
                            showsTime: !Self.sameGroup(message, next),
                            showsIcon: !Self.sameGroup(message, next) || next?.kind != message.kind,
                            onDelete: { withAnimation(.easeOut(duration: 0.2)) { model.store.messages.delete(message.id) } }
                        )
                        .padding(.top, Self.sameGroup(previous, message) ? 2 : Theme.Spacing.m)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: messages.map(\.id))
        }
    }

    private static func sameGroup(_ first: CreatureMessage?, _ second: CreatureMessage?) -> Bool {
        guard let first, let second else { return false }
        return first.sender == second.sender
            && first.delivery == second.delivery
            && second.time.timeIntervalSince(first.time) < groupGap
    }

    private static func days(_ messages: [CreatureMessage]) -> [(start: Date, messages: [CreatureMessage])] {
        let calendar = Calendar.current
        var result: [(start: Date, messages: [CreatureMessage])] = []
        for message in messages {
            let start = calendar.startOfDay(for: message.time)
            if result.last?.start == start {
                result[result.count - 1].messages.append(message)
            } else {
                result.append((start, [message]))
            }
        }
        return result
    }
}

private struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(MessageTime.day(date))
            .font(Theme.Text.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.surfaceElevated, in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ConversationEmpty: View {
    let name: String
    let filter: MessageTopic?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            IconBadge(systemName: filter?.systemImage ?? "bubble.left.and.bubble.right", tint: Theme.accent, size: 56)
            Text(filter == nil ? "Nothing yet" : "No \(filter?.filterTitle.lowercased() ?? "") messages")
                .font(Theme.Text.title)
                .foregroundStyle(Theme.textPrimary)
            Text(filter == nil
                 ? "\(name) will tell you things here: greetings, break reminders, goodnight."
                 : "Choose All in the filter menu to see the whole conversation.")
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl)
        .padding(.horizontal, Theme.Spacing.l)
    }
}

// MARK: - Bubble

private struct MessageRow: View {
    let message: CreatureMessage
    let showsTime: Bool
    /// Only the last bubble of a run carries the kind icon, like an avatar.
    let showsIcon: Bool
    let onDelete: () -> Void

    private static let avatarSide: CGFloat = 26

    var body: some View {
        let mine = !message.isFromCreature
        VStack(alignment: mine ? .trailing : .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                if mine {
                    Spacer(minLength: Theme.Spacing.xxl * 1.5)
                    if message.delivery == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Theme.negative)
                            .accessibilityLabel("Not sent")
                    }
                    bubble(mine: true)
                } else {
                    if showsIcon {
                        IconBadge(systemName: message.symbolName, tint: kindTint, size: Self.avatarSide)
                    } else {
                        Color.clear.frame(width: Self.avatarSide, height: Self.avatarSide)
                    }
                    bubble(mine: false)
                    Spacer(minLength: Theme.Spacing.xxl * 1.5)
                }
            }
            if showsTime || message.delivery != .delivered {
                footer
                    .padding(mine ? .trailing : .leading, mine ? Theme.Spacing.xs : Self.avatarSide + Theme.Spacing.s + Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You" : message.topic.filterTitle), \(message.text), \(message.time.formatted(date: .omitted, time: .shortened))")
    }

    private func bubble(mine: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
        return Text(message.text)
            .font(Theme.Text.body)
            .foregroundStyle(mine ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.m + 2)
            .padding(.vertical, Theme.Spacing.s + 1)
            .background {
                if mine {
                    shape.fill(Theme.accent)
                } else {
                    shape.fill(Theme.surface)
                        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                }
            }
            .opacity(message.delivery == .sending ? 0.6 : 1)
            #if os(iOS)
            .contentShape(.contextMenuPreview, shape)
            #endif
            .contextMenu {
                Text(message.time.formatted(date: .complete, time: .shortened))
                Button {
                    copy(message.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private var footer: some View {
        switch message.delivery {
        case .delivered:
            SecondaryText(message.time.formatted(date: .omitted, time: .shortened), font: Theme.Text.caption2)
                .monospacedDigit()
        case .sending:
            SecondaryText("Sending", font: Theme.Text.caption2)
        case .failed:
            Text("Not delivered. The hub did not answer.")
                .font(Theme.Text.caption2)
                .foregroundStyle(Theme.negative)
        }
    }

    private var kindTint: Color {
        switch message.topic {
        case .said: Theme.accent
        case .greetings: Theme.MoodColor.color(for: .pleased)
        case .breaks: Theme.warning
        case .wellbeing: Theme.MoodColor.color(for: .alert)
        case .room: Theme.negative
        case .night: Theme.MoodColor.color(for: .curious)
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Composer

/// "Message <name>" field and send button, pinned under the conversation.
struct ChatComposer: View {
    @Environment(AppModel.self) private var model
    let unitID: String
    let name: String
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        model.isHubConnected && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            TextField(model.isHubConnected ? "Message \(name)" : "Not connected to the hub", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Text.body)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(!model.isHubConnected)
                .padding(.vertical, Theme.Spacing.s)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Theme.accent : Theme.inactive, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .animation(.easeInOut(duration: 0.15), value: canSend)
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l + 2, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .frame(maxWidth: Theme.contentMaxWidth)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func send() {
        guard canSend else { return }
        Haptics.light()
        model.sendMessage(text, to: unitID)
        text = ""
    }
}

// MARK: - Time formatting

enum MessageTime {
    /// "Today", "Yesterday", or the date.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Short time for a list row: the time today, else the day.
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
