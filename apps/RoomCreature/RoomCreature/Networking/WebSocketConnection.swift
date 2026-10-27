import Foundation
import Network

final class WebSocketConnection: Sendable {
    private final class Box: @unchecked Sendable {
        let connection: NWConnection
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    struct ConnectTimeout: Error {}

    private let box: Box
    let messages: AsyncThrowingStream<Data, Error>

    init(endpoint: NWEndpoint, connectTimeout: TimeInterval = 8) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let box = Box(NWConnection(to: endpoint, using: parameters))
        self.box = box

        messages = AsyncThrowingStream { continuation in
            let queue = DispatchQueue(label: "roomcreature.websocket")
            let timeout = DispatchWorkItem {
                continuation.finish(throwing: ConnectTimeout())
            }
            box.timeout = timeout
            box.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.timeout?.cancel()
                    Self.receiveNext(box, into: continuation)
                case .waiting(let error), .failed(let error):
                    box.timeout?.cancel()
                    continuation.finish(throwing: error)
                case .cancelled:
                    box.timeout?.cancel()
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { _ in box.connection.cancel() }
            queue.asyncAfter(deadline: .now() + connectTimeout, execute: timeout)
            box.connection.start(queue: queue)
        }
    }

    func cancel() {
        box.connection.cancel()
    }

    func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        box.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private static func receiveNext(_ box: Box, into continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        box.connection.receiveMessage { data, context, _, error in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                continuation.finish()
                return
            }
            guard let data else {
                continuation.finish()
                return
            }
            if !data.isEmpty {
                continuation.yield(data)
            }
            receiveNext(box, into: continuation)
        }
    }
}
