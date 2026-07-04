import Foundation
import CoreNetworking

/// A Seerr (Overseerr / Jellyseerr) instance found on the local network.
public struct DiscoveredSeerServer: Sendable, Hashable, Identifiable {
    /// Bare origin, e.g. `http://192.168.1.42:5055` — ready to hand straight
    /// to ``SeerConfig/init(baseURL:apiKey:userId:)``.
    public let baseURL: URL
    /// Seerr's reported version (from `/api/v1/status`), for display only.
    public let version: String?

    public init(baseURL: URL, version: String?) {
        self.baseURL = baseURL
        self.version = version
    }

    public var id: String { baseURL.absoluteString }
}

/// Finds Seerr servers on the local network.
///
/// Unlike Jellyfin (a UDP broadcast responder, see `UDPServerDiscovery`) or
/// SMB shares (Bonjour's `_smb._tcp`), Overseerr/Jellyseerr has **no announce
/// protocol at all** — a stock install just binds a port with nothing
/// listening for probes. So discovery here means going and looking:
///
/// 1. Probe any `hostHints` first (already-known Jellyfin/Plex/Emby server
///    hosts, if the caller has them) — Seerr is very commonly co-hosted on
///    the same box as the media server it manages, so this is often an
///    instant, single-request hit.
/// 2. Fall back to a bounded unicast sweep of the local subnet (see
///    ``LocalSubnetScanner``), probing Seerr's default port.
///
/// Each candidate is confirmed by its unauthenticated `GET /api/v1/status` —
/// no API key needed to *find* a server, only to connect to one.
public final class SeerDiscovery: Sendable {
    private let http: HTTPClient
    private let port: Int
    private let concurrency: Int
    /// Produces the subnet-sweep candidate list. Defaults to the real local
    /// LAN via ``LocalSubnetScanner``; injectable so tests can supply a fixed
    /// list instead of depending on the test machine's actual interfaces.
    private let subnetHosts: @Sendable () -> [String]

    /// How long Foundation allows a single probe to run (mirrors
    /// `URLSession.plozzDiscovery`'s resource timeout). Used to size the
    /// default `discover` timeout from the candidate count so a full sweep
    /// isn't cut off before every host has had a chance to respond.
    private static let perProbeTimeout: TimeInterval = 3

    public init(
        http: HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery),
        port: Int = 5055,
        concurrency: Int = 48,
        subnetHosts: @escaping @Sendable () -> [String] = { LocalSubnetScanner.allHostAddresses() }
    ) {
        self.http = http
        self.port = port
        self.concurrency = concurrency
        self.subnetHosts = subnetHosts
    }

    /// Streams unique servers as they're confirmed. `hostHints` (bare hosts,
    /// no scheme/port — e.g. already-known Jellyfin hosts) are probed first
    /// and are deduplicated against the subnet sweep. Finishes once every
    /// candidate has been probed or `timeout` elapses, whichever is first.
    ///
    /// When `timeout` is `nil` (the default), it's derived from the
    /// candidate count and `concurrency` so a full sweep always has time to
    /// finish — `waves * perProbeTimeout + margin`, where `waves` is how many
    /// batches of `concurrency` probes are needed to cover every candidate.
    /// A fixed default (e.g. 8s) would cut off most of a /24 sweep: at
    /// concurrency 48 that's ~6 waves × up to 3s each, well past 8s.
    public func discover(hostHints: [String] = [], timeout: TimeInterval? = nil) -> AsyncStream<DiscoveredSeerServer> {
        AsyncStream { continuation in
            var seen = Set<String>()
            let hints = hostHints.filter { seen.insert($0).inserted }
            let swept = subnetHosts().filter { seen.insert($0).inserted }
            let candidates = hints + swept

            guard !candidates.isEmpty else {
                continuation.finish()
                return
            }

            let waves = (candidates.count + concurrency - 1) / concurrency
            let resolvedTimeout = timeout ?? (Double(waves) * Self.perProbeTimeout + 2)

            let work = Task { [http, port, concurrency] in
                await withTaskGroup(of: DiscoveredSeerServer?.self) { group in
                    var nextIndex = 0
                    func dispatchNext() {
                        // Cancellation-aware: once the timeout fires (or the
                        // stream's consumer disappears), stop spooling up new
                        // tasks for the remaining candidates instead of
                        // burning through all of them just to have each
                        // immediately no-op on `Task.isCancelled`.
                        guard !Task.isCancelled, nextIndex < candidates.count else { return }
                        let host = candidates[nextIndex]
                        nextIndex += 1
                        group.addTask { await Self.probe(host: host, port: port, http: http) }
                    }

                    while nextIndex < min(concurrency, candidates.count) {
                        dispatchNext()
                    }
                    while let result = await group.next() {
                        if let server = result, !Task.isCancelled {
                            continuation.yield(server)
                        }
                        dispatchNext()
                    }
                }
                continuation.finish()
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, resolvedTimeout) * 1_000_000_000))
                work.cancel()
            }

            continuation.onTermination = { _ in
                work.cancel()
                timeoutTask.cancel()
            }
        }
    }

    /// Probes one host:port for an unauthenticated `/api/v1/status`. Rejects
    /// anything that isn't shaped like a Seerr response (guards against some
    /// unrelated device answering 200 with arbitrary JSON on this port).
    private static func probe(host: String, port: Int, http: HTTPClient) async -> DiscoveredSeerServer? {
        guard !Task.isCancelled else { return nil }
        // Bare IPv6 addresses (e.g. from a known server's `URL.host`, which
        // strips brackets) must be re-bracketed before a port can follow —
        // "http://fd00::1:5055" is not a valid URL, but "http://[fd00::1]:5055" is.
        let hostComponent = host.contains(":") ? "[\(host)]" : host
        guard let baseURL = URL(string: "http://\(hostComponent):\(port)") else { return nil }
        let endpoint = Endpoint(method: .get, path: "/api/v1/status")
        do {
            let status = try await http.decode(SeerStatus.self, from: endpoint, baseURL: baseURL)
            guard let version = status.version, !version.isEmpty else { return nil }
            return DiscoveredSeerServer(baseURL: baseURL, version: version)
        } catch {
            return nil
        }
    }
}
