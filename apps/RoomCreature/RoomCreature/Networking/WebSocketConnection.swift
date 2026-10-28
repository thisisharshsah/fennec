import CryptoKit
import Foundation
import Network
import os
import Security

final class WebSocketConnection: Sendable {
    /// TLS with a pinned certificate. With no pin (first contact) any certificate is accepted and
    /// its fingerprint is kept in `observedFingerprint`, so pairing can pin it.
    struct SecureOptions: Sendable {
        var pinnedFingerprint: String?
        var token: String?
    }

    /// What the TLS handshake saw, written on the connection's queue and read on the main actor.
    private struct Observed: Sendable {
        var fingerprint: String?
        var pinMismatch = false
    }

    private final class Box: @unchecked Sendable {
        let connection: NWConnection
        var timeout: DispatchWorkItem?
        let observed: OSAllocatedUnfairLock<Observed>
        init(_ connection: NWConnection, observed: OSAllocatedUnfairLock<Observed>) {
            self.connection = connection
            self.observed = observed
        }
    }

    struct ConnectTimeout: Error {}

    private let box: Box
    let messages: AsyncThrowingStream<Data, Error>

    /// SHA-256 of the leaf certificate the hub presented, lowercase hex (TLS only).
    var observedFingerprint: String? { box.observed.withLock { $0.fingerprint } }
    /// True when the hub presented a certificate other than the pinned one.
    var pinMismatch: Bool { box.observed.withLock { $0.pinMismatch } }

    init(endpoint: NWEndpoint, secure: SecureOptions? = nil, connectTimeout: TimeInterval = 8) {
        let queue = DispatchQueue(label: "roomcreature.websocket")
        let observed = OSAllocatedUnfairLock(initialState: Observed())
        let parameters: NWParameters
        if let secure {
            let tls = NWProtocolTLS.Options()
            let pin = secure.pinnedFingerprint?.lowercased()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let fingerprint = Self.leafFingerprint(sec_trust_copy_ref(trust).takeRetainedValue())
                let accepted = fingerprint != nil && (pin == nil || fingerprint == pin)
                observed.withLock {
                    $0.fingerprint = fingerprint
                    $0.pinMismatch = !accepted
                }
                complete(accepted)
            }, queue)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        parameters.includePeerToPeer = false
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        if let token = secure?.token, !token.isEmpty {
            options.setAdditionalHeaders([(name: "Authorization", value: "Bearer \(token)")])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let box = Box(NWConnection(to: endpoint, using: parameters), observed: observed)
        self.box = box

        messages = AsyncThrowingStream { continuation in
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

    /// SHA-256 of the DER of the first certificate in the chain, lowercase hex.
    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
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
