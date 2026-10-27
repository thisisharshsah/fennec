import SwiftUI

/// Known creatures paired with their live state, online first, then by name.
@MainActor
private func sortedCreatures(_ model: AppModel) -> [(creature: KnownCreature, unit: UnitState)] {
    model.store.registry.creatures
        .map { ($0, model.store.unit($0.unitID)) }
        .sorted { lhs, rhs in
            if lhs.1.isConnected != rhs.1.isConnected { return lhs.1.isConnected }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }
}

/// "My creatures". On iOS the root of a NavigationStack with a card per creature; on the Mac a
/// sidebar of creatures with the selected creature's page on the right.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var navigator = model.navigator
        #if os(macOS)
        NavigationSplitView {
            HomeSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            NavigationStack(path: $navigator.path) {
                Group {
                    if let selection = navigator.selection {
                        CreatureDetailView(initialID: selection)
                            .id(selection)
                    } else {
                        ContentUnavailableView("Choose a creature", systemImage: "face.smiling", description: Text("Pick one in the sidebar, or add a new one with +."))
                            .screenBackground()
                    }
                }
                .creatureDestinations()
            }
        }
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: model.store.registry.creatures.map(\.unitID)) { selectFirstIfNeeded() }
        #else
        NavigationStack(path: $navigator.path) {
            CreatureList()
                .creatureDestinations()
        }
        #endif
    }

    #if os(macOS)
    private func selectFirstIfNeeded() {
        let ids = model.store.registry.creatures.map(\.unitID)
        let current = model.navigator.selection.map { model.store.registry.currentID(for: $0) }
        if let current, ids.contains(current) {
            if current != model.navigator.selection { model.navigator.selection = current }
            return
        }
        model.navigator.selection = sortedCreatures(model).first?.creature.unitID
    }
    #endif
}

// MARK: - Destinations

private struct CreatureDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Navigator.Route.self) { route in
            switch route {
            case .creature(let id): CreatureDetailView(initialID: id)
            case .history(let id): ChartsView(unitID: id)
            case .wifi(let id): CreatureWifiView(initialID: id)
            }
        }
    }
}

extension View {
    fileprivate func creatureDestinations() -> some View {
        modifier(CreatureDestinations())
    }
}

// MARK: - Toolbar

private struct HomeToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Haptics.medium()
                model.navigator.startAdding()
            } label: {
                Label("Add creature", systemImage: "plus")
            }
            .accessibilityLabel("Add creature")
            .help("Add creature")
        }
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) { settingsButton }
        #else
        ToolbarItem(placement: .automatic) { settingsButton }
        #endif
    }

    private var settingsButton: some View {
        Button {
            model.navigator.isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .accessibilityLabel("Settings")
        .help("Settings")
    }
}

// MARK: - iOS list of cards

private struct CreatureList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let creatures = sortedCreatures(model)
        let others = model.store.otherDevices
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HubBanner()
                ForEach(creatures, id: \.creature.unitID) { item in
                    NavigationLink(value: Navigator.Route.creature(item.creature.unitID)) {
                        CreatureCard(unit: item.unit, name: item.creature.name, lastSeen: item.creature.lastSeen)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            model.store.registry.remove(item.creature.unitID)
                        } label: {
                            Label("Remove from this app", systemImage: "trash")
                        }
                    }
                }
                if !others.isEmpty {
                    OtherDevicesSection(units: others)
                        .padding(.top, Theme.Spacing.xl)
                }
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: Theme.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .animation(.spring(duration: 0.4, bounce: 0.1), value: creatures.map(\.creature.unitID))
        }
        .screenBackground()
        .largeNavigationTitle("My creatures")
        .toolbar { HomeToolbar(model: model) }
    }
}

private struct OtherDevicesSection: View {
    let units: [UnitState]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Other devices")
                .font(Theme.Text.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .padding(.leading, Theme.Spacing.xs)
            VStack(spacing: Theme.Spacing.s) {
                ForEach(units) { unit in
                    OtherDeviceRow(unit: unit)
                }
            }
            .card(padding: Theme.Spacing.m, radius: Theme.Radius.m)
            SecondaryText("Helpers the hub runs on the Mac. They are not creatures.")
                .padding(.leading, Theme.Spacing.xs)
        }
    }
}

/// Shown above the cards only while the hub is not connected.
private struct HubBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.isHubConnected {
            HStack(spacing: Theme.Spacing.m) {
                IconBadge(systemName: "antenna.radiowaves.left.and.right.slash", tint: Theme.warning, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not connected to the hub")
                        .font(Theme.Text.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    SecondaryText(model.client.status.text)
                }
                Spacer(minLength: Theme.Spacing.s)
                Button("Settings") { model.navigator.isShowingSettings = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Theme.accent)
            }
            .card(padding: Theme.Spacing.m, radius: Theme.Radius.m)
            .transition(.opacity)
        }
    }
}

// MARK: - Mac sidebar

#if os(macOS)
private struct HomeSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var navigator = model.navigator
        let creatures = sortedCreatures(model)
        let others = model.store.otherDevices
        List(selection: $navigator.selection) {
            Section("My creatures") {
                ForEach(creatures, id: \.creature.unitID) { item in
                    CreatureSidebarRow(unit: item.unit, name: item.creature.name, lastSeen: item.creature.lastSeen)
                        .tag(item.creature.unitID)
                }
            }
            if !others.isEmpty {
                Section("Other devices") {
                    ForEach(others) { unit in
                        OtherDeviceRow(unit: unit)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ConnectionStatusView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.m)
        }
        .onChange(of: navigator.selection) { navigator.path = [] }
        .toolbar { HomeToolbar(model: model) }
    }
}
#endif
