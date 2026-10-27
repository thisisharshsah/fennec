import SwiftUI

/// App settings, from the gear on Home: the hub connection, saved Wi-Fi passwords, About.
/// Creature setup and per-creature Wi-Fi live on Home and the creature's page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hostDraft = ""
    @State private var portDraft = 8777

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            connectionSection(settings: settings)
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
            TextField("Port", value: $portDraft, format: .number.grouping(.never))
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
            Text("The hub is the program on your Mac that the creatures talk to. Bonjour finds it on the local network; the host and port are used otherwise.")
        }
    }

    // MARK: About

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

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
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
        guard !host.isEmpty, (1...65535).contains(portDraft) else { return }
        model.settings.host = host
        model.settings.port = portDraft
    }
}
