import SwiftUI

/// One creature's page: the live hero and controls, then Senses, Activity, History, Manage, Details.
struct CreatureDetailView: View {
    @Environment(AppModel.self) private var model
    /// The id the page was opened with; renames are followed through the registry.
    let initialID: String

    @State private var isRenaming = false
    @State private var nameDraft = ""
    @State private var confirmRestart = false
    @State private var confirmRemove = false
    @State private var identifiedAt: Date?
    @State private var section: Section = Self.launchSection
    @State private var chatFilter: MessageTopic?

    enum Section: String, CaseIterable, Identifiable {
        case play = "Play", senses = "Senses", activity = "Activity", chat = "Chat", manage = "Manage"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .play: "face.smiling"
            case .senses: "waveform.path.ecg"
            case .activity: "clock"
            case .chat: "bubble.left.and.bubble.right"
            case .manage: "slider.horizontal.3"
            }
        }
    }

    /// Debug builds accept `-creatureSection manage` so screenshots can open a section directly.
    private static var launchSection: Section {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "creatureSection"),
           let match = Section.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
            return match
        }
        #endif
        return .play
    }

    private var unitID: String { model.store.registry.currentID(for: initialID) }
    private var known: KnownCreature? { model.store.registry.creature(unitID) }
    private var name: String { model.store.registry.name(for: unitID) }
    private var canCommand: Bool { model.isHubConnected && unit.isConnected }

    /// Live state, with the persisted last-seen time for a creature not reported this session.
    private var unit: UnitState {
        var unit = model.store.unit(unitID)
        if unit.lastSeen == nil { unit.lastSeen = known?.lastSeen }
        return unit
    }

    var body: some View {
        let unit = unit
        let chat = ConversationThread.filtered(model.store.messages.messages(for: unitID), by: chatFilter)
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                CreatureHero(unit: unit, name: name, compact: true)
                sectionPicker
                    .padding(.horizontal, Theme.Spacing.l)
                Group {
                    switch section {
                    case .play:
                        CreatureHero.Controls(unit: unit)
                    case .senses:
                        VStack(spacing: Theme.Spacing.l) {
                            SensesCard(unit: unit, embedded: true)
                            historyLink
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                    case .activity:
                        EventFeed(
                            events: model.store.events.filter { $0.unit == unitID && !Self.internalEvents.contains($0.name) },
                            title: nil,
                            showsUnit: false,
                            limit: 40
                        )
                        .padding(.horizontal, Theme.Spacing.l)
                    case .chat:
                        VStack(spacing: 0) {
                            ConversationThread(messages: chat, name: name, filter: chatFilter)
                            Color.clear.frame(height: 1).id(ConversationThread.endID)
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                    case .manage:
                        VStack(spacing: Theme.Spacing.l) {
                            manageCard(unit: unit)
                            detailsCard(unit: unit)
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                    }
                }
                .transition(.opacity)
            }
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: section)
        }
        .onChange(of: section) { scrollToChatEnd(proxy, animated: false) }
        .onChange(of: chat.last?.id) { scrollToChatEnd(proxy, animated: true) }
        .onAppear { scrollToChatEnd(proxy, animated: false) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if section == .chat {
                ChatComposer(unitID: unitID, name: name)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .refreshable { await model.refreshMessages() }
        .onAppear {
            consumePendingSection()
            markChatReadIfShown()
        }
        .onChange(of: model.navigator.pendingSection) { consumePendingSection() }
        .onChange(of: section) { markChatReadIfShown() }
        .onChange(of: model.store.messages.unreadCount(for: unitID)) { markChatReadIfShown() }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if section == .chat {
                ToolbarItem(placement: .primaryAction) {
                    ConversationFilterMenu(filter: $chatFilter)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { identify() } label: { Label("Identify", systemImage: "hand.wave") }
                        .disabled(!canCommand)
                    Button { nameDraft = name; isRenaming = true } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
                    Button { section = .manage } label: { Label("Wi-Fi and details", systemImage: "wifi") }
                    Divider()
                    Button { confirmRestart = true } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .disabled(!canCommand)
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove from this app", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More actions")
                }
            }
        }
        .alert("Rename \(name)", isPresented: $isRenaming) {
            TextField("Name", text: $nameDraft)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save", action: rename)
        } message: {
            Text(renameMessage(unit: unit))
        }
        .confirmationDialog("Restart \(name)?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart") {
                Haptics.medium()
                model.client.send(.restart(unit: unitID))
            }
        } message: {
            Text("It goes offline for about 20 seconds and comes back on its own.")
        }
        .confirmationDialog("Remove \(name) from this app?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("The creature itself is not changed. It appears here again the next time the hub reports it coming online.")
        }
    }

    /// Plumbing, not things that happened in the room.
    static let internalEvents: Set<String> = ["wifi_cmd", "error", "setup", "journal", "ack"]

    // MARK: Chat

    private func scrollToChatEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard section == .chat else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ConversationThread.endID, anchor: .bottom) }
            } else {
                proxy.scrollTo(ConversationThread.endID, anchor: .bottom)
            }
        }
    }

    private func markChatReadIfShown() {
        if section == .chat { model.store.messages.markRead(unitID) }
    }

    /// A notification was opened for this creature: show its conversation.
    private func consumePendingSection() {
        guard let pending = model.navigator.pendingSection,
              model.store.registry.currentID(for: pending.unitID) == unitID else { return }
        section = pending.section
        model.navigator.pendingSection = nil
        markChatReadIfShown()
    }

    // MARK: Section picker

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(Section.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: section) { Haptics.light() }
    }

    // MARK: History

    private var historyLink: some View {
        NavigationLink(value: Navigator.Route.history(unitID)) {
            HStack(spacing: Theme.Spacing.m) {
                IconBadge(systemName: "chart.xyaxis.line", tint: Theme.accent, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                        .font(Theme.Text.headline)
                        .foregroundStyle(Theme.textPrimary)
                    SecondaryText("Charts of the last 10 minutes")
                }
                Spacer(minLength: Theme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(Theme.Text.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Manage

    private func manageCard(unit: UnitState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ManageRow(systemImage: "character.cursor.ibeam", title: "Name", value: name) {
                nameDraft = name
                isRenaming = true
            }
            RowDivider()
            NavigationLink(value: Navigator.Route.wifi(unitID)) {
                ManageRowLabel(systemImage: "wifi", title: "Wi-Fi", value: wifiSummary(unit), showsChevron: true)
            }
            .buttonStyle(.plain)
            RowDivider()
            ManageRow(
                systemImage: identifiedAt == nil ? "hand.wave" : "checkmark",
                title: "Identify",
                value: identifiedAt == nil ? "Wag and chirp" : "Sent",
                isEnabled: canCommand,
                action: identify
            )
            RowDivider()
            ManageRow(systemImage: "arrow.clockwise", title: "Restart", value: nil, isEnabled: canCommand) {
                Haptics.warning()
                confirmRestart = true
            }
            RowDivider()
            ManageRow(systemImage: "trash", title: "Remove from this app", value: nil, tint: Theme.negative) {
                Haptics.warning()
                confirmRemove = true
            }
            if !canCommand {
                SecondaryText(model.isHubConnected ? "\(name) is offline. Identify and Restart work when it is back." : "Not connected to the hub.")
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .card()
    }

    private func wifiSummary(_ unit: UnitState) -> String {
        if unit.isConnected, unit.link != "wifi" { return "USB cable" }
        if let ssid = unit.wifi?.ssid, !ssid.isEmpty { return ssid }
        return unit.isConnected ? "Connected" : "—"
    }

    // MARK: Details

    private func detailsCard(unit: UnitState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CardHeader("Details", systemImage: "info.circle")
                .padding(.bottom, Theme.Spacing.xs)
            DetailRow("Firmware", unit.firmware ?? "—")
            DetailRow("Hub name", unitID)
            if let added = known?.addedAt {
                DetailRow("Added", added.formatted(date: .abbreviated, time: .omitted))
            }
            if let health = unit.health {
                DetailRow("Uptime", health.uptimeS.map(Self.duration) ?? "—")
                DetailRow("Boots", health.boots.map(String.init) ?? "—")
                if let reset = health.reset, !reset.isEmpty {
                    DetailRow("Last reset", reset.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                DetailRow("Watchdog resets", health.wdResets.map(String.init) ?? "—")
                DetailRow("Free memory", health.freeRam.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—")
                DetailRow("Wi-Fi reconnects", health.wifiReconnects.map(String.init) ?? "—")
            } else {
                SecondaryText(unit.isConnected ? "Health figures need firmware 0.5 or later." : "Health figures appear while it is online.")
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .card()
    }

    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : (seconds >= 3600 ? [.hour, .minute] : [.minute, .second])
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    // MARK: Actions

    private func identify() {
        Haptics.medium()
        model.client.send(.gesture(.wag, unit: unitID))
        model.client.send(.chirp("hello", unit: unitID))
        identifiedAt = .now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            identifiedAt = nil
        }
    }

    private func renameMessage(unit: UnitState) -> String {
        if canCommand {
            return "The creature stores its new name and reports in under it a moment later."
        }
        return "\(name) is offline, so the name is kept in this app only."
    }

    /// The hub knows a unit by the name stored on it. A typed name becomes that id in a hub-safe form
    /// ("Shelf Buddy" -> "shelf-buddy"); what was typed stays as the display name in this app.
    private func rename() {
        let typed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != name else { return }
        Haptics.success()
        // Shown at once and kept even if the creature never confirms the new id.
        model.store.registry.setDisplayName(typed, for: unitID)
        let newID = Self.hubID(from: typed)
        guard canCommand, !newID.isEmpty, newID != unitID, model.store.unitsByID[newID] == nil else { return }
        model.store.registry.beginRename(from: unitID, to: newID, ip: unit.wifi?.ip, firmware: unit.firmware)
        model.client.send(.rename(newID, unit: unitID))
    }

    static func hubID(from name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var id = ""
        for character in lowered {
            if character.isASCII && (character.isLetter || character.isNumber) {
                id.append(character)
            } else if character == "-" || character == "_" || character == " " {
                if !id.isEmpty, id.last != "-" { id.append("-") }
            }
        }
        while id.hasSuffix("-") { id.removeLast() }
        return String(id.prefix(23))
    }

    private func remove() {
        Haptics.medium()
        model.store.registry.remove(unitID)
        #if os(macOS)
        model.navigator.selection = nil
        #endif
        model.navigator.path = []
    }
}

// MARK: - Rows

struct ManageRowLabel: View {
    let systemImage: String
    let title: String
    let value: String?
    var tint: Color = Theme.textPrimary
    var showsChevron = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(Theme.Text.body)
                .foregroundStyle(tint == Theme.textPrimary ? Theme.accent : tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Text.body)
                .foregroundStyle(tint)
            Spacer(minLength: Theme.Spacing.s)
            if let value {
                Text(value)
                    .font(Theme.Text.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.Text.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
    }
}

private struct ManageRow: View {
    let systemImage: String
    let title: String
    let value: String?
    var tint: Color = Theme.textPrimary
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ManageRowLabel(systemImage: systemImage, title: title, value: value, tint: tint)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, 26 + Theme.Spacing.m)
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Spacing.s)
            Text(value)
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
