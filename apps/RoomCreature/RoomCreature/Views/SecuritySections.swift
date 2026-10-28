import SwiftUI

/// Settings: how this device is trusted by the hub, the hub's certificate fingerprint, the devices
/// the hub has paired, and pairing another one.
struct SecuritySections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var deviceToRevoke: PairedDevice?
    @State private var isConfirmingForget = false

    private var client: BridgeClient { model.client }

    var body: some View {
        Section {
            LabeledContent("This device") {
                Text(statusText)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }
            if client.needsPairing {
                Button("Pair this device") {
                    client.pairingPromptDismissed = false
                    dismiss()
                }
            }
            if !client.isLocal, let fingerprint = client.credentials?.fingerprint ?? client.observedFingerprint {
                LabeledContent("Hub fingerprint") {
                    Text(HubCredentials.shortFingerprint(fingerprint))
                        .font(Theme.Text.mono)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            if client.pinMismatch {
                Text("This is not your hub: it shows a different certificate from the one you paired with. If you reinstalled the hub, forget it and pair again.")
                    .font(Theme.Text.callout)
                    .foregroundStyle(Theme.negative)
            }
            if !client.isLocal, client.hubIdentity != nil, client.credentials != nil || client.pinMismatch {
                Button("Forget this hub", role: .destructive) { isConfirmingForget = true }
            }
        } header: {
            Label("Security", systemImage: "lock.shield")
        } footer: {
            Text(client.isLocal
                ? "The app talks to the hub on this Mac directly. Phones and other computers connect encrypted and must be paired."
                : "The connection to your hub is encrypted and tied to its certificate. A device pairs only while someone presses the blue button on a creature.")
        }
        .confirmationDialog("Forget this hub?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget hub", role: .destructive) {
                Haptics.warning()
                client.forgetHub()
            }
        } message: {
            Text("This device's token and the hub's certificate are removed. You will need to pair again.")
        }

        if model.isHubConnected {
            devicesSection
        }
    }

    // MARK: Paired devices

    private var devicesSection: some View {
        Section {
            if let devices = client.devices {
                if devices.isEmpty {
                    SecondaryText("No devices paired yet", font: Theme.Text.body)
                }
                ForEach(devices) { device in
                    deviceRow(device)
                        #if os(iOS)
                        .swipeActions {
                            Button("Revoke", role: .destructive) { deviceToRevoke = device }
                        }
                        #endif
                }
            } else {
                SecondaryText("Asking the hub…", font: Theme.Text.body)
            }
            pairAnotherRow
        } header: {
            Text("Paired devices")
        } footer: {
            Text("Revoking a device signs it out of the hub at once. To add a phone or computer, tap Pair another device here and then Pair on the new device within a minute.")
        }
        .task(id: model.isHubConnected) {
            if model.isHubConnected { client.requestDevices() }
        }
        .confirmationDialog(
            "Revoke \(deviceToRevoke?.name ?? "device")?",
            isPresented: Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }),
            titleVisibility: .visible,
            presenting: deviceToRevoke
        ) { device in
            Button("Revoke", role: .destructive) {
                Haptics.warning()
                client.revokeDevice(device.id)
            }
        } message: { device in
            Text(device.id == client.credentials?.deviceID
                ? "This is the device you are using. It will need to be paired again."
                : "It will need to be paired again to talk to the hub.")
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconBadge(systemName: device.kind == "app" ? "iphone" : "sensor", tint: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(device.name ?? "Device")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textPrimary)
                    if device.id == client.credentials?.deviceID {
                        Text("This device")
                            .font(Theme.Text.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                SecondaryText(detail(for: device))
            }
            Spacer(minLength: Theme.Spacing.s)
            #if os(macOS)
            Button("Revoke", role: .destructive) { deviceToRevoke = device }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.negative)
            #endif
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(for device: PairedDevice) -> String {
        var parts: [String] = []
        if let created = device.created {
            parts.append("Paired \(Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .omitted))")
        }
        if let seen = device.lastSeen {
            parts.append("seen \(Date(timeIntervalSince1970: seen).formatted(.relative(presentation: .named)))")
        } else {
            parts.append("not seen yet")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var pairAnotherRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int((client.pairingWindowUntil?.timeIntervalSince(context.date) ?? 0).rounded(.up))
            if remaining > 0 {
                HStack(spacing: Theme.Spacing.s) {
                    StatusDot(color: Theme.positive)
                    Text("Pairing is open for \(remaining) s")
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    Haptics.medium()
                    client.openPairingWindow()
                } label: {
                    Label("Pair another device", systemImage: "plus.circle")
                }
            }
        }
    }

    // MARK: Status

    private var statusText: String {
        if client.isLocal { return "Local connection on this Mac" }
        if let credentials = client.credentials, credentials.isPaired {
            return "Paired as \(credentials.deviceName ?? BridgeClient.deviceName)"
        }
        return "Not paired"
    }

    private var statusColor: Color {
        if client.pinMismatch { return Theme.negative }
        if client.isLocal || client.credentials?.isPaired == true { return Theme.positive }
        return Theme.warning
    }
}
