import Foundation
import CoreModels
import CoreNetworking
#if canImport(Darwin)
import Darwin

/// LAN discovery for Jellyfin servers.
///
/// Jellyfin's native auto-discovery is a UDP request/response on port 7359: the
/// client sends `"Who is JellyfinServer?"` and each server replies with a small
/// JSON announcement. This implementation deliberately uses BSD sockets rather
/// than `Network.framework` for two reasons:
///
///  1. **Receiving replies.** A `NWConnection` "to" the broadcast address is a
///     *connected* UDP flow, so datagrams arriving from a server's own unicast
///     address are filtered out and never delivered. A plain unconnected socket
///     with `recvfrom` accepts replies from any source.
///  2. **Avoiding the multicast entitlement.** Sending to a broadcast address on
///     tvOS/iOS 14+ requires `com.apple.developer.networking.multicast`, which
///     in turn forces TestFlight/App-Store-only distribution. Jellyfin servers
///     answer *unicast* probes too, so we sweep each host on the local subnet
///     with unicast packets — which only needs the Local Network permission —
///     and additionally try broadcast as a best-effort (it simply no-ops when
///     the entitlement is absent).
public final class UDPServerDiscovery: ServerDiscovering, @unchecked Sendable {
    /// Largest subnet we will unicast-sweep host-by-host. `/22` (1024 hosts)
    /// comfortably covers home networks while avoiding a pathological sweep of a
    /// `/16`. Larger subnets fall back to broadcast only.
    private let maxSweepHosts: UInt32

    /// Validates discovery candidates over HTTP so we surface the URL that
    /// actually answers (handles https / custom ports / reverse proxies and
    /// servers advertising a foreign address). Uses a short-timeout session so
    /// trying several candidates per server stays fast.
    private let validator: ServerValidator
    private let provider: ProviderKind

    public init(
        provider: ProviderKind = .jellyfin,
        maxSweepHosts: UInt32 = 1024,
        validator: ServerValidator? = nil
    ) {
        self.provider = provider
        self.maxSweepHosts = maxSweepHosts
        self.validator = validator ?? ServerValidator(
            provider: provider,
            http: URLSessionHTTPClient(session: .plozzDiscovery)
        )
    }

    public func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        let maxSweepHosts = self.maxSweepHosts
        let validator = self.validator
        let provider = self.provider

