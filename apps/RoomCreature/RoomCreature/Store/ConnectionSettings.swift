import Foundation
import Observation

@MainActor @Observable
final class ConnectionSettings {
    private enum Key {
        static let host = "bridge.host"
        static let port = "bridge.port"
        static let usesBonjour = "bridge.usesBonjour"
    }

    var host: String { didSet { defaults.set(host, forKey: Key.host) } }
    /// The port the user typed, or nil for the default: 8777 on this Mac, 8779 (TLS) for any other host.
    var port: Int? {
        didSet {
            if let port { defaults.set(port, forKey: Key.port) } else { defaults.removeObject(forKey: Key.port) }
        }
    }
    var usesBonjour: Bool { didSet { defaults.set(usesBonjour, forKey: Key.usesBonjour) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: Key.host) ?? "localhost"
        let storedPort = defaults.integer(forKey: Key.port)
        port = storedPort > 0 ? storedPort : nil
        #if os(macOS)
        let bonjourByDefault = false      // the bridge runs on this Mac: localhost is the reliable path
        #else
        let bonjourByDefault = true
        #endif
        usesBonjour = defaults.object(forKey: Key.usesBonjour) as? Bool ?? bonjourByDefault
    }

    /// The port used for the manual host. The plain port 8777 only answers on the hub's own Mac,
    /// so an older saved 8777 for a network host means the TLS port now.
    var effectivePort: UInt16 {
        let local = BridgeEndpoint.isLoopbackHost(host)
        guard let port, (1...65535).contains(port) else {
            return local ? BridgeEndpoint.localPort : BridgeEndpoint.securePort
        }
        if !local, port == Int(BridgeEndpoint.localPort) { return BridgeEndpoint.securePort }
        return UInt16(port)
    }

    var manualEndpoint: BridgeEndpoint {
        .manual(host: host.trimmingCharacters(in: .whitespaces), port: effectivePort)
    }
}
