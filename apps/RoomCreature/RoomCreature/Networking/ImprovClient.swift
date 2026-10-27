import CoreBluetooth
import Foundation
import Observation
import os

/// Onboards a unit over Bluetooth with the Improv Wi-Fi BLE protocol plus our network-list
/// characteristics. All CoreBluetooth callbacks are delivered on the main queue, so the whole
/// object lives on the main actor; reads and writes are wrapped in continuations so the flow
/// reads top to bottom (see `readNetworks` and `provision`).
@MainActor @Observable
final class ImprovClient {
    struct DiscoveredCreature: Identifiable, Hashable, Sendable {
        let id: UUID
        var name: String
        var rssi: Int

        var signalLevel: Double { min(1, max(0, Double(rssi + 90) / 50)) }
    }

    enum Availability: Equatable {
        case unknown, ready, poweredOff, unauthorized, unsupported

        var note: String? {
            switch self {
            case .unknown, .ready: nil
            case .poweredOff: "Bluetooth is turned off. Turn it on to find creatures nearby."
            case .unsupported: "This device has no Bluetooth."
            case .unauthorized:
                #if os(macOS)
                "RoomCreature is not allowed to use Bluetooth. Allow it in System Settings > Privacy & Security > Bluetooth."
                #else
                "RoomCreature is not allowed to use Bluetooth. Allow it in Settings > Privacy & Security > Bluetooth."
                #endif
            }
        }
    }

    enum Connection: Equatable {
        case disconnected
        case connecting(DiscoveredCreature)
        case preparing(DiscoveredCreature)
        case ready(DiscoveredCreature)

        var creature: DiscoveredCreature? {
            switch self {
            case .disconnected: nil
            case .connecting(let c), .preparing(let c), .ready(let c): c
            }
        }

        var isReady: Bool { if case .ready = self { true } else { false } }
    }

    enum Provisioning: Equatable {
        case idle
        case sending
        case joining
        case succeeded(url: String?)
        case failed(String)

        var isBusy: Bool { self == .sending || self == .joining }
        var isSucceeded: Bool { if case .succeeded = self { true } else { false } }
    }

    private struct PendingRead {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }

    private struct PendingWrite {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    static let provisionTimeout: Duration = .seconds(25)
    static let requestTimeout: Duration = .seconds(6)
    static let connectTimeout: Duration = .seconds(15)

    private(set) var availability: Availability = .unknown
    private(set) var isScanning = false
    private(set) var creatures: [DiscoveredCreature] = []
    private(set) var connection: Connection = .disconnected
    private(set) var networks: [ImprovNetwork] = []
    private(set) var isLoadingNetworks = false
    private(set) var provisioning: Provisioning = .idle
    private(set) var errorText: String?
    private(set) var deviceState: ImprovState?
    private(set) var supportsIdentify = true

    @ObservationIgnored private let logger = Logger(subsystem: "com.harshsah.roomcreature", category: "improv")
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingReads: [CBUUID: PendingRead] = [:]
    @ObservationIgnored private var pendingWrites: [CBUUID: PendingWrite] = [:]
    @ObservationIgnored private var connectTimer: Task<Void, Never>?
    @ObservationIgnored private var provisionArmed = false
    @ObservationIgnored private var provisionOutcome: Provisioning?
    @ObservationIgnored private var provisionContinuation: CheckedContinuation<Provisioning, Never>?
    @ObservationIgnored private var provisionTimer: Task<Void, Never>?
    @ObservationIgnored private var lastResultURL: String?

    // MARK: Scanning

    /// Creates the central on first use (this is what triggers the Bluetooth permission prompt).
    func startScanning() {
        wantsScan = true
        if central == nil {
            let delegate = Delegate(client: self)
            self.delegate = delegate
            central = CBCentralManager(delegate: delegate, queue: .main)
        } else {
            scanIfPossible()
        }
    }

    func stopScanning() {
        wantsScan = false
        central?.stopScan()
        isScanning = false
    }

    /// Stops everything; called when the setup screen goes away.
    func stop() {
        stopScanning()
        disconnect()
        creatures = []
    }

    private func scanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn, !central.isScanning else { return }
        // No service filter: a unit might advertise only its name, so we match either in didDiscover.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        logger.info("scanning for creatures")
    }

    // MARK: Connecting

