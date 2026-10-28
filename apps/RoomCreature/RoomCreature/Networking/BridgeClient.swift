import Foundation
import Observation
import os
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class BridgeClient {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        /// Reached the hub over the network, but it wants this device paired first.
        case needsPairing
        case retrying(inSeconds: Int)

        var text: String {
            switch self {
            case .idle: "Not connected"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .needsPairing: "Pairing needed"
            case .retrying(let seconds): "Retrying in \(seconds) s"
            }
        }
    }

    /// Where the pairing screen stands.
    struct Pairing: Equatable {
        /// The hub's pairing window is open (its blue button was pressed).
        var windowOpen = false
        /// A pair request is on its way.
        var isWaiting = false
        /// Why the hub said no, or why this app refused the answer.
        var refusal: String?
        /// The hub that answered is not the one whose certificate this connection saw.
        var wrongHub = false
    }

    private struct StreamEnded: Error {}

    private(set) var status: Status = .idle
    private(set) var target: BridgeEndpoint?
    /// Used when a Bonjour endpoint keeps failing: the host and port typed in Settings.
    var fallback: BridgeEndpoint?
    private(set) var lastError: String?
    private(set) var messageCount = 0

    // MARK: Security state of the current connection

    /// The hub identity of the current attempt (Bonjour name or `host:port`).
    private(set) var hubIdentity: String?
    /// The current attempt is to the hub on this Mac over loopback (trusted, no pairing).
    private(set) var isLocal = false
    /// What the Keychain holds for the current hub.
    private(set) var credentials: HubCredentials?
    /// SHA-256 of the certificate the hub presented on the current TLS connection.
    private(set) var observedFingerprint: String?
    /// The hub presented a different certificate than the one pinned at pairing.
    private(set) var pinMismatch = false
    /// The hub wants this device paired; stays true across retries until a trusted connection.
    private(set) var needsPairing = false
    private(set) var pairing = Pairing()
    /// The owner closed the pairing screen; Settings can bring it back.
    var pairingPromptDismissed = false
    /// Devices the hub has issued tokens to (from `devices`).
    private(set) var devices: [PairedDevice]?
    /// Until when the pairing window this app opened for another device stays open.
    private(set) var pairingWindowUntil: Date?

    private let store: RoomStore
    private let logger = Logger(subsystem: "com.harshsah.roomcreature", category: "bridge")
    private var loop: Task<Void, Never>?
    private var connection: WebSocketConnection?
    /// The current connection presented a stored token.
    private var sentToken = false

    init(store: RoomStore) {
        self.store = store
    }

    func connect(to endpoint: BridgeEndpoint) {
        if endpoint == target, loop != nil { return }
        stop()
        if endpoint != target { resetSecurityState() }
        target = endpoint
        loop = Task { await run(endpoint) }
    }

    func reconnectNow() {
        guard let target else { return }
        stop()
        connect(to: target)
    }

    func disconnect() {
        stop()
        target = nil
    }

    func send(_ command: BridgeCommand) {
        guard status == .connected, let connection else {
            logger.warning("dropping command \(command.cmd, privacy: .public): not connected")
            return
        }
        transmit(command, on: connection)
    }

    // MARK: Pairing

    /// The name the hub lists this device under.
    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Asks the hub for a token. Works only while its pairing window is open.
    func pair() {
        guard status == .needsPairing, let connection else { return }
        pairing.isWaiting = true
        pairing.refusal = nil
        pairing.wrongHub = false
        transmit(.pair(deviceName: Self.deviceName), on: connection)
    }

    /// Opens the hub's pairing window so another device can pair (needs a trusted connection).
    func openPairingWindow() {
        send(.pairOpen())
    }

    func requestDevices() {
        send(.devices())
    }

    func revokeDevice(_ id: String) {
        send(.devices(revoke: id))
    }

    /// Forgets the token and the pinned certificate of the current hub, then connects again.
    func forgetHub() {
        guard let hubIdentity else { return }
        HubCredentials.forget(hubIdentity)
        resetSecurityState()
        logger.info("forgot hub \(hubIdentity, privacy: .public)")
        reconnectNow()
    }

    private func resetSecurityState() {
        credentials = nil
        observedFingerprint = nil
        pinMismatch = false
        needsPairing = false
        pairing = Pairing()
        pairingPromptDismissed = false
        devices = nil
        pairingWindowUntil = nil
    }

    // MARK: Connection loop

    private func transmit(_ command: BridgeCommand, on connection: WebSocketConnection) {
        do {
            connection.send(try JSONEncoder().encode(command))
            logger.info("sent \(command.cmd, privacy: .public) to \(command.unit, privacy: .public)")
        } catch {
            logger.error("could not encode command: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        status = .idle
    }

    private func run(_ endpoint: BridgeEndpoint) async {
        var failures = 0
        while !Task.isCancelled {
            // after two failed Bonjour attempts, alternate with the typed host
            var attempt = endpoint
            if case .bonjour = endpoint, failures >= 2, failures % 2 == 0, let fallback { attempt = fallback }
            status = .connecting
            logger.info("connecting to \(attempt.label, privacy: .public)")
            do {
                try await receiveMessages(from: attempt) { failures = 0 }
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                if pinMismatch {
                    lastError = "\(attempt.label): this is not your hub (its certificate changed)"
                } else {
                    lastError = "\(attempt.label): \(error.localizedDescription)"
                }
                logger.error("connection ended: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { break }
            failures += 1
            await waitBeforeRetry(seconds: min(15, 1 << min(failures, 4)))
        }
    }

    private func receiveMessages(from endpoint: BridgeEndpoint, onOpen: () -> Void) async throws {
        let identity = endpoint.hubIdentity
        if identity != hubIdentity {
            observedFingerprint = nil
            pinMismatch = false
        }
        hubIdentity = identity
        isLocal = endpoint.isLoopback
        var secure: WebSocketConnection.SecureOptions?
        if endpoint.usesTLS {
            let saved = HubCredentials.load(for: identity)
            credentials = saved
            secure = .init(pinnedFingerprint: saved?.fingerprint, token: saved?.token)
        } else {
            credentials = nil
            needsPairing = false
        }
        sentToken = secure?.token?.isEmpty == false
        let connection = WebSocketConnection(endpoint: endpoint.nwEndpoint, secure: secure)
        self.connection = connection
        defer {
            connection.cancel()
            if self.connection === connection { self.connection = nil }
        }
        do {
            for try await data in connection.messages {
                if Task.isCancelled { return }
                if endpoint.usesTLS {
                    observedFingerprint = connection.observedFingerprint
                    pinMismatch = false
                }
                handle(data, from: endpoint, on: connection, onOpen: onOpen)
            }
        } catch {
            if connection.pinMismatch {
                pinMismatch = true
                observedFingerprint = connection.observedFingerprint
            }
            throw error
        }
        if connection.pinMismatch { pinMismatch = true }
        throw StreamEnded()
    }

    private func handle(_ data: Data, from endpoint: BridgeEndpoint, on connection: WebSocketConnection, onOpen: () -> Void) {
        let message: BridgeMessage
        do {
            message = try BridgeMessage.decode(data)
        } catch let error as BridgeMessageError {
            logger.debug("ignoring message of type \(error.type, privacy: .public)")
            return
        } catch {
            logger.error("bad frame: \(error.localizedDescription, privacy: .public)")
            return
        }
        messageCount += 1
        switch message {
        case .authRequired(let auth):
            authRequired(auth, onOpen: onOpen)
        case .paired(let paired):
            didPair(paired, on: connection)
        case .pairRefused(let reason):
            pairing.isWaiting = false
            pairing.refusal = reason.isEmpty ? "The hub said no." : reason
        case .pairing(let openUntil):
            pairingWindowUntil = Date(timeIntervalSince1970: openUntil)
        case .devices(let items):
            devices = items
        default:
            if status != .connected {
                status = .connected
                needsPairing = false
                pairing = Pairing()
                lastError = nil
                onOpen()
                logger.info("connected to \(endpoint.label, privacy: .public)")
            }
            store.apply(message)
            if case .hello = message {
                send(.messages(days: MessageStore.historyDays))     // the conversation, once per connection
                send(.brain())                                      // can the creature answer back?
            }
        }
    }

    private func authRequired(_ auth: AuthRequiredMessage, onOpen: () -> Void) {
        if sentToken, let hubIdentity {
            // the hub no longer knows our token (revoked, or its device list was reset): drop it, keep the pin
            sentToken = false
            var kept = credentials ?? HubCredentials()
            kept.token = nil
            kept.deviceID = nil
            kept.deviceName = nil
            HubCredentials.save(kept, for: hubIdentity)
            credentials = kept
            logger.warning("stored token was rejected; pairing again")
        }
        if status != .needsPairing {
            status = .needsPairing
            lastError = nil
            onOpen()
            if !needsPairing { pairingPromptDismissed = false }
            needsPairing = true
            logger.info("hub wants this device paired")
        }
        pairing.windowOpen = auth.pairingOpen ?? false
    }

    private func didPair(_ paired: PairedMessage, on connection: WebSocketConnection) {
        pairing.isWaiting = false
        guard let hubIdentity else { return }
        // The answer must come from the hub whose certificate this TLS connection verified.
        guard let observed = connection.observedFingerprint,
              let claimed = paired.fingerprint?.lowercased(),
              claimed == observed
        else {
            pairing.wrongHub = true
            pairing.refusal = "This is not your hub. Nothing was saved."
            logger.error("pairing answer fingerprint does not match the TLS certificate; ignored")
            return
        }
        let saved = HubCredentials(fingerprint: observed, token: paired.token, deviceID: paired.deviceID, deviceName: Self.deviceName)
        guard HubCredentials.save(saved, for: hubIdentity) else {
            pairing.refusal = "Could not save the pairing in the Keychain."
            logger.error("could not save hub credentials")
            return
        }
        credentials = saved
        observedFingerprint = observed
        needsPairing = false
        pairing = Pairing()
        logger.info("paired with hub \(hubIdentity, privacy: .public) as device \(paired.deviceID, privacy: .public)")
        reconnectNow()
    }

    private func waitBeforeRetry(seconds: Int) async {
        for remaining in stride(from: seconds, to: 0, by: -1) {
            status = .retrying(inSeconds: remaining)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
    }
}
