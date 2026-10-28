import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    let store = RoomStore()
    let settings = ConnectionSettings()
    let browser = BonjourBrowser()
    let navigator = Navigator()
    let client: BridgeClient
    let notifier: CreatureNotifier
    /// Reads a creature's new messages aloud on the iPhone (silent on the Mac).
    let voice = CreatureVoice()
    #if os(iOS)
    /// Hold to talk in Chat.
    let listener = SpeechListener()
    #endif
    /// The app is on screen; a creature only speaks then.
    @ObservationIgnored var isActive = true

    init() {
        client = BridgeClient(store: store)
        notifier = CreatureNotifier(client: client)
        store.onEvent = { [weak self] event in
            guard let self else { return }
            self.notifier.handle(event, creatureName: self.store.registry.name(for: event.unit))
            if self.isActive, event.isNotice, let text = event.text, !self.isListening {
                self.voice.say(text)
            }
        }
        store.messages.onUnreadChange = { [weak self] count in
            self?.notifier.setBadge(count)
        }
        notifier.onOpenConversation = { [weak self] unit in
            guard let self else { return }
            self.store.messages.markRead(unit)
            self.navigator.open(self.store.registry.currentID(for: unit), section: .chat)
        }
    }

    var desiredEndpoint: BridgeEndpoint {
        if settings.usesBonjour, let service = browser.services.first ?? browser.lastService {
            return .bonjour(service)
        }
        return settings.manualEndpoint
    }

    func start() {
        #if DEBUG
        // `-skipNotificationPrompt 1` keeps the permission alert off headless screenshots.
        if !UserDefaults.standard.bool(forKey: "skipNotificationPrompt") { notifier.requestAuthorization() }
        #else
        notifier.requestAuthorization()
        #endif
        browser.start()
        client.fallback = settings.manualEndpoint
        client.connect(to: desiredEndpoint)
    }

    /// Asks the hub for the conversation again (pull to refresh).
    func refreshMessages() async {
        client.send(.messages(days: MessageStore.historyDays))
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// Sends the owner's message to a creature and shows it at once.
    func sendMessage(_ text: String, to unit: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isHubConnected else { return }
        store.messages.addPendingReply(trimmed, unit: unit)
        client.send(.reply(trimmed, unit: unit))
    }

    /// `host:port` a unit should connect to over Wi-Fi: the bridge's LAN address and unit port from
    /// its WebSocket hello, else the host this app is connected to and the default unit port 8778.
    /// Nil when the only candidate is loopback, which a unit could never reach.
    var unitBridgeAddress: String? {
        let port = store.bridgeUnitPort ?? 8778
        var host = store.bridgeLanIP
        if host == nil, case .manual(let typed, _) = client.target ?? settings.manualEndpoint {
            host = typed
        }
        guard let host, !host.isEmpty else { return nil }
        if ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) { return nil }
        return "\(host):\(port)"
    }

    /// Where the hub was found, for people: the Bonjour name (the Mac's), or "this Mac" for localhost.
    var hubName: String? {
        guard client.status == .connected, let target = client.target else { return nil }
        switch target {
        case .bonjour(let service): return service.name
        case .manual(let host, _):
            return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) ? "this Mac" : host
        }
    }

    var isHubConnected: Bool { client.status == .connected }

    /// The owner is talking: the creature does not speak over them.
    var isListening: Bool {
        #if os(iOS)
        listener.isListening
        #else
        false
        #endif
    }

    /// When the app went to the background, for `resume`.
    @ObservationIgnored var backgroundedAt: Date?

    /// Back in the foreground: iOS closed the connection while the app was away, and the Bonjour
    /// search may have failed. Search again, and connect again unless the link is still alive.
    func resume() {
        let away = backgroundedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        browser.restart()
        // after a while away the hub has dropped this app even if the connection still looks open
        if client.status != .connected || away > 20 {
            client.fallback = settings.manualEndpoint
            if client.target == nil { client.connect(to: desiredEndpoint) } else { client.reconnectNow() }
        }
    }

    func applyDesiredEndpoint() {
        client.fallback = settings.manualEndpoint
        client.connect(to: desiredEndpoint)
    }
}
