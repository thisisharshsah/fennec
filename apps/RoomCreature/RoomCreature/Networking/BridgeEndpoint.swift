import Foundation
import Network

enum BridgeEndpoint: Hashable, Sendable {
    case manual(host: String, port: UInt16)
    case bonjour(DiscoveredService)

    /// The hub's plain WebSocket, trusted without a token but listening on its own Mac only.
    static let localPort: UInt16 = 8777
    /// The hub's TLS WebSocket for apps on the network (token required).
    static let securePort: UInt16 = 8779

    var nwEndpoint: NWEndpoint {
        switch self {
        case .manual(let host, let port) where !Self.isLoopbackHost(host):
            // WebSocket over TLS needs a URL endpoint to build its request
            .url(URL(string: "wss://\(host.contains(":") ? "[\(host)]" : host):\(port)/") ?? URL(filePath: "/"))
        case .manual(let host, let port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8779)
        case .bonjour(let service):
            .service(name: service.name, type: service.type, domain: service.domain, interface: nil)
        }
    }

    var label: String {
        switch self {
        case .manual(let host, let port): "\(host):\(port)"
        case .bonjour(let service): service.name
        }
    }

    /// The hub on this very Mac, reached over loopback: plain WebSocket, no pairing.
    var isLoopback: Bool {
        if case .manual(let host, _) = self { return Self.isLoopbackHost(host) }
        return false
    }

    /// Everything but loopback goes over TLS with a pinned certificate.
    var usesTLS: Bool { !isLoopback }

    /// The key the hub's pinned certificate and this device's token are stored under:
    /// the Bonjour service name, or `host:port`.
    var hubIdentity: String {
        switch self {
        case .manual(let host, let port): "\(host.lowercased()):\(port)"
        case .bonjour(let service): "bonjour:\(service.name)"
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

struct DiscoveredService: Hashable, Identifiable, Sendable {
    let name: String
    let type: String
    let domain: String

    var id: String { "\(name).\(type)\(domain)" }
}
