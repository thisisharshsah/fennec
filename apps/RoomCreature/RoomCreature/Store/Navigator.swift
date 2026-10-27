import Foundation
import Observation

/// Where the app is: the pushed pages, the Mac sidebar selection, and the sheets on top.
/// One object so any screen can say "open this creature" or "start the Add flow".
@MainActor @Observable
final class Navigator {
    enum Route: Hashable {
        case creature(String)
        case history(String)
        case wifi(String)
    }

    /// Why the Add flow is open; changes the intro text.
    enum AddReason: Equatable {
        case new
        /// The named creature was just told to forget its network and is rebooting into setup mode.
        case changeWifi(name: String)
    }

    /// Pushed pages: the whole stack on iOS, the detail column's stack on the Mac.
    var path: [Route] = []
    /// Mac sidebar selection (a creature id).
    var selection: String?

    var isAddingCreature = false
    private(set) var addReason: AddReason = .new
    var isShowingSettings = false

    /// After setup ends before the new creature is back on the hub: open it when a creature on this
    /// network comes online, within two minutes.
    private(set) var awaitedArrival: (ssid: String?, until: Date)?

    func startAdding(_ reason: AddReason = .new) {
        addReason = reason
        isAddingCreature = true
    }

    func open(_ unitID: String) {
        #if os(macOS)
        selection = unitID
        path = []
        #else
        path = [.creature(unitID)]
        #endif
    }

    func awaitArrival(onNetwork ssid: String?) {
        awaitedArrival = (ssid, Date.now.addingTimeInterval(120))
    }

    /// Called when the set of online creatures changes; opens the awaited one if it arrived.
    func checkArrival(in units: [UnitState]) {
        guard let awaited = awaitedArrival else { return }
        guard Date.now < awaited.until else {
            awaitedArrival = nil
            return
        }
        let match = units.first { unit in
            unit.isCreature && unit.isConnected && unit.link == "wifi"
                && (awaited.ssid == nil || unit.wifi?.ssid == awaited.ssid)
        }
        if let match {
            awaitedArrival = nil
            open(match.id)
        }
    }
}
