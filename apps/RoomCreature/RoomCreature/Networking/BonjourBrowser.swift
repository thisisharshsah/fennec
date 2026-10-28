import Foundation
import Network
import Observation

@MainActor @Observable
final class BonjourBrowser {
    static let serviceType = "_roomcreature._tcp"

    private(set) var services: [DiscoveredService] = []
    /// The last hub found. A hub that restarts drops out of Bonjour for a moment; the app keeps
    /// aiming at it instead of falling back to "localhost", which on a phone is the phone itself.
    private(set) var lastService: DiscoveredService?
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
            Task { @MainActor in
                self.services = found.sorted { $0.name < $1.name }
                if let first = self.services.first { self.lastService = first }
            }
        }
        browser.stateUpdateHandler = { state in
            let browsing = if case .ready = state { true } else { false }
            let failed = if case .failed = state { true } else { false }
            Task { @MainActor in
                self.isBrowsing = browsing
                if failed { self.restart(after: 2) }        // e.g. after the app was suspended
            }
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

    /// A fresh search: after coming back to the foreground, or when the search failed.
    func restart(after seconds: Double = 0) {
        Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            browser?.cancel()
            browser = nil
            isBrowsing = false
            start()
        }
    }
}
