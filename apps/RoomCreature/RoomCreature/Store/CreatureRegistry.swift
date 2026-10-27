import Foundation
import Observation

/// A creature this app knows about, kept across launches so an offline one still has a card.
struct KnownCreature: Codable, Identifiable, Hashable, Sendable {
    /// The id the hub uses (the unit's stored name, e.g. "desk").
    var unitID: String
    /// A name the user typed, shown instead of the capitalised id. Nil = use the id.
    var displayName: String?
    var addedAt: Date
    /// Last time the hub heard from it; persisted at most once a minute.
    var lastSeen: Date?

    var id: String { unitID }

    var name: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty { return displayName }
        return unitID.capitalized
    }
}

/// The list of known creatures, persisted in UserDefaults.
///
/// - Creatures the hub reports are added automatically, unless the user removed them (or they were
///   renamed away from); such ids are "dismissed" until the unit announces itself again (its own
///   hello, or the hub reporting it newly connected).
/// - Rename: the hub keys units by their stored name, so a rename makes the unit say hello under a new
///   id. `beginRename` remembers the request; a unit hello within 30 s whose id is the requested name
///   (or, failing that, has the same Wi-Fi IP) moves the entry to the new id, keeping its display
///   name and the date it was added.
@MainActor @Observable
final class CreatureRegistry {
    private enum Key {
        static let creatures = "creatures.known"
        static let dismissed = "creatures.dismissed"
    }

    private struct PendingRename {
        let oldID: String
        let newID: String
        let ip: String?
        let firmware: String?
        let at: Date
    }

    static let renameWindow: TimeInterval = 30

    private(set) var creatures: [KnownCreature] = []
    /// old id -> new id for renames seen this session, so an open page can follow its creature.
    private(set) var renamed: [String: String] = [:]

    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var pendingRename: PendingRename?
    @ObservationIgnored private var lastPersistedSeen: [String: Date] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.creatures),
           let decoded = try? JSONDecoder().decode([KnownCreature].self, from: data) {
            creatures = decoded
        }
        dismissed = Set(defaults.stringArray(forKey: Key.dismissed) ?? [])
        for creature in creatures {
            lastPersistedSeen[creature.unitID] = creature.lastSeen
        }
    }

    // MARK: Lookup

    func creature(_ id: String) -> KnownCreature? {
        creatures.first { $0.unitID == id }
    }

    func isKnown(_ id: String) -> Bool { creature(id) != nil }

    /// The name to show for a unit: the user's display name, else the capitalised id.
    func name(for id: String) -> String {
        creature(id)?.name ?? id.capitalized
    }

    /// Follows renames, so a page opened for "desk" keeps showing the unit after it became "shelf".
    func currentID(for id: String) -> String {
        var id = id
        var hops = 0
        while let next = renamed[id], hops < 8 {
            id = next
            hops += 1
        }
        return id
    }

    // MARK: Reports from the hub

    /// Called by the store after every update to a unit. `announced` is true for the unit's own hello
    /// or a hub "connected" notice: that is when a removed creature is allowed back. Returns the old id
    /// when this report completed a rename (the store then drops the stale unit).
    @discardableResult
    func observe(_ unit: UnitState, isHello: Bool, announced: Bool) -> String? {
        if announced, unit.isConnected, dismissed.remove(unit.id) != nil {
            persistDismissed()
        }
        var migratedFrom: String?
        if isHello, let oldID = matchRename(unit) {
            migrate(from: oldID, to: unit.id)
            migratedFrom = oldID
        }
        guard unit.isCreature else { return migratedFrom }
        if let index = creatures.firstIndex(where: { $0.unitID == unit.id }) {
            if let seen = unit.lastSeen, seen > (creatures[index].lastSeen ?? .distantPast) {
                creatures[index].lastSeen = seen
                let persisted = lastPersistedSeen[unit.id] ?? .distantPast
                if seen.timeIntervalSince(persisted) > 60 || !unit.isConnected {
                    lastPersistedSeen[unit.id] = seen
                    persist()
                }
            }
        } else if !dismissed.contains(unit.id) {
            creatures.append(KnownCreature(unitID: unit.id, displayName: nil, addedAt: .now, lastSeen: unit.lastSeen))
            lastPersistedSeen[unit.id] = unit.lastSeen
            persist()
        }
        return migratedFrom
    }

    // MARK: User actions

    func setDisplayName(_ name: String?, for id: String) {
        guard let index = creatures.firstIndex(where: { $0.unitID == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        creatures[index].displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist()
    }

    /// Remembers a rename sent to the hub so the unit's next hello under `newID` moves the entry.
    func beginRename(from oldID: String, to newID: String, ip: String?, firmware: String?) {
        pendingRename = PendingRename(oldID: oldID, newID: newID, ip: ip, firmware: firmware, at: .now)
    }

    /// Forgets a creature. It comes back if the hub reports it online again.
    func remove(_ id: String) {
        creatures.removeAll { $0.unitID == id }
        dismissed.insert(id)
        persist()
        persistDismissed()
    }

    // MARK: Private

    private func matchRename(_ unit: UnitState) -> String? {
        guard let pending = pendingRename else { return nil }
        guard Date.now.timeIntervalSince(pending.at) <= Self.renameWindow else {
            pendingRename = nil
            return nil
        }
        guard unit.id != pending.oldID, !isKnown(unit.id) else { return nil }
        let sameName = unit.id == pending.newID
        let sameIP = pending.ip != nil && unit.wifi?.ip == pending.ip
        let sameFirmware = pending.firmware != nil && unit.firmware == pending.firmware && unit.isCreature
        guard sameName || sameIP || sameFirmware else { return nil }
        pendingRename = nil
        return pending.oldID
    }

    private func migrate(from oldID: String, to newID: String) {
        renamed[oldID] = newID
        dismissed.insert(oldID)              // the hub keeps the old id as an offline unit; do not re-add it
        dismissed.remove(newID)
        if let index = creatures.firstIndex(where: { $0.unitID == oldID }) {
            creatures[index].unitID = newID
            lastPersistedSeen[newID] = lastPersistedSeen.removeValue(forKey: oldID)
        }
        persist()
        persistDismissed()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(creatures) {
            defaults.set(data, forKey: Key.creatures)
        }
    }

    private func persistDismissed() {
        defaults.set(Array(dismissed).sorted(), forKey: Key.dismissed)
    }
}
