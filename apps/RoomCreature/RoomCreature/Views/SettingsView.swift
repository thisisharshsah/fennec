import SwiftUI

/// App settings, from the gear on Home: the hub connection, saved Wi-Fi passwords, About.
/// Creature setup and per-creature Wi-Fi live on Home and the creature's page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var hostDraft = ""
    @State private var portDraft: Int?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            lifeSection
            brainSection
            NotificationSettingsSections(notifier: model.notifier, openSystemSettings: openSystemSettings)
            connectionSection(settings: settings)
            SecuritySections()
            SavedWifiPasswordsSection()
            aboutSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: loadDrafts)
        .task { await model.notifier.refreshPermission() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.notifier.refreshPermission() } }
        }
    }

    // MARK: Connection

    private func connectionSection(settings: ConnectionSettings) -> some View {
        @Bindable var settings = settings
        return Section {
            LabeledContent("Status") { ConnectionStatusView() }
            Toggle("Discover with Bonjour", isOn: $settings.usesBonjour)
            if settings.usesBonjour {
                if model.browser.services.isEmpty {
                    LabeledContent("Discovered") {
                        SecondaryText(model.browser.isBrowsing ? "Looking…" : "Not browsing", font: Theme.Text.body)
                    }
                } else {
                    ForEach(model.browser.services) { service in
                        Label(service.name, systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
            TextField("Host", text: $hostDraft)
                .autocorrectionDisabled()
                .onSubmit(applyDrafts)
            TextField("Port", value: $portDraft, format: .number.grouping(.never), prompt: Text(String(defaultPort)))
                .onSubmit(applyDrafts)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            if draftsChanged {
                Button("Apply host and port", action: applyDrafts)
            }
            if let error = model.client.lastError {
                LabeledContent("Last error") {
                    Text(error)
                        .foregroundStyle(Theme.negative)
                        .multilineTextAlignment(.trailing)
                }
            }
            Button("Reconnect") { model.client.reconnectNow() }
        } header: {
            Label("Hub connection", systemImage: "network")
        } footer: {
            Text("The hub is the program on your Mac that the creatures talk to. Bonjour finds it on the local network; the host and port are used otherwise. On this Mac the app uses localhost, port 8777; from anywhere else it uses an encrypted connection on port 8779. Leave the port empty for the default.")
        }
    }

    // MARK: About

    private var brainSection: some View {
        let brain = model.store.brain
        let ready = (brain?.hasKey ?? false) && (brain?.enabled ?? false)
        return Section {
            Toggle(isOn: Binding(
                get: { brain?.enabled ?? false },
                set: { on in
                    Haptics.light()
                    model.client.send(.brain(on: on))
                }
            )) {
                Label("Creature replies", systemImage: "bubble.left.and.text.bubble.right")
            }
            .disabled(brain == nil || !(brain?.hasKey ?? false))
            LabeledContent("Status") {
                Text(brainStatusText(brain))
                    .foregroundStyle(ready ? Theme.positive : Theme.textSecondary)
            }
            if let brain, brain.hasKey ?? false {
                LabeledContent("Model") {
                    Text((brain.local ?? false) ? "\(brain.model ?? "local") on this Mac" : (brain.model ?? "Claude"))
                }
            }
            if let brain, brain.hasKey ?? false, !(brain.local ?? false) {
                LabeledContent("Spent today") {
                    Text(String(format: "$%.2f of $%.2f", brain.spentTodayUsd ?? 0, brain.dailyCapUsd ?? 0))
                        .monospacedDigit()
                }
                Stepper(
                    "Daily limit: $\(String(format: "%.2f", brain.dailyCapUsd ?? 0.5))",
                    value: Binding(
                        get: { brain.dailyCapUsd ?? 0.5 },
                        set: { cap in model.client.send(.brain(dailyCapUsd: cap)) }
                    ),
                    in: 0...10,
                    step: 0.25
                )
            }
        } header: {
            Text("Conversation")
        } footer: {
            Text(brain?.hasKey ?? false
                ? "When you write to a creature in Chat, it answers in its own words, using what its sensors know about the room. It stops for the day at the limit."
                : "To let creatures answer you, the hub needs a model to talk to. Until then your messages are kept and an agent can still read them.")
        }
    }

    private func brainStatusText(_ brain: BrainStatus?) -> String {
        guard let brain else { return "Waiting for the hub" }
        if !(brain.hasKey ?? false) { return "Not set up" }
        if !(brain.enabled ?? false) { return "Off" }
        if (brain.spentTodayUsd ?? 0) >= (brain.dailyCapUsd ?? 0) { return "Paused until tomorrow" }
        return (brain.local ?? false) ? "Answering, free" : "Answering"
    }

    private var lifeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.store.lifeEnabled ?? true },
                set: { enabled in
                    Haptics.light()
                    model.client.send(.life(enabled))
                }
            )) {
                Label("Daily life", systemImage: "sparkles")
            }
            .disabled(model.store.lifeEnabled == nil)
        } header: {
            Text("Behaviour")
        } footer: {
            Text("Your creatures greet you when you come back, say good morning and goodnight, suggest a break after 50 minutes in front of them, and notice when the room gets warm. Each one at most once in a while.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("App version", value: Self.appVersion)
            if let version = model.store.bridgeVersion {
                LabeledContent("Hub version", value: version)
            }
            if let ip = model.store.bridgeLanIP {
                LabeledContent("Hub address", value: "\(ip):\(model.store.bridgeUnitPort.map(String.init) ?? "?")")
            }
            LabeledContent("Messages received", value: model.client.messageCount.formatted())
            LabeledContent("Events kept", value: model.store.events.count.formatted())
            Button("Clear history", role: .destructive) { model.store.clearHistory() }
        } header: {
            Label("About", systemImage: "info.circle")
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        let link = UIApplication.openSettingsURLString
        #else
        let link = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        #endif
        if let url = URL(string: link) { openURL(url) }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// The port used when the field is empty, for the host being typed.
    private var defaultPort: UInt16 {
        BridgeEndpoint.isLoopbackHost(hostDraft) ? BridgeEndpoint.localPort : BridgeEndpoint.securePort
    }

    private var draftsChanged: Bool {
        hostDraft != model.settings.host || portDraft != model.settings.port
    }

    private func loadDrafts() {
        hostDraft = model.settings.host
        portDraft = model.settings.port
    }

    private func applyDrafts() {
        let host = hostDraft.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if let portDraft, !(1...65535).contains(portDraft) { return }
        model.settings.host = host
        model.settings.port = portDraft
    }
}

// MARK: - Notifications

/// How the creature's messages arrive. Whatever is chosen, every message stays in Messages.
private struct NotificationSettingsSections: View {
    @Bindable var notifier: CreatureNotifier
    let openSystemSettings: () -> Void

    var body: some View {
        Section {
            permissionRow
            Toggle(isOn: $notifier.isEnabled) {
                Label("Notify me", systemImage: "bell.badge")
            }
            Group {
                Toggle(isOn: $notifier.playsSound) {
                    Label("Sound", systemImage: "speaker.wave.2")
                }
                .disabled(notifier.isFocused)
                Toggle(isOn: $notifier.isFocused) {
                    Label("Focus", systemImage: "moon.circle")
                }
            }
            .disabled(!notifier.isEnabled)
        } header: {
            Label("Notifications", systemImage: "bell")
        } footer: {
            Text("Every message is kept in Messages. Focus delivers them quietly to Notification Center: no banner, no sound.")
        }

        Section {
            ForEach(MessageTopic.allCases) { topic in
                Toggle(isOn: Binding(
                    get: { notifier.isOn(topic) },
                    set: { notifier.set(topic, on: $0) }
                )) {
                    Label(topic.settingTitle, systemImage: topic.systemImage)
                }
            }
        } header: {
            Text("Notify me about")
        }
        .disabled(!notifier.isEnabled)

        Section {
            Toggle(isOn: $notifier.usesQuietHours) {
                Label("Quiet hours", systemImage: "moon.zzz")
            }
            if notifier.usesQuietHours {
                DatePicker("From", selection: time($notifier.quietStart), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: time($notifier.quietEnd), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("During quiet hours notifications arrive silently in Notification Center and wait in Messages.")
        }
        .disabled(!notifier.isEnabled)
    }

    @ViewBuilder
    private var permissionRow: some View {
        LabeledContent("Permission") {
            HStack(spacing: Theme.Spacing.s) {
                StatusDot(color: permissionColor)
                Text(permissionText)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        switch notifier.permission {
        case .denied:
            Button("Open system settings", action: openSystemSettings)
        case .notAsked:
            Button("Allow notifications") { notifier.requestAuthorization() }
        case .granted, .unknown:
            EmptyView()
        }
    }

    private var permissionText: String {
        switch notifier.permission {
        case .granted: "Allowed"
        case .denied: "Off in system settings"
        case .notAsked: "Not asked yet"
        case .unknown: "Checking"
        }
    }

    private var permissionColor: Color {
        switch notifier.permission {
        case .granted: Theme.positive
        case .denied: Theme.negative
        case .notAsked, .unknown: Theme.inactive
        }
    }

    /// Minutes after midnight shown as a time of day.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
