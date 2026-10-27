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
    var port: Int { didSet { defaults.set(port, forKey: Key.port) } }
    var usesBonjour: Bool { didSet { defaults.set(usesBonjour, forKey: Key.usesBonjour) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: Key.host) ?? "localhost"
        let storedPort = defaults.integer(forKey: Key.port)
        port = storedPort > 0 ? storedPort : 8777
        #if os(macOS)
        let bonjourByDefault = false      // the bridge runs on this Mac: localhost is the reliable path
        #else
        let bonjourByDefault = true
        #endif
        usesBonjour = defaults.object(forKey: Key.usesBonjour) as? Bool ?? bonjourByDefault
    }

    var manualEndpoint: BridgeEndpoint {
        .manual(host: host.trimmingCharacters(in: .whitespaces), port: UInt16(clamping: port))
    }
}
