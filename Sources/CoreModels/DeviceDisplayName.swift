import Foundation

/// Derives a friendly, user-recognizable device name — WITHOUT blocking the main
/// thread or triggering a local-network permission prompt.
///
/// `UIDevice.current.name` returns only a generic model name ("iPad", "iPhone",
/// "Apple TV") on iOS/tvOS 16+ unless the app holds the Apple-managed
/// `user-assigned-device-name` entitlement. The device's host name still reflects the
/// name the owner gave it ("Brando's iPad" -> host `Brandos-iPad`), so we prettify that
/// into a display name.
///
/// IMPORTANT: `ProcessInfo.processInfo.hostName` must NEVER be read on the main thread.
/// It performs a *blocking* reverse-DNS/mDNS resolution (`-[NSHost blockingResolveUntil:]`)
/// that can stall for ~20s on a fresh device — long enough to trip the app-launch
/// watchdog (0x8BADF00D) — and the mDNS lookup is also what raises the "allow local
/// network" prompt. So the synchronous accessor here uses the POSIX `gethostname()`
/// (a non-blocking kernel string, no network, no prompt), and only falls back to a
/// *background* `ProcessInfo.hostName` refresh when that isn't informative.
public enum DeviceDisplayName {
    private static let cacheKey = "com.plozz.deviceDisplayName.cached.v1"

    /// Non-blocking friendly device name. Order of preference:
    ///   1. A previously cached resolution (from the background refresh below).
    ///   2. The POSIX host name via `gethostname()` — no network, no permission prompt.
    ///   3. `fallback` (e.g. `UIDevice.current.name` on iOS, "Apple TV" on tvOS),
    ///      while a one-shot background task resolves `ProcessInfo.hostName` and caches
    ///      it for next time.
    /// Safe to call from the main thread and during `init()` / scene creation.
    public static func current(
        fallback: @autoclosure () -> String,
        defaults: UserDefaults = .standard
    ) -> String {
        if let cached = defaults.string(forKey: cacheKey), !cached.isEmpty {
            return cached
        }
        let fb = fallback()
        if let posix = posixHostName() {
            let pretty = fromHostName(posix, fallback: fb)
            if pretty != fb {
                defaults.set(pretty, forKey: cacheKey)
                return pretty
            }
        }
        // gethostname wasn't informative (e.g. "localhost"); resolve off-main so the
        // blocking lookup can't stall launch, and cache for subsequent reads.
        scheduleBackgroundRefresh(fallback: fb, defaults: defaults)
        return fb
    }

    /// The non-blocking kernel host name (`gethostname(2)`), or nil when unavailable
    /// or uninformative. Does NOT touch the network and never prompts for local-network
    /// permission (unlike `ProcessInfo.hostName`, which does reverse-DNS).
    private static func posixHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "localhost" else { return nil }
        return name
    }

    private static let refreshFlag = NSLock()
    private static var refreshStarted = false

    /// Resolve `ProcessInfo.hostName` (blocking) on a background queue exactly once and
    /// cache the prettified result, so a future `current(...)` can return it without
    /// blocking. Off the main thread, a stall here is harmless.
    private static func scheduleBackgroundRefresh(fallback: String, defaults: UserDefaults) {
        refreshFlag.lock()
        guard !refreshStarted else { refreshFlag.unlock(); return }
        refreshStarted = true
        refreshFlag.unlock()
        DispatchQueue.global(qos: .utility).async {
            let host = ProcessInfo.processInfo.hostName
            let pretty = fromHostName(host, fallback: fallback)
            if pretty != fallback {
                defaults.set(pretty, forKey: cacheKey)
            }
        }
    }

    /// Prettify a host name into a display name, or return `fallback` when the host
    /// name is missing/uninformative (e.g. "localhost").
    public static func fromHostName(_ hostName: String, fallback: String) -> String {
        let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "localhost" else { return fallback }
        let base = trimmed.replacingOccurrences(of: ".local", with: "")
        guard !base.isEmpty else { return fallback }
        let pretty = base
            .split(separator: "-")
            .map(prettifyWord)
            .joined(separator: " ")
        return pretty.isEmpty ? fallback : pretty
    }

    /// Title-case a single host-name segment, preserving well-known product casing
    /// ("ipad" -> "iPad", "tv" -> "TV") that a naive capitalization would mangle.
    private static func prettifyWord(_ word: Substring) -> String {
        let s = String(word)
        switch s.lowercased() {
        case "tv": return "TV"
        case "ipad": return "iPad"
        case "iphone": return "iPhone"
        case "ipod": return "iPod"
        case "imac": return "iMac"
        case "macbook": return "MacBook"
        default:
            guard let first = s.first else { return s }
            return first.uppercased() + s.dropFirst()
        }
    }
}
