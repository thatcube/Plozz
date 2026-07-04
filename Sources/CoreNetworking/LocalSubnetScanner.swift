import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Enumerates host addresses on the device's local IPv4 LAN subnet(s), for
/// features that need to probe every nearby host over TCP/HTTP because
/// there's no broadcast-discovery protocol to listen for (unlike Jellyfin's
/// UDP announce, which `UDPServerDiscovery` handles separately with its own
/// raw-socket sweep).
///
/// Bounding rule mirrors `UDPServerDiscovery`'s own unicast sweep, but with a
/// smaller default ceiling: an HTTP probe (TCP handshake + request/response)
/// costs far more per host than firing a UDP datagram, so fully sweeping a
/// /22 (1024 hosts) the way the Jellyfin discovery does would make an
/// "empty" scan take far too long. Subnets at or under a /24 (256 addresses)
/// sweep in full; anything larger falls back to just the local /24 around
/// our own address — the overwhelmingly common real-world segment — so nearby
/// servers are still found without a pathological full-range sweep.
public enum LocalSubnetScanner {
    public static let defaultMaxSweepHosts: UInt32 = 256

    /// Given one local interface's address/netmask (host byte order, i.e.
    /// already converted from network byte order), returns the dotted-decimal
    /// host addresses to probe — excludes the network and broadcast addresses
    /// themselves, since neither is ever a connectable host.
    ///
    /// Pure and deterministic so it's unit-testable without real interfaces.
    public static func hostAddresses(
        address: UInt32,
        netmask: UInt32,
        maxSweepHosts: UInt32 = defaultMaxSweepHosts
    ) -> [String] {
        guard netmask != 0, netmask != 0xFFFF_FFFF else { return [] }
        let network = address & netmask
        let broadcast = network | ~netmask
        let span = broadcast - network // delta from network to broadcast, inclusive of broadcast
        guard span > 1 else { return [] }

        let lower: UInt32
        let upper: UInt32
        if span <= maxSweepHosts {
            lower = network
            upper = broadcast
        } else {
            // Too large to sweep fully (e.g. a /16) — still probe the local
            // /24 around our own address.
            let net24 = address & 0xFFFF_FF00
            lower = net24
            upper = net24 | 0x0000_00FF
        }

        var results: [String] = []
        results.reserveCapacity(Int(upper - lower - 1))
        var addr = lower + 1
        while addr < upper {
            results.append(dottedDecimal(addr))
            addr += 1
        }
        return results
    }

    /// `a.b.c.d` for a host-byte-order IPv4 address.
    static func dottedDecimal(_ addr: UInt32) -> String {
        "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
    }

    #if canImport(Darwin)
    /// Active, non-loopback, non-point-to-point IPv4 interfaces on this
    /// device, as (address, netmask) in HOST byte order, ready for
    /// ``hostAddresses(address:netmask:maxSweepHosts:)``.
    public static func localIPv4Interfaces() -> [(address: UInt32, netmask: UInt32)] {
        var result: [(UInt32, UInt32)] = []
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
                  let nm = cur.pointee.ifa_netmask else { continue }

            let address = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            result.append((address, netmask))
        }
        return result
    }

    /// Every host address across all local IPv4 interfaces, deduplicated,
    /// preserving discovery order.
    public static func allHostAddresses(maxSweepHosts: UInt32 = defaultMaxSweepHosts) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for iface in localIPv4Interfaces() {
            for host in hostAddresses(address: iface.address, netmask: iface.netmask, maxSweepHosts: maxSweepHosts) where seen.insert(host).inserted {
                ordered.append(host)
            }
        }
        return ordered
    }
    #else
    public static func localIPv4Interfaces() -> [(address: UInt32, netmask: UInt32)] { [] }
    public static func allHostAddresses(maxSweepHosts: UInt32 = defaultMaxSweepHosts) -> [String] { [] }
    #endif
}