        return AsyncStream { continuation in
            let cancelled = AtomicFlag()

            let task = Task {
                // Validate each announcement's candidates concurrently so a slow
                // (or wrong) candidate for one server never holds up another.
                await withTaskGroup(of: Void.self) { group in
                    let stream = Self.announcements(
                        timeout: timeout,
                        maxSweepHosts: maxSweepHosts,
                        provider: provider,
                        cancelled: cancelled
                    )
                    for await announcement in stream {
                        if Task.isCancelled { break }
                        group.addTask {
                            if let server = await Self.resolve(announcement, validator: validator) {
                                continuation.yield(server)
                            }
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                cancelled.set()
                task.cancel()
            }
        }
    }

    // MARK: - Candidate resolution

    /// Probes an announcement's candidate URLs in priority order and returns the
    /// first that a Jellyfin server actually answers on. If none answer in time
    /// (slow server, HTTP blocked, …) the best-effort first candidate is still
    /// surfaced — the server clearly exists, so the user shouldn't see "nothing".
    private static func resolve(
        _ announcement: JellyfinAnnouncement,
        validator: ServerValidator
    ) async -> MediaServer? {
        for url in announcement.candidateURLs {
            if Task.isCancelled { return nil }
            if let server = try? await validator.validate(rawURL: url.absoluteString) {
                PlozzLog.discovery.info("Validated \(server.name) at \(server.baseURL.absoluteString)")
                return server
            }
        }
        if let server = announcement.primaryServer {
            PlozzLog.discovery.info("No candidate validated; surfacing best-effort \(server.name)")
            return server
        }
        return nil
    }

    // MARK: - Announcement stream

    /// Bridges the blocking BSD-socket loop (run on a background queue) into an
    /// `AsyncStream` of parsed, de-duplicated announcements.
    private static func announcements(
        timeout: TimeInterval,
        maxSweepHosts: UInt32,
        provider: ProviderKind,
        cancelled: AtomicFlag
    ) -> AsyncStream<JellyfinAnnouncement> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.plozz.discovery.socket")
            queue.async {
                Self.run(
                    timeout: timeout,
                    maxSweepHosts: maxSweepHosts,
                    provider: provider,
                    cancelled: cancelled
                ) { announcement in
                    continuation.yield(announcement)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Socket loop

    private static func run(
        timeout: TimeInterval,
        maxSweepHosts: UInt32,
        provider: ProviderKind,
        cancelled: AtomicFlag,
        yield: (JellyfinAnnouncement) -> Void
    ) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            PlozzLog.discovery.error("Discovery socket() failed (errno \(errno))")
            return
        }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Short receive timeout so the loop can re-probe and notice cancellation.
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind an ephemeral local port so replies have somewhere to land.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = INADDR_ANY
        local.sin_port = 0
        _ = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let targets = Self.probeTargets(maxSweepHosts: maxSweepHosts)
        let probe = Array(JellyfinDiscoveryParser.probeMessage(for: provider).utf8)
        PlozzLog.discovery.info("Discovery probing \(targets.count) target(s)")

        func sendProbes() {
            for target in targets {
                var dst = sockaddr_in()
                dst.sin_family = sa_family_t(AF_INET)
                dst.sin_port = JellyfinDiscoveryParser.discoveryPort.bigEndian
                dst.sin_addr.s_addr = target
                _ = probe.withUnsafeBytes { raw in
                    withUnsafePointer(to: &dst) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(timeout)
        var lastProbe = Date()
        sendProbes()

        var buffer = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline && !cancelled.isSet {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }

            if n > 0 {
                let data = Data(buffer[0..<n])
                let sourceIP = Self.ipString(from: from)
                if let announcement = JellyfinDiscoveryParser.parse(
                    data,
                    sourceIP: sourceIP,
                    provider: provider
                ),
                   seen.insert(announcement.id).inserted {
                    PlozzLog.discovery.info(
                        "Announce \(announcement.name) — \(announcement.candidateURLs.count) candidate(s)"
                    )
                    yield(announcement)
                }
            }

            // Re-probe roughly once a second to ride out dropped UDP packets.
            if Date().timeIntervalSince(lastProbe) > 1 {
                sendProbes()
                lastProbe = Date()
            }
        }
    }

    // MARK: - Targets

    /// Builds the set of destination addresses (network byte order) to probe:
    /// every host on each local IPv4 subnet (unicast sweep), each subnet's
    /// directed broadcast, and the limited broadcast `255.255.255.255`.
    private static func probeTargets(maxSweepHosts: UInt32) -> [in_addr_t] {
        var targets: [in_addr_t] = []
        var seen = Set<in_addr_t>()
        func append(_ addr: in_addr_t) {
            if seen.insert(addr).inserted { targets.append(addr) }
        }

        for iface in localIPv4Interfaces() {
            let host = UInt32(bigEndian: iface.address)
            let mask = UInt32(bigEndian: iface.netmask)
            guard mask != 0 else { continue }
            let network = host & mask
            let broadcast = network | ~mask
            let hostCount = broadcast - network  // excludes network + broadcast

            if hostCount > 1 && hostCount <= maxSweepHosts {
                var addr = network + 1
                while addr < broadcast {
                    append(in_addr_t(addr).bigEndian)
                    addr += 1
                }
            } else if hostCount > maxSweepHosts {
                // Subnet too large to sweep fully (e.g. a /16). Still unicast the
                // local /24 around our own address — the overwhelmingly common
                // real-world segment — so a nearby server is found without a
                // pathological full-range sweep.
                let net24 = host & 0xFFFF_FF00
                let bcast24 = net24 | 0x0000_00FF
                var addr = net24 + 1
                while addr < bcast24 {
                    append(in_addr_t(addr).bigEndian)
                    addr += 1
                }
            }
            append(in_addr_t(broadcast).bigEndian)
        }

        append(INADDR_BROADCAST)  // 255.255.255.255 (byte-order agnostic)
        return targets
    }

    private struct Interface { let address: in_addr_t; let netmask: in_addr_t }

    /// Active, broadcast-capable, non-loopback IPv4 LAN interfaces and their
    /// netmasks. Point-to-point links (VPN tunnels, cellular) are skipped: a
    /// unicast LAN sweep over them is meaningless and a broadcast is undeliverable.
    private static func localIPv4Interfaces() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0,
                  (flags & IFF_BROADCAST) != 0,
                  let nm = cur.pointee.ifa_netmask else { continue }

            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            result.append(Interface(address: address, netmask: netmask))
        }
        return result
    }

    private static func ipString(from addr: sockaddr_in) -> String {
        var sin = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

/// Minimal thread-safe flag for signalling cancellation into the socket loop.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

#endif
