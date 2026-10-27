import CoreLocation
import Foundation
import Observation
import os
#if os(iOS)
import NetworkExtension
#elseif os(macOS)
import CoreWLAN
#endif

/// Finds the Wi-Fi network this device is on, so the setup flow can preselect it in the creature's
/// list. Both platforms only reveal the SSID with location permission (plus the Access Wi-Fi
/// Information entitlement on iOS), so the first `refresh` asks for when-in-use authorization.
/// Denied, restricted or unknown simply leaves `ssid` nil; nothing here ever blocks or throws.
@MainActor @Observable
final class CurrentNetworkFinder {
    /// The SSID this device is joined to, or nil when unknown or not permitted.
    private(set) var ssid: String?

    @ObservationIgnored private let logger = Logger(subsystem: "com.harshsah.roomcreature", category: "current-network")
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var refreshAfterAuthorization = false

    /// Looks the network up, asking for location permission the first time.
    func refresh() {
        if manager == nil {
            let delegate = Delegate(finder: self)
            self.delegate = delegate
            let manager = CLLocationManager()
            manager.delegate = delegate
            self.manager = manager
        }
        guard let manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            refreshAfterAuthorization = true
            manager.requestWhenInUseAuthorization()
        case let status where Self.isAuthorized(status):
            Task { await fetch() }
        default:
            logger.info("location not authorized; skipping current-network lookup")
            ssid = nil
        }
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard refreshAfterAuthorization, status != .notDetermined else { return }
        refreshAfterAuthorization = false
        if Self.isAuthorized(status) {
            Task { await fetch() }
        } else {
            logger.info("location permission declined; no current-network preselection")
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        status == .authorizedAlways
        #else
        status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    private func fetch() async {
        #if os(iOS)
        let found: String? = await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        #elseif os(macOS)
        let found = CWWiFiClient.shared().interface()?.ssid()
        #else
        let found: String? = nil
        #endif
        ssid = (found?.isEmpty ?? true) ? nil : found
        logger.info("current network: \(self.ssid ?? "unknown", privacy: .private)")
    }
}

/// The manager is created on the main thread, so its callbacks arrive there too; the
/// `@preconcurrency` conformance lets the main-actor method satisfy the nonisolated protocol.
@MainActor
private final class Delegate: NSObject, @preconcurrency CLLocationManagerDelegate {
    unowned let finder: CurrentNetworkFinder

    init(finder: CurrentNetworkFinder) {
        self.finder = finder
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        finder.authorizationChanged(manager.authorizationStatus)
    }
}
