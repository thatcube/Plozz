import Foundation
import Network
import CoreModels
import CoreNetworking

/// Discovers Jellyfin servers on the local network.
public protocol ServerDiscovering: Sendable {
    /// Streams unique `MediaServer`s as they answer, stopping after `timeout`.
    func discover(timeout: TimeInterval) -> AsyncStream<MediaServer>
}

/// UDP-broadcast based discovery — Jellyfin's native LAN announce protocol.
///
/// Broadcasts `"Who is JellyfinServer?"` to `255.255.255.255:7359` and parses
/// the JSON replies. This is the "equivalent" to Bonjour/mDNS that Jellyfin
/// actually implements server-side, so it works against stock servers with no
/// extra configuration.
public final class UDPServerDiscovery: ServerDiscovering, @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.plizz.discovery")

    public init() {
        self.port = NWEndpoint.Port(rawValue: JellyfinDiscoveryParser.discoveryPort)!
    }

    public func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        AsyncStream { continuation in
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            // Permit sending to the broadcast address.
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }

            let endpoint = NWEndpoint.hostPort(host: .ipv4(.broadcast), port: port)
            let connection = NWConnection(to: endpoint, using: params)

            // De-dupe servers that reply more than once (multiple NICs etc.).
            var seen = Set<String>()
            let lock = NSLock()

            @Sendable func emit(_ data: Data) {
                guard let server = JellyfinDiscoveryParser.parse(data) else { return }
                lock.lock(); defer { lock.unlock() }
                guard seen.insert(server.id).inserted else { return }
                PlizzLog.discovery.info("Discovered server \(server.name, privacy: .public)")
                continuation.yield(server)
            }

            func receiveLoop() {
                connection.receiveMessage { data, _, _, error in
                    if let data, !data.isEmpty { emit(data) }
                    if error == nil { receiveLoop() }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let probe = Data(JellyfinDiscoveryParser.probeMessage.utf8)
                    connection.send(content: probe, completion: .contentProcessed { _ in })
                    receiveLoop()
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Stop after the timeout window.
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                connection.cancel()
            }
        }
    }
}