    func connect(_ creature: DiscoveredCreature) {
        guard let central, let target = peripherals[creature.id] else { return }
        if peripheral != nil { disconnect() }
        resetSession()
        errorText = nil
        connection = .connecting(creature)
        peripheral = target
        target.delegate = delegate
        central.stopScan()
        isScanning = false
        central.connect(target, options: nil)
        connectTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, case .connecting = connection else { return }
            logger.warning("connect timed out")
            central.cancelPeripheralConnection(target)
            failConnection("Could not connect to \(creature.name). Make sure it is in setup mode (violet cheeks) and nearby.")
        }
    }

    func disconnect() {
        connectTimer?.cancel()
        connectTimer = nil
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        finishProvisioning(.failed(ImprovError.disconnected.localizedDescription))
        failPending(ImprovError.disconnected)
        peripheral = nil
        characteristics = [:]
        if connection != .disconnected { connection = .disconnected }
        scanIfPossible()
    }

    /// Clears a finished attempt so the user can try another network.
    func resetProvisioning() {
        guard !provisioning.isBusy else { return }
        provisioning = .idle
        errorText = nil
    }

    private func resetSession() {
        networks = []
        deviceState = nil
        supportsIdentify = true
        lastResultURL = nil
        provisioning = .idle
        provisionOutcome = nil
        provisionArmed = false
    }

    private func failConnection(_ message: String) {
        errorText = message
        peripheral?.delegate = nil
        peripheral = nil
        characteristics = [:]
        connection = .disconnected
        scanIfPossible()
    }

    // MARK: Operations

    /// Reads the count, then selects and reads every entry; strongest signal first, one row per SSID.
    func readNetworks() async {
        guard connection.isReady, !isLoadingNetworks else { return }
        isLoadingNetworks = true
        defer { isLoadingNetworks = false }
        do {
            let countData = try await read(ImprovUUID.networkCount)
            let count = Int(countData.first ?? 0)
            logger.info("unit reports \(count) networks")
            var found: [String: ImprovNetwork] = [:]
            for index in 0..<count {
                guard connection.isReady else { break }
                try await write(Data([UInt8(clamping: index)]), to: ImprovUUID.networkIndex)
                let entryData = try await read(ImprovUUID.networkEntry)
                let entry = String(decoding: entryData, as: UTF8.self)
                guard let network = ImprovNetwork(entry: entry) else {
                    logger.debug("skipping network entry \(entry, privacy: .public)")
                    continue
                }
                if let existing = found[network.ssid], existing.rssi >= network.rssi { continue }
                found[network.ssid] = network
            }
            networks = found.values.sorted { ($0.rssi, $0.ssid) > ($1.rssi, $1.ssid) }
        } catch {
            if connection.isReady {
                errorText = "Could not read the network list: \(error.localizedDescription)"
            }
        }
    }

    /// RPC 0x02: the creature wags and flashes its cheeks.
    func identify() async {
        do {
            try await write(try ImprovPacket.identify(), to: ImprovUUID.rpcCommand)
        } catch {
            errorText = "Identify failed: \(error.localizedDescription)"
        }
    }

    /// Our characteristic ...8013: `host:port` the unit should connect to once on Wi-Fi.
    func writeBridgeAddress(_ address: String) async throws {
        try await write(Data(address.utf8), to: ImprovUUID.bridgeAddress)
    }

    /// Writes the bridge address (if known), then RPC 0x01, then waits for state 0x04 or a
    /// non-zero error, giving up after `provisionTimeout`.
    func provision(ssid: String, password: String, bridgeAddress: String?) async {
        guard connection.isReady, !provisioning.isBusy else { return }
        errorText = nil
        provisioning = .sending
        provisionOutcome = nil
        lastResultURL = nil
        do {
            if let bridgeAddress {
                try await writeBridgeAddress(bridgeAddress)
            }
            let packet = try ImprovPacket.wifiSettings(ssid: ssid, password: password)
            provisionArmed = true
            try await write(packet, to: ImprovUUID.rpcCommand)
            if provisioning == .sending { provisioning = .joining }
            let outcome: Provisioning
            if let early = provisionOutcome {
                outcome = early
            } else {
                outcome = await withCheckedContinuation { continuation in
                    provisionContinuation = continuation
                    provisionTimer = Task { [weak self] in
                        try? await Task.sleep(for: Self.provisionTimeout)
                        guard !Task.isCancelled else { return }
                        self?.finishProvisioning(.failed("No answer from the creature after 25 s. Check the password and try again."))
                    }
                }
            }
            provisionArmed = false
            provisioning = outcome
            if case .succeeded = outcome {
                logger.info("provisioned \(ssid, privacy: .public)")
            }
        } catch {
            provisionArmed = false
            provisioning = .failed(error.localizedDescription)
        }
    }

    private func finishProvisioning(_ outcome: Provisioning) {
        guard provisionArmed, provisionOutcome == nil else { return }
        provisionOutcome = outcome
        provisionTimer?.cancel()
        provisionTimer = nil
        if let continuation = provisionContinuation {
            provisionContinuation = nil
            continuation.resume(returning: outcome)
        }
    }

    // MARK: GATT plumbing

    private func read(_ uuid: CBUUID) async throws -> Data {
        guard let peripheral, connection.isReady else { throw ImprovError.notConnected }
        guard let characteristic = characteristics[uuid] else { throw ImprovError.missingCharacteristic(String(uuid.uuidString.suffix(4))) }
        guard pendingReads[uuid] == nil else { throw ImprovError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: Self.requestTimeout)
                guard !Task.isCancelled, let pending = self?.pendingReads.removeValue(forKey: uuid) else { return }
                pending.continuation.resume(throwing: ImprovError.timedOut)
            }
            pendingReads[uuid] = PendingRead(continuation: continuation, timeout: timeout)
            peripheral.readValue(for: characteristic)
        }
    }

    private func write(_ data: Data, to uuid: CBUUID) async throws {
        guard let peripheral, connection.isReady else { throw ImprovError.notConnected }
        guard let characteristic = characteristics[uuid] else { throw ImprovError.missingCharacteristic(String(uuid.uuidString.suffix(4))) }
        if characteristic.properties.contains(.write) {
            guard pendingWrites[uuid] == nil else { throw ImprovError.busy }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: Self.requestTimeout)
                    guard !Task.isCancelled, let pending = self?.pendingWrites.removeValue(forKey: uuid) else { return }
                    pending.continuation.resume(throwing: ImprovError.timedOut)
                }
                pendingWrites[uuid] = PendingWrite(continuation: continuation, timeout: timeout)
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            try await Task.sleep(for: .milliseconds(80))   // give the unit a moment before the next request
        } else {
            throw ImprovError.notWritable(String(uuid.uuidString.suffix(4)))
        }
    }

    private func failPending(_ error: Error) {
        for pending in pendingReads.values {
            pending.timeout.cancel()
            pending.continuation.resume(throwing: error)
        }
        pendingReads = [:]
        for pending in pendingWrites.values {
            pending.timeout.cancel()
            pending.continuation.resume(throwing: error)
        }
        pendingWrites = [:]
    }

    // MARK: Delegate events (main queue)

    fileprivate func centralStateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            availability = .ready
            scanIfPossible()
        case .poweredOff:
            availability = .poweredOff
            isScanning = false
        case .unauthorized:
            availability = .unauthorized
            isScanning = false
        case .unsupported:
            availability = .unsupported
            isScanning = false
        default:
            availability = .unknown
        }
        if state != .poweredOn, connection != .disconnected {
            failPending(ImprovError.bluetoothUnavailable)
            finishProvisioning(.failed(ImprovError.bluetoothUnavailable.localizedDescription))
            peripheral = nil
            characteristics = [:]
            connection = .disconnected
        }
    }

    fileprivate func didDiscover(_ found: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) {
        let advertisedName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? found.name
        var services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        services += advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let matches = services.contains(ImprovUUID.service) || (name?.hasPrefix(ImprovUUID.namePrefix) ?? false)
        guard matches else { return }
        peripherals[found.identifier] = found
        let creature = DiscoveredCreature(id: found.identifier, name: name ?? "creature", rssi: rssi.intValue)
        if let index = creatures.firstIndex(where: { $0.id == creature.id }) {
            creatures[index] = creature
        } else {
            creatures.append(creature)
            logger.info("found \(creature.name, privacy: .public) at \(creature.rssi) dBm")
        }
        creatures.sort { ($0.rssi, $0.name) > ($1.rssi, $1.name) }
    }

    fileprivate func didConnect(_ connected: CBPeripheral) {
        guard connected === peripheral, let creature = connection.creature else { return }
        connectTimer?.cancel()
        connectTimer = nil
        connection = .preparing(creature)
        connected.discoverServices([ImprovUUID.service])
    }

    fileprivate func didFailToConnect(_ failed: CBPeripheral, error: Error?) {
        guard failed === peripheral else { return }
        connectTimer?.cancel()
        connectTimer = nil
        failConnection("Could not connect: \(error?.localizedDescription ?? "unknown error")")
    }

    fileprivate func didDisconnect(_ gone: CBPeripheral, error: Error?) {
        guard gone === peripheral else { return }
        logger.info("disconnected: \(error?.localizedDescription ?? "by request", privacy: .public)")
        connectTimer?.cancel()
        connectTimer = nil
        finishProvisioning(.failed("The creature disconnected before it answered."))
        failPending(ImprovError.disconnected)
        peripheral = nil
        characteristics = [:]
        connection = .disconnected
        // After a success the unit turns Bluetooth off on purpose; that is not an error.
        if let error, !provisioning.isBusy, !provisioning.isSucceeded {
            errorText = error.localizedDescription
        }
        scanIfPossible()
    }

    fileprivate func didDiscoverServices(_ discovered: CBPeripheral, error: Error?) {
        guard discovered === peripheral else { return }
        guard let service = discovered.services?.first(where: { $0.uuid == ImprovUUID.service }) else {
            central?.cancelPeripheralConnection(discovered)
            failConnection(error?.localizedDescription ?? "This device does not offer the Improv setup service.")
            return
        }
        discovered.discoverCharacteristics(nil, for: service)
    }

    fileprivate func didDiscoverCharacteristics(_ discovered: CBPeripheral, service: CBService, error: Error?) {
        guard discovered === peripheral, service.uuid == ImprovUUID.service, let creature = connection.creature else { return }
        if let error {
            central?.cancelPeripheralConnection(discovered)
            failConnection(error.localizedDescription)
            return
        }
        characteristics = Dictionary((service.characteristics ?? []).map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        guard characteristics[ImprovUUID.rpcCommand] != nil, characteristics[ImprovUUID.state] != nil else {
            central?.cancelPeripheralConnection(discovered)
            failConnection("This device does not offer the Improv setup service.")
            return
        }
        for uuid in ImprovUUID.notified {
            if let characteristic = characteristics[uuid], characteristic.properties.contains(.notify) {
                discovered.setNotifyValue(true, for: characteristic)
            }
        }
        if let capabilities = characteristics[ImprovUUID.capabilities] { discovered.readValue(for: capabilities) }
        if let state = characteristics[ImprovUUID.state] { discovered.readValue(for: state) }
        connection = .ready(creature)
        logger.info("ready: \(creature.name, privacy: .public)")
        Task { await readNetworks() }
    }

    fileprivate func didUpdateValue(for characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        if let pending = pendingReads.removeValue(forKey: uuid) {
            pending.timeout.cancel()
            if let error {
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume(returning: characteristic.value ?? Data())
            }
        }
        guard error == nil, let value = characteristic.value else { return }
        switch uuid {
        case ImprovUUID.state:
            guard let byte = value.first else { return }
            deviceState = ImprovState(rawValue: byte)
            logger.debug("state 0x\(String(byte, radix: 16), privacy: .public)")
            if byte == ImprovState.provisioned.rawValue {
                finishProvisioning(.succeeded(url: lastResultURL))
            } else if byte == ImprovState.provisioning.rawValue, provisioning == .sending {
                provisioning = .joining
            }
        case ImprovUUID.error:
            guard let byte = value.first else { return }
            logger.debug("error 0x\(String(byte, radix: 16), privacy: .public)")
            if byte != 0 {
                finishProvisioning(.failed(ImprovDeviceError.describe(byte)))
            }
        case ImprovUUID.rpcResult:
            guard let result = ImprovPacket.parseResult(value) else {
                logger.warning("bad RPC result packet (\(value.count) bytes)")
                return
            }
            if result.command == ImprovPacket.Command.wifiSettings.rawValue {
                lastResultURL = result.strings.first
                if case .succeeded = provisioning {
                    provisioning = .succeeded(url: lastResultURL)
                }
            }
        case ImprovUUID.capabilities:
            supportsIdentify = (value.first ?? 1) & 0x01 == 0x01
        default:
            break
        }
    }

    fileprivate func didWriteValue(for characteristic: CBCharacteristic, error: Error?) {
        guard let pending = pendingWrites.removeValue(forKey: characteristic.uuid) else { return }
        pending.timeout.cancel()
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume()
        }
    }

    fileprivate func didUpdateNotificationState(for characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.warning("notify on \(characteristic.uuid.uuidString.suffix(4), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - CoreBluetooth delegate

/// The central is created with `queue: .main`, so every callback already runs on the main actor;
/// the `@preconcurrency` conformances let the main-actor methods satisfy the nonisolated protocols.
@MainActor
private final class Delegate: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    unowned let client: ImprovClient

    init(client: ImprovClient) {
        self.client = client
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        client.centralStateChanged(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        client.didDiscover(peripheral, advertisement: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        client.didConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        client.didFailToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        client.didDisconnect(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        client.didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        client.didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        client.didUpdateValue(for: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        client.didWriteValue(for: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        client.didUpdateNotificationState(for: characteristic, error: error)
    }
}
