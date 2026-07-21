import Foundation
import Network
import CoreModels

// MARK: - Bonjour pairing transport (Network.framework, bidirectional)
//
// Production byte transport for the pairing handoff. The target advertises
// `_plozz-pair._tcp` under a service name equal to the short pairing code; the
// source connects to that service name (learned from the QR or the typed code).
// Both then exchange framed messages over one NWConnection: target sends its
// invite, source sends the sealed bundle.

public let kPlozzPairingServiceType = "_plozz-pair._tcp"

public enum BonjourPairingError: Error, Equatable {
    case listenerFailed
    case connectionFailed
    case framing
    case timedOut
}

/// A PairingLink backed by a single NWConnection with UInt32-length-prefixed frames.
public final class NWConnectionPairingLink: PairingLink, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(_ data: Data) async throws {
        var len = UInt32(data.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { err in
                if err != nil { cont.resume(throwing: BonjourPairingError.connectionFailed) }
                else { cont.resume(returning: ()) }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await receiveExactly(4)
        let len = header.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
        guard len > 0, len < 5_000_000 else { throw BonjourPairingError.framing }
        return try await receiveExactly(len)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, err in
                if err != nil { cont.resume(throwing: BonjourPairingError.connectionFailed); return }
                guard let data, data.count == count else { cont.resume(throwing: BonjourPairingError.framing); return }
                cont.resume(returning: data)
            }
        }
    }

    public func close() { connection.cancel() }
}

/// Target/host: advertise a service and accept one incoming connection.
public final class BonjourPairingHost: @unchecked Sendable {
    public let serviceName: String
    private let queue = DispatchQueue(label: "plozz.pair.host")
    private var listener: NWListener?

    public init(serviceName: String) { self.serviceName = serviceName }

    /// Advertise and wait for the first connection, returning a link over it.
    public func awaitConnection() async throws -> PairingLink {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PairingLink, Error>) in
            let once = Once()
            do {
                let params = NWParameters.tcp
                params.includePeerToPeer = true
                let l = try NWListener(using: params)
                l.service = NWListener.Service(name: serviceName, type: kPlozzPairingServiceType)
                l.stateUpdateHandler = { st in
                    if case .failed = st { once.run { cont.resume(throwing: BonjourPairingError.listenerFailed) } }
                }
                l.newConnectionHandler = { [queue] conn in
                    conn.stateUpdateHandler = { st in
                        if case .ready = st {
                            once.run { cont.resume(returning: NWConnectionPairingLink(connection: conn)) }
                        }
                        if case .failed = st {
                            once.run { cont.resume(throwing: BonjourPairingError.connectionFailed) }
                        }
                    }
                    conn.start(queue: queue)
                }
                l.start(queue: queue)
                self.listener = l
            } catch {
                once.run { cont.resume(throwing: BonjourPairingError.listenerFailed) }
            }
        }
    }

    public func stop() { listener?.cancel(); listener = nil }
}

/// Source/guest: connect to a known service name, returning a link over it.
public final class BonjourPairingGuest: @unchecked Sendable {
    public let serviceName: String
    private let queue = DispatchQueue(label: "plozz.pair.guest")

    public init(serviceName: String) { self.serviceName = serviceName }

    public func connect() async throws -> PairingLink {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PairingLink, Error>) in
            let once = Once()
            let endpoint = NWEndpoint.service(name: serviceName, type: kPlozzPairingServiceType, domain: "local.", interface: nil)
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let conn = NWConnection(to: endpoint, using: params)
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    once.run { cont.resume(returning: NWConnectionPairingLink(connection: conn)) }
                case .failed, .cancelled:
                    once.run { cont.resume(throwing: BonjourPairingError.connectionFailed) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }
}

/// One-shot continuation guard (Network callbacks may fire more than once).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; block()
    }
}
