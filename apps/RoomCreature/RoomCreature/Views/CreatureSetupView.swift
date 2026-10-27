import SwiftUI

/// Onboards a creature over Bluetooth as four steps: Find, Choose network, Password, Done.
struct CreatureSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var improv = ImprovClient()
    @State private var currentNetwork = CurrentNetworkFinder()
    @State private var selectedNetwork: ImprovNetwork?
    @State private var usesManualNetwork = false
    @State private var manualSSID = ""
    @State private var password = ""
    /// The Keychain entry whose password was prefilled, and that password as prefilled, so the
    /// "saved on" note disappears as soon as the user types something else.
    @State private var savedPassword: SavedWifiPassword?
    @State private var prefilledPassword = ""
    @State private var didPreselect = false
    /// Called instead of a plain dismiss when the flow is finished: the id of the creature that
    /// came online (nil if it has not yet) and the network it was sent to.
    var onFinished: ((_ unitID: String?, _ ssid: String?) -> Void)?

    private enum Step: Int, CaseIterable {
        case find, network, password, done

        var title: String {
            switch self {
            case .find: "Find"
            case .network: "Network"
            case .password: "Password"
            case .done: "Done"
            }
        }
    }

    private var step: Step {
        if improv.provisioning.isSucceeded { return .done }
        switch improv.connection {
        case .disconnected, .connecting, .preparing: return .find
        case .ready: return (chosenSSID != nil || usesManualNetwork) ? .password : .network
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step.rawValue, titles: Step.allCases.map(\.title))
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.l)
            Form {
                if let note = improv.availability.note {
                    Section {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                }
                switch step {
                case .find:
                    findStep
                case .network:
                    creatureSection
                    networksSection
                case .password:
                    passwordStep
                case .done:
                    doneStep
                }
                if let error = improv.errorText, step != .done {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Theme.negative)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .screenBackground()
        .animation(.spring(duration: 0.4, bounce: 0.05), value: step)
        .navigationTitle("Set up a creature")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(step == .done ? "Done" : "Close") {
                    if step == .done { finish() } else { dismiss() }
                }
            }
        }
        .onAppear {
            improv.startScanning()
            currentNetwork.refresh()
        }
        .onDisappear { improv.stop() }
        .onChange(of: improv.connection) { _, connection in
            if !connection.isReady {
                didPreselect = false
                if !improv.provisioning.isSucceeded { clearChoice() }
            }
        }
        .onChange(of: improv.networks) { preselectCurrentNetwork() }
        .onChange(of: currentNetwork.ssid) { preselectCurrentNetwork() }
        .onChange(of: manualSSID) { _, ssid in
            if usesManualNetwork { loadSavedPassword(for: ssid.trimmingCharacters(in: .whitespaces)) }
        }
    }

    // MARK: Step 1 · Find

    @ViewBuilder
    private var findStep: some View {
        switch improv.connection {
        case .connecting(let creature), .preparing(let creature):
            Section {
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(creature.name)…")
                }
                Button("Cancel", role: .cancel) { improv.disconnect() }
            }
        case .disconnected, .ready:
            creaturesSection
        }
    }

    private var creaturesSection: some View {
        Section {
            if improv.creatures.isEmpty {
                HStack(spacing: Theme.Spacing.m) {
                    if improv.isScanning { ProgressView().controlSize(.small) }
                    SecondaryText(improv.isScanning ? "Looking for creatures nearby…" : "Not scanning", font: Theme.Text.body)
                }
            }
            ForEach(improv.creatures) { creature in
                Button {
                    improv.connect(creature)
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        IconBadge(systemName: "face.smiling", tint: Theme.MoodColor.color(for: .curious), size: 32)
                        Text(creature.name)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right", variableValue: creature.signalLevel)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel("Signal \(creature.rssi) dBm")
                        Image(systemName: "chevron.right")
                            .font(Theme.Text.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Creatures nearby")
        } footer: {
            Text("A creature advertises itself while its cheeks are violet: a new unit does this on its own; hold the blue button while powering one on to put it back into setup mode. Tap one to connect.")
        }
    }

    // MARK: Step 2 · Network

    @ViewBuilder
    private var creatureSection: some View {
        if let creature = improv.connection.creature {
            Section {
                HStack(spacing: Theme.Spacing.m) {
                    IconBadge(systemName: "face.smiling", tint: Theme.MoodColor.color(for: .pleased), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(creature.name)
                            .foregroundStyle(Theme.textPrimary)
                        if let state = improv.deviceState, state == .authorizationRequired {
                            SecondaryText("Press the button on the creature to allow setup.")
                        } else {
                            SecondaryText("Connected over Bluetooth")
                        }
                    }
                    Spacer()
                    Button {
                        Task { await improv.identify() }
                    } label: {
                        Label("Identify", systemImage: "hand.wave")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!improv.supportsIdentify || improv.provisioning.isBusy)
                    .help("Wags the tail and flashes the cheeks so you know which creature this is.")
                }
                Button("Disconnect", role: .cancel) { improv.disconnect() }
                    .disabled(improv.provisioning.isBusy)
            }
        }
    }

    private var networksSection: some View {
        Section {
            if improv.networks.isEmpty {
                HStack(spacing: Theme.Spacing.m) {
                    if improv.isLoadingNetworks { ProgressView().controlSize(.small) }
                    SecondaryText(
                        improv.isLoadingNetworks ? "Reading the creature's network list…" : "The creature has not seen any networks yet.",
                        font: Theme.Text.body
                    )
                }
            }
            ForEach(improv.networks.sorted { ($0.lastUsed || $0.ssid == currentNetwork.ssid) && !($1.lastUsed || $1.ssid == currentNetwork.ssid) }) { network in
                Button {
                    choose(network)
                } label: {
                    NetworkRow(
                        network: network,
                        isSelected: !usesManualNetwork && selectedNetwork == network,
                        isCurrent: network.ssid == currentNetwork.ssid,
                        hasSavedPassword: WifiPasswordStore.password(for: network.ssid) != nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(improv.provisioning.isBusy)
            }
            Button {
                chooseManual()
            } label: {
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22)
                    Text("Other network…")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Theme.Text.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(improv.provisioning.isBusy)
        } header: {
            HStack {
                Text("Choose a Wi-Fi network")
                Spacer()
                Button {
                    Task { await improv.readNetworks() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(improv.isLoadingNetworks || improv.provisioning.isBusy)
                .accessibilityLabel("Refresh network list")
            }
        } footer: {
            Text("Strongest signal first, as seen from the creature. A lock means the network needs a password.")
        }
    }

    // MARK: Step 3 · Password

    @ViewBuilder
    private var passwordStep: some View {
        if case .failed(let message) = improv.provisioning {
            Section {
                OutcomeView(
                    systemName: "xmark",
                    tint: Theme.negative,
                    title: "Not connected",
                    message: message
                )
                Button("Try again") { improv.resetProvisioning() }
                Button("Choose another network") { backToNetworks() }
            }
        } else {
            Section {
                if usesManualNetwork {
                    TextField("Network name (SSID)", text: $manualSSID)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                } else if let network = selectedNetwork {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: "wifi", variableValue: network.signalLevel)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(network.ssid)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button("Change") { backToNetworks() }
                            .buttonStyle(.borderless)
                            .disabled(improv.provisioning.isBusy)
                    }
                }
                if needsPassword {
                    RevealablePasswordField(text: $password, onSubmit: startProvisioning)
                        .disabled(improv.provisioning.isBusy)
                    if let savedPassword, password == prefilledPassword, !password.isEmpty {
                        HStack {
                            if let date = savedPassword.savedAt {
                                SecondaryText("Using the password saved on \(date.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                SecondaryText("Using the password saved earlier")
                            }
                            Spacer()
                            Button("Forget") { forgetSavedPassword() }
                                .buttonStyle(.borderless)
                                .font(Theme.Text.caption)
                                .disabled(improv.provisioning.isBusy)
                        }
                    }
                }
            } header: {
                Text(usesManualNetwork ? "Network and password" : (needsPassword ? "Password" : "Open network"))
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if needsPassword && password.isEmpty {
                    #if os(iOS)
                    Text("Tip: iPhone shows this password under Settings › Wi-Fi › ⓘ › Password. Copy it there, then tap Paste.")
                    #else
                    Text("Tip: Keychain Access or System Settings › Wi-Fi › Details shows this password. Copy it, then paste here.")
                    #endif
                }
                if let address = model.unitBridgeAddress {
                    Text("The creature will be told to reach the bridge at \(address).")
                } else {
                    Text("The bridge address is unknown (the app is not connected to a bridge on the network), so the creature will join Wi-Fi but will not know where the bridge is.")
                }
                }
            }
            Section {
                provisioningRow
            }
        }
    }

    @ViewBuilder
    private var provisioningRow: some View {
        switch improv.provisioning {
        case .idle, .failed:
            Button(action: startProvisioning) {
                Label("Connect", systemImage: "wifi")
                    .font(Theme.Text.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(!canProvision)
        case .sending:
            ProgressLine(text: "Sending the network details…")
        case .joining:
            ProgressLine(text: "Joining \(chosenSSID ?? "the network")… this takes up to 25 s.")
        case .succeeded:
            EmptyView()
        }
    }

    // MARK: Step 4 · Done

    /// The unit that was just set up, as the bridge sees it once it is back on Wi-Fi.
    private var joinedUnit: UnitState? {
        model.store.units.first { $0.isConnected && $0.link == "wifi" && $0.wifi?.ssid == chosenSSID }
    }

    @ViewBuilder
    private var doneStep: some View {
        Section {
            if let unit = joinedUnit {
                OutcomeView(
                    systemName: "checkmark",
                    tint: Theme.positive,
                    title: "\(unit.id.capitalized) is online",
                    message: "Connected over Wi-Fi and talking to the bridge. You can unplug it and put it anywhere in range."
                )
            } else {
                OutcomeView(
                    systemName: "checkmark",
                    tint: Theme.positive,
                    title: "Joined \(chosenSSID ?? "the network")",
                    message: "The creature restarts and comes back online in about 20 s. This screen updates when it does."
                )
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView().controlSize(.small)
                    SecondaryText("Waiting for it to reach the bridge…")
                }
            }
        }
        Section("Connection") {
            LabeledContent("Network", value: joinedUnit?.wifi?.ssid ?? chosenSSID ?? "—")
            LabeledContent("Address", value: joinedUnit?.wifi?.ip ?? doneAddress ?? "—")
            LabeledContent("Signal", value: joinedUnit?.signalDBm.map { "\($0) dBm" } ?? "—")
            LabeledContent("Bridge", value: joinedUnit != nil ? "Connected" : (model.unitBridgeAddress ?? "—"))
        }
        Section {
            Button("Set up another creature") {
                improv.resetProvisioning()
                clearChoice()
                if !improv.connection.isReady { improv.startScanning() }
            }
            Button("Done") { finish() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    private func finish() {
        if let onFinished {
            onFinished(joinedUnit?.id, chosenSSID)
        } else {
            dismiss()
        }
    }

    /// The IP from the unit's Improv result URL ("http://192.168.1.214/").
    private var doneAddress: String? {
        guard case .succeeded(let url) = improv.provisioning, let url, !url.isEmpty else { return nil }
        return url.replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Choice

    private var chosenSSID: String? {
        if usesManualNetwork {
            let name = manualSSID.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return selectedNetwork?.ssid
    }

    private var needsPassword: Bool {
        usesManualNetwork || (selectedNetwork?.secured ?? true)
    }

    private var canProvision: Bool {
        guard improv.connection.isReady, chosenSSID != nil else { return false }
        if !usesManualNetwork, selectedNetwork?.secured == true, password.isEmpty { return false }
        return true
    }

    private func choose(_ network: ImprovNetwork) {
        guard !improv.provisioning.isBusy else { return }
        improv.resetProvisioning()
        usesManualNetwork = false
        if selectedNetwork != network {
            password = ""
            loadSavedPassword(for: network.ssid)
        }
        selectedNetwork = network
    }

    private func chooseManual() {
        improv.resetProvisioning()
        usesManualNetwork = true
        selectedNetwork = nil
        loadSavedPassword(for: manualSSID.trimmingCharacters(in: .whitespaces))
    }

    /// Back to the network list without dropping the Bluetooth connection.
    private func backToNetworks() {
        guard !improv.provisioning.isBusy else { return }
        improv.resetProvisioning()
        clearChoice()
    }

    private func clearChoice() {
        selectedNetwork = nil
        usesManualNetwork = false
        manualSSID = ""
        password = ""
        savedPassword = nil
        prefilledPassword = ""
    }

    /// Once per connection: if this device's own network is in the creature's list, pick it.
    private func preselectCurrentNetwork() {
        guard !didPreselect, improv.connection.isReady, improv.provisioning == .idle,
              selectedNetwork == nil, !usesManualNetwork,
              let ssid = currentNetwork.ssid,
              let network = improv.networks.first(where: { $0.ssid == ssid })
        else { return }
        didPreselect = true
        choose(network)
    }

    /// Prefills the password remembered for `ssid`, or clears the note if there is none.
    private func loadSavedPassword(for ssid: String) {
        guard !ssid.isEmpty, let saved = WifiPasswordStore.password(for: ssid) else {
            if savedPassword != nil, password == prefilledPassword { password = "" }
            savedPassword = nil
            prefilledPassword = ""
            return
        }
        password = saved.password
        prefilledPassword = saved.password
        savedPassword = SavedWifiPassword(ssid: ssid, savedAt: saved.savedAt)
    }

    private func forgetSavedPassword() {
        guard let savedPassword else { return }
        WifiPasswordStore.forget(savedPassword.ssid)
        if password == prefilledPassword { password = "" }
        self.savedPassword = nil
        prefilledPassword = ""
    }

    private func startProvisioning() {
        guard canProvision, let ssid = chosenSSID else { return }
        let bridgeAddress = model.unitBridgeAddress
        let password = password
        let remember = needsPassword && !password.isEmpty
        Task {
            await improv.provision(ssid: ssid, password: password, bridgeAddress: bridgeAddress)
            if remember, improv.provisioning.isSucceeded, WifiPasswordStore.save(password, for: ssid) {
                savedPassword = SavedWifiPassword(ssid: ssid, savedAt: .now)
                prefilledPassword = password
            }
        }
    }
}

// MARK: - Pieces

/// Numbered circles joined by lines; done steps show a tick, the current one is filled.
private struct StepIndicator: View {
    let current: Int
    let titles: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Rectangle()
                        .fill(index <= current ? Theme.accent : Theme.hairline)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 13)
                }
                VStack(spacing: Theme.Spacing.xs + 2) {
                    ZStack {
                        Circle()
                            .fill(index <= current ? Theme.accent : Theme.surfaceElevated)
                            .overlay(Circle().strokeBorder(index <= current ? .clear : Theme.hairline, lineWidth: 1))
                        if index < current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(index == current ? .white : Theme.textSecondary)
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(title)
                        .font(Theme.Text.caption2.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.1), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(titles.count), \(titles[min(current, titles.count - 1)])")
    }
}

/// Large success / failure state: tinted icon circle, title, one explanatory paragraph.
private struct OutcomeView: View {
    let systemName: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            IconBadge(systemName: systemName, tint: tint, size: 72)
            Text(title)
                .font(Theme.Text.title)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.l)
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.Text.callout)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct NetworkRow: View {
    let network: ImprovNetwork
    let isSelected: Bool
    /// True when this device is itself joined to the network.
    let isCurrent: Bool
    var hasSavedPassword = false

    #if os(macOS)
    private static let currentNote = "Your Mac is on this network"
    #else
    private static let currentNote = "Your phone is on this network"
    #endif

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "wifi", variableValue: network.signalLevel)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.ssid)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if isCurrent {
                    SecondaryText(Self.currentNote)
                } else if network.lastUsed {
                    SecondaryText("Your home network · this creature was on it")
                }
                if hasSavedPassword {
                    SecondaryText("Password saved")
                }
            }
            Spacer()
            if network.secured {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Password required")
            }
            Image(systemName: isSelected ? "checkmark" : "chevron.right")
                .font(Theme.Text.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.accent : Theme.inactive)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(network.ssid)\(network.secured ? ", password required" : "")\(isCurrent ? ", " + Self.currentNote : "")")
    }
}
