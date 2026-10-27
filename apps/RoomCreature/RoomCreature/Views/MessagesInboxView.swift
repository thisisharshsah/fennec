import SwiftUI

/// Every creature's conversation: face, last message, time, unread dot. Tap to open one.
struct MessagesInboxView: View {
    @Environment(AppModel.self) private var model

    /// Creatures with messages, most recent first, then known creatures that have not said anything.
    private var unitIDs: [String] {
        let messages = model.store.messages
        var ids = messages.unitsByRecency.map { model.store.registry.currentID(for: $0) }
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        let quiet = model.store.registry.creatures.map(\.unitID).filter { !seen.contains($0) }
        return ids + quiet.sorted()
    }

    var body: some View {
        let ids = unitIDs
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                VStack(spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        NavigationLink(value: Navigator.Route.conversation(id)) {
                            InboxRow(unitID: id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                model.store.messages.markRead(id)
                            } label: {
                                Label("Mark as read", systemImage: "envelope.open")
                            }
                            .disabled(model.store.messages.unreadCount(for: id) == 0)
                        }
                        if index < ids.count - 1 {
                            Rectangle()
                                .fill(Theme.hairline)
                                .frame(height: 1)
                                .padding(.leading, InboxRow.thumbnail + Theme.Spacing.m)
                        }
                    }
                }
                .card(padding: Theme.Spacing.m, radius: Theme.Radius.l)
                SecondaryText("The last \(MessageStore.historyDays) days, kept by the hub. Read and deleted messages are remembered on this device.")
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refreshMessages() }
        .screenBackground()
        .largeNavigationTitle("Messages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.light()
                    model.store.messages.markAllRead()
                } label: {
                    Label("Mark all as read", systemImage: "checkmark.circle")
                }
                .disabled(model.store.messages.totalUnread == 0)
                .help("Mark all as read")
            }
        }
    }
}

private struct InboxRow: View {
    @Environment(AppModel.self) private var model
    let unitID: String

    static let thumbnail: CGFloat = 52

    var body: some View {
        let messages = model.store.messages
        let last = messages.lastMessage(for: unitID)
        let unread = messages.unreadCount(for: unitID)
        let name = model.store.registry.name(for: unitID)
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            CreatureThumbnail(unit: model.store.unit(unitID), size: Self.thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(name)
                        .font(Theme.Text.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.s)
                    if let last {
                        Text(MessageTime.short(last.time))
                            .font(Theme.Text.caption)
                            .monospacedDigit()
                            .foregroundStyle(unread > 0 ? Theme.accent : Theme.textSecondary)
                    }
                }
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    Text(preview(last))
                        .font(Theme.Text.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if unread > 0 {
                        UnreadBadge(count: unread)
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(unread > 0 ? "\(unread) unread" : "")
    }

    private func preview(_ message: CreatureMessage?) -> String {
        guard let message else { return "Nothing yet" }
        return message.isFromCreature ? message.text : "You: \(message.text)"
    }
}

/// A filled accent capsule with an unread count.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Theme.Text.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Theme.accent, in: Capsule())
            .accessibilityLabel("\(count) unread")
    }
}

/// The Messages entry on Home (iOS): unread count and the latest line.
struct MessagesHomeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let messages = model.store.messages
        let unread = messages.totalUnread
        let last = messages.items.last
        NavigationLink(value: Navigator.Route.messages) {
            HStack(spacing: Theme.Spacing.m) {
                IconBadge(systemName: "bubble.left.and.bubble.right.fill", tint: Theme.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages")
                        .font(Theme.Text.headline)
                        .foregroundStyle(Theme.textPrimary)
                    SecondaryText(subtitle(last), font: Theme.Text.callout)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.s)
                if unread > 0 {
                    UnreadBadge(count: unread)
                }
                Image(systemName: "chevron.right")
                    .font(Theme.Text.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .card(padding: Theme.Spacing.m, radius: Theme.Radius.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ last: CreatureMessage?) -> String {
        guard let last else { return "What your creatures tell you appears here" }
        let name = model.store.registry.name(for: last.unit)
        return last.isFromCreature ? "\(name): \(last.text)" : "You to \(name): \(last.text)"
    }
}
