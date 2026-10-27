import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    let store = RoomStore()
    let settings = ConnectionSettings()
    let browser = BonjourBrowser()
    let navigator = Navigator()
    let client: BridgeClient

    init() {
        client = BridgeClient(store: store)
    }

    var desiredEndpoint: BridgeEndpoint {
        if settings.usesBonjour, let service = browser.services.first {
            return .bonjour(service)
        }
        return settings.manualEndpoint
    }

    func start() {
        browser.start()
        client.fallback = settings.manualEndpoint
        client.connect(to: desiredEndpoint)
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

    func applyDesiredEndpoint() {
        client.fallback = settings.manualEndpoint
        client.connect(to: desiredEndpoint)
    }
}
