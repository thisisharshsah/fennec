import Foundation
import Network

enum BridgeEndpoint: Hashable, Sendable {
    case manual(host: String, port: UInt16)
    case bonjour(DiscoveredService)

    var nwEndpoint: NWEndpoint {
        switch self {
        case .manual(let host, let port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8777)
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
}

struct DiscoveredService: Hashable, Identifiable, Sendable {
    let name: String
    let type: String
    let domain: String

    var id: String { "\(name).\(type)\(domain)" }
}
