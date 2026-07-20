import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Heuristic detection of whether this device is currently connected to a
/// Tailscale network.
///
/// A third-party app on tvOS/iOS cannot query Tailscale's local API — it is
/// sandboxed to the Tailscale Network Extension. But every app *can* enumerate
/// its own network interfaces, and when the Tailscale tunnel is up the device
/// is assigned an IPv4 address in the CGNAT range `100.64.0.0/10` on a `utun`
/// interface. The presence of such an address is therefore a reliable signal
/// that this device is on a tailnet, which we use to surface Tailscale guidance
/// only when it is actually relevant.
public enum TailscaleDetector {

    /// The CGNAT range Tailscale assigns from: `100.64.0.0/10`.
    /// Network = `0x64400000`, prefix mask (/10) = `0xFFC00000`.
    private static let cgnatNetwork: UInt32 = 0x6440_0000
    private static let cgnatMask: UInt32 = 0xFFC0_0000

    /// This device's own Tailscale IPv4 address, if connected; otherwise `nil`.
    public static func localTailscaleIP() -> String? {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if addr & cgnatMask == cgnatNetwork {
                return "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Whether this device appears to be connected to Tailscale right now.
    public static func isConnected() -> Bool {
        localTailscaleIP() != nil
    }
}
