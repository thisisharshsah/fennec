import SwiftUI

/// Manage › Wi-Fi: the creature's network, address, signal and link, "Change Wi-Fi network",
/// and (only while it is on the USB cable) sending Wi-Fi details over the cable.
struct CreatureWifiView: View {
    @Environment(AppModel.self) private var model
    let initialID: String

    @State private var confirmChange = false
    @State private var showsCable = false

    private var unitID: String { model.store.registry.currentID(for: initialID) }
    private var name: String { model.store.registry.name(for: unitID) }

    var body: some View {
        let unit = model.store.unit(unitID)
        let canCommand = model.isHubConnected && unit.isConnected
        Form {
            Section {
                LabeledContent("Network", value: unit.wifi?.ssid.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                LabeledContent("IP address", value: unit.wifi?.ip.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                LabeledContent("Signal", value: signalText(unit))
                LabeledContent("Link", value: linkText(unit))
                if let wifi = unit.wifi {
                    LabeledContent("Hub link", value: wifi.bridgeConnected == true ? "Connected" : (wifi.bridgeConnected == false ? "Not connected" : "—"))
                    LabeledContent("Updated") { Text(wifi.updatedAt, style: .relative) }
                }
                Button("Refresh") { model.client.send(.status(unit: unitID)) }
                    .disabled(!canCommand)
            } header: {
                Label("Wi-Fi", systemImage: "wifi")
            }

            Section {
                Button {
                    Haptics.warning()
                    confirmChange = true
                } label: {
                    Label("Change Wi-Fi network", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canCommand)
            } footer: {
                Text(canCommand
                     ? "\(name) forgets its network and restarts in setup mode, then you choose a new one from this device over Bluetooth."
                     : "\(name) is offline. To set it up from scratch, use Add creature on the home screen.")
            }

            if unit.isConnected, unit.link == "serial" {
                Section {
                    DisclosureGroup("Set Wi-Fi over USB cable", isExpanded: $showsCable) {
                        CableWifiForm(unitID: unitID)
                    }
                } footer: {
                    Text("For a creature plugged into the hub's Mac by USB: sends the network straight down the cable, no Bluetooth needed.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Wi-Fi")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Change \(name)'s Wi-Fi network?", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("Forget network and set up", role: .destructive, action: changeNetwork)
        } message: {
            Text("\(name) will go offline, forget its current network and restart in setup mode (violet cheeks). Then pick the new network here.")
        }
    }

    private func signalText(_ unit: UnitState) -> String {
        guard let dbm = unit.signalDBm else { return "—" }
        let quality = dbm >= -55 ? "strong" : (dbm >= -70 ? "good" : "weak")
        return "\(dbm) dBm · \(quality)"
    }

    private func linkText(_ unit: UnitState) -> String {
        guard unit.isConnected else { return "Offline" }
        switch unit.link {
        case "wifi": return "Wi-Fi"
        case "serial": return "USB cable"
        default: return "—"
        }
    }

    private func changeNetwork() {
        model.client.send(.forgetWifi(unit: unitID))
        model.navigator.startAdding(.changeWifi(name: name))
    }
}

/// Wi-Fi name and password sent to a unit over its serial link, plus the hub address.
private struct CableWifiForm: View {
    @Environment(AppModel.self) private var model
    let unitID: String

    @State private var ssid = ""
    @State private var password = ""

    private var isConnected: Bool { model.client.status == .connected }

    var body: some View {
        if let since = model.store.wifiRequests[unitID] {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Joining… waiting for the creature (\(Text(since, style: .relative)))")
                    .font(Theme.Text.callout)
                Spacer()
                Button("Dismiss") { model.store.dismissWifiRequest(for: unitID) }
                    .buttonStyle(.borderless)
            }
        }
        TextField("Network name (SSID)", text: $ssid)
            .autocorrectionDisabled()
        #if os(iOS)
            .textInputAutocapitalization(.never)
        #endif
        SecureField("Password", text: $password)
        if model.store.bridgeLanIP == nil || model.store.bridgeUnitPort == nil {
            SecondaryText("Hub address unknown; only the Wi-Fi details will be sent.")
        }
        Button("Send to creature", action: sendWifi)
            .disabled(!isConnected || ssid.trimmingCharacters(in: .whitespaces).isEmpty)
        SecondaryText("Joining can take up to 30 s; the first attempt after a reset often fails and the creature retries on its own every 20 s.")
    }

    private func sendWifi() {
        Haptics.medium()
        let name = ssid.trimmingCharacters(in: .whitespaces)
        model.client.send(.wifi(ssid: name, password: password, unit: unitID))
        if let host = model.store.bridgeLanIP, let port = model.store.bridgeUnitPort {
            model.client.send(.bridge(host: host, port: port, unit: unitID))
        }
        model.store.noteWifiRequest(for: unitID)
    }
}
