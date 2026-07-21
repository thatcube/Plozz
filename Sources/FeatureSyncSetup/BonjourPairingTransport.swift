import Foundation
import Network
import CoreModels

// MARK: - Bonjour pairing transport (Network.framework)
//
// Production byte transport for the non-secret config handoff. The target (e.g.
// Apple TV) advertises `_plozz-pair._tcp` under a random service name that is also
// embedded in its QR invite; the source (phone) connects to that exact service
// name — which it learned by scanning — and sends the sealed payload. Bonjour
// discovery here is only "a TV is waiting"; the key material comes from the QR
// (see SyncPairingInvite), so a LAN bystander can't seal to the TV.
//
// This mirrors the validated on-device probe (real Apple TV discovered in 0.009s).
// It carries ONLY a SealedSyncPayload of the non-secret snapshot in v1.

public let kPlozzPairingServiceType = "_plozz-pair._tcp"

public enum BonjourPairingError: Error, Equatable {
    case listenerFailed
    case connectionFailed
    case framing
    case timedOut
}

private enum Framing {
    /// UInt32 big-endian length prefix + JSON bytes.
    static func encode(_ payload: SealedSyncPayload) throws -> Data {
        let body = try JSONEncoder().encode(payload)
        var len = UInt32(body.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(body)
        return out
    }
}

/// Target/receiver side: advertise a service and receive one sealed payload.
public final class BonjourPairingResponder: PairingReceiving, @unchecked Sendable {
    public let serviceName: String
    private let queue = DispatchQueue(label: "plozz.pair.responder")
    private var listener: NWListener?

    public init(serviceName: String = "Plozz-\(Int.random(in: 1000...9999))") {
        self.serviceName = serviceName
    }

    public func receive() async throws -> SealedSyncPayload {
        try await withCheckedThrowingContinuation { cont in
            let once = OnceBox(cont)
            do {
                let params = NWParameters.tcp
                params.includePeerToPeer = true
                let l = try NWListener(using: params)
                l.service = NWListener.Service(name: serviceName, type: kPlozzPairingServiceType)
                l.stateUpdateHandler = { st in
                    if case .failed = st { once.fail(BonjourPairingError.listenerFailed) }
                }
                l.newConnectionHandler = { [queue] conn in
                    conn.stateUpdateHandler = { st in
                        if case .failed = st { once.fail(BonjourPairingError.connectionFailed) }
                    }
                    conn.start(queue: queue)
                    Self.readFrame(on: conn, into: once)
                }
                l.start(queue: queue)
                self.listener = l
            } catch {
                once.fail(BonjourPairingError.listenerFailed)
            }
        }
    }

    private static func readFrame(on conn: NWConnection, into once: OnceBox) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, err in
            guard err == nil, let header, header.count == 4 else { once.fail(BonjourPairingError.framing); return }
            let len = header.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            guard len > 0, len < 1_000_000 else { once.fail(BonjourPairingError.framing); return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err in
                guard err == nil, let body, body.count == len,
                      let payload = try? JSONDecoder().decode(SealedSyncPayload.self, from: body) else {
                    once.fail(BonjourPairingError.framing); return
                }
                once.succeed(payload)
                conn.cancel()
            }
        }
    }

    public func stop() { listener?.cancel(); listener = nil }
}

/// Source/sender side: connect to a known service name and send one sealed payload.
public final class BonjourPairingInitiator: PairingSending, @unchecked Sendable {
    public let serviceName: String
    private let queue = DispatchQueue(label: "plozz.pair.initiator")

    public init(serviceName: String) { self.serviceName = serviceName }

    public func send(_ payload: SealedSyncPayload) async throws {
        let frame = try Framing.encode(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceVoidBox(cont)
            let endpoint = NWEndpoint.service(name: serviceName, type: kPlozzPairingServiceType, domain: "local.", interface: nil)
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let conn = NWConnection(to: endpoint, using: params)
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    conn.send(content: frame, completion: .contentProcessed { err in
                        if err != nil { once.fail(BonjourPairingError.connectionFailed) }
                        else { once.succeed() }
                        conn.cancel()
                    })
                case .failed, .cancelled:
                    once.fail(BonjourPairingError.connectionFailed)
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }
}

// One-shot continuation guards (Network callbacks may fire more than once).
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<SealedSyncPayload, Error>
    init(_ cont: CheckedContinuation<SealedSyncPayload, Error>) { self.cont = cont }
    func succeed(_ v: SealedSyncPayload) { fire { cont.resume(returning: v) } }
    func fail(_ e: Error) { fire { cont.resume(throwing: e) } }
    private func fire(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; block()
    }
}

private final class OnceVoidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<Void, Error>
    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }
    func succeed() { fire { cont.resume(returning: ()) } }
    func fail(_ e: Error) { fire { cont.resume(throwing: e) } }
    private func fire(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; block()
    }
}
