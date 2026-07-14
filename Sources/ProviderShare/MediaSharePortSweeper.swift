import Foundation
import CoreModels
import CoreNetworking

/// One physical device (a "box") on the network, grouped from the per-transport
/// services discovered for its host. The onboarding UI lists boxes (one row per
/// device), then a box's doors become the Protocol options on the Connect form.
public struct DiscoveredMediaShareBox: Sendable, Hashable, Identifiable {
    /// A door into the box: a transport reachable on this host, and the port it
    /// was found on (`nil` = the transport default).
    public struct Door: Sendable, Hashable {
        public let transport: MediaShareTransportKind
        public let port: Int?
        public init(transport: MediaShareTransportKind, port: Int?) {
            self.transport = transport
            self.port = port
        }
    }

    public let host: String
    public let displayName: String
    public private(set) var doors: [Door]

    public var id: String { host.lowercased() }

    public init(host: String, displayName: String, doors: [Door]) {
        self.host = host
        self.displayName = displayName
        self.doors = doors
    }

    /// Merge a door in, de-duping on transport (a box lists each transport once;
    /// keeps the first-seen port unless the new one is more specific).
    mutating func addDoor(_ door: Door) {
        if let idx = doors.firstIndex(where: { $0.transport == door.transport }) {
            if doors[idx].port == nil, door.port != nil { doors[idx] = door }
        } else {
            doors.append(door)
        }
    }
}

/// Groups a flat stream of `DiscoveredNetworkService`s into per-host boxes, so a
/// device that advertised several transports (or several records) shows up once.
public struct MediaShareBoxGrouping {
    /// Fold services into boxes keyed by lowercased host, preserving first-seen
    /// display name and order.
    public static func group(_ services: [DiscoveredNetworkService]) -> [DiscoveredMediaShareBox] {
        var order: [String] = []
        var byHost: [String: DiscoveredMediaShareBox] = [:]
        for service in services {
            let key = service.host.lowercased()
            let door = DiscoveredMediaShareBox.Door(transport: service.transport, port: service.port)
            if var box = byHost[key] {
                box.addDoor(door)
                byHost[key] = box
            } else {
                order.append(key)
                byHost[key] = DiscoveredMediaShareBox(
                    host: service.host,
                    displayName: service.name.isEmpty ? service.host : service.name,
                    doors: [door]
                )
            }
        }
        return order.compactMap { byHost[$0] }
    }
}

/// One transport's worth of ports to sweep on an already-known host (Channel B).
public struct TransportSweepSpec: Sendable {
    public let transport: MediaShareTransportKind
    public let ports: [Int]
    public let defaultPort: Int
    public init(transport: MediaShareTransportKind, ports: [Int], defaultPort: Int) {
        self.transport = transport
        self.ports = ports
        self.defaultPort = defaultPort
    }
}

/// Probes whether a TCP port is open on a host. Injectable so the sweep is
/// unit-testable offline; the default implementation does a real short-timeout
/// TCP connect.
public protocol MediaSharePortProbing: Sendable {
    func isOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool
}

/// Curated port sweep on a KNOWN host (Channel B, §1.1): probe each transport's
/// curated ports in parallel and report which doors answered. Bounded to the
/// curated list — never a full 65k scan (which is slow when firewalled and reads
/// as a port scan). This is how a box that didn't Bonjour-advertise a transport
/// (e.g. Unraid WebDAV on :8384) still gets found without the user typing it.
public struct MediaSharePortSweeper: Sendable {
    private let probe: any MediaSharePortProbing
    private let timeout: TimeInterval

    public init(probe: any MediaSharePortProbing = TCPConnectProbe(), timeout: TimeInterval = 1.5) {
        self.probe = probe
        self.timeout = timeout
    }

    /// Returns the doors found on `host` across the given specs. A port equal to
    /// the transport default is reported with `port == nil` (implicit).
    public func sweep(host: String, specs: [TransportSweepSpec]) async -> [DiscoveredMediaShareBox.Door] {
        await withTaskGroup(of: DiscoveredMediaShareBox.Door?.self) { group in
            for spec in specs {
                for port in spec.ports {
                    group.addTask { [probe, timeout] in
                        guard await probe.isOpen(host: host, port: port, timeout: timeout) else { return nil }
                        return DiscoveredMediaShareBox.Door(
                            transport: spec.transport,
                            port: port == spec.defaultPort ? nil : port
                        )
                    }
                }
            }
            var found: [DiscoveredMediaShareBox.Door] = []
            for await door in group {
                if let door, !found.contains(door) { found.append(door) }
            }
            return found
        }
    }
}

#if canImport(Network)
import Network

/// Real TCP-connect probe: opens an `NWConnection`, reports `.ready` within the
/// timeout as "open". Credential-free and side-effect-free.
public struct TCPConnectProbe: MediaSharePortProbing {
    public init() {}

    public func isOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
            return false
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        let box = ProbeBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            box.attach(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.finish(true)
                case .failed, .cancelled: box.finish(false)
                default: break
                }
            }
            let queue = DispatchQueue(label: "com.plozz.portprobe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { box.finish(false) }
        }
    }

    /// Serialises the single-shot resume + connection teardown.
    private final class ProbeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var connection: NWConnection?

        func attach(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
            lock.lock(); self.continuation = continuation; self.connection = connection; lock.unlock()
        }
        func finish(_ value: Bool) {
            lock.lock()
            let c = continuation; continuation = nil
            let conn = connection; connection = nil
            lock.unlock()
            conn?.cancel()
            c?.resume(returning: value)
        }
    }
}
#else
public struct TCPConnectProbe: MediaSharePortProbing {
    public init() {}
    public func isOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool { false }
}
#endif
