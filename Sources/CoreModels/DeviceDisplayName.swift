import Foundation

/// Derives a friendly, user-recognizable device name.
///
/// `UIDevice.current.name` returns only a generic model name ("iPad", "iPhone",
/// "Apple TV") on iOS/tvOS 16+ unless the app holds the Apple-managed
/// `user-assigned-device-name` entitlement. The local host name still reflects the
/// name the owner gave the device ("Brando's iPad" → host `Brandos-iPad.local`), so we
/// prettify that back into a display name — the same trick tvOS already used, shared
/// here so iOS and tvOS produce identical results.
///
/// Note: the host name drops apostrophes and spaces, so "Brando's iPad" comes back as
/// "Brandos iPad" — close, but not character-exact. Exact names require the entitlement.
public enum DeviceDisplayName {
    /// Prettify a local host name into a display name, or return `fallback` when the
    /// host name is missing/uninformative (e.g. "localhost").
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
    /// ("ipad" → "iPad", "tv" → "TV") that a naive capitalization would mangle.
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
