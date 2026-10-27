import Foundation
import Observation
import os

@MainActor @Observable
final class BridgeClient {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case retrying(inSeconds: Int)

        var text: String {
            switch self {
            case .idle: "Not connected"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .retrying(let seconds): "Retrying in \(seconds) s"
            }
        }
    }

    private struct StreamEnded: Error {}

    private(set) var status: Status = .idle
    private(set) var target: BridgeEndpoint?
    /// Used when a Bonjour endpoint keeps failing: the host and port typed in Settings.
    var fallback: BridgeEndpoint?
    private(set) var lastError: String?
    private(set) var messageCount = 0

    private let store: RoomStore
    private let logger = Logger(subsystem: "com.harshsah.roomcreature", category: "bridge")
    private var loop: Task<Void, Never>?
    private var connection: WebSocketConnection?

    init(store: RoomStore) {
        self.store = store
    }

    func connect(to endpoint: BridgeEndpoint) {
        if endpoint == target, loop != nil { return }
        stop()
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
                lastError = "\(attempt.label): \(error.localizedDescription)"
                logger.error("connection ended: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { break }
            failures += 1
            await waitBeforeRetry(seconds: min(15, 1 << min(failures, 4)))
        }
    }

    private func receiveMessages(from endpoint: BridgeEndpoint, onOpen: () -> Void) async throws {
        let connection = WebSocketConnection(endpoint: endpoint.nwEndpoint)
        self.connection = connection
        defer {
            connection.cancel()
            self.connection = nil
        }
        for try await data in connection.messages {
            if status != .connected {
                status = .connected
                lastError = nil
                onOpen()
                logger.info("connected to \(endpoint.label, privacy: .public)")
            }
            handle(data)
        }
        throw StreamEnded()
    }

    private func handle(_ data: Data) {
        do {
            let message = try BridgeMessage.decode(data)
            store.apply(message)
            messageCount += 1
            if case .hello = message {
                send(.messages(days: MessageStore.historyDays))     // the conversation, once per connection
            }
        } catch let error as BridgeMessageError {
            logger.debug("ignoring message of type \(error.type, privacy: .public)")
        } catch {
            logger.error("bad frame: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func waitBeforeRetry(seconds: Int) async {
        for remaining in stride(from: seconds, to: 0, by: -1) {
            status = .retrying(inSeconds: remaining)
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
    }
}
