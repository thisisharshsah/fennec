import Foundation
import Network
import Observation

@MainActor @Observable
final class BonjourBrowser {
    static let serviceType = "_roomcreature._tcp"

    private(set) var services: [DiscoveredService] = []
    private(set) var isBrowsing = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { result -> DiscoveredService? in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                return DiscoveredService(name: name, type: type, domain: domain)
            }
            Task { @MainActor in self.services = found.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { state in
            let browsing = if case .ready = state { true } else { false }
            Task { @MainActor in self.isBrowsing = browsing }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        services = []
        isBrowsing = false
    }
}
