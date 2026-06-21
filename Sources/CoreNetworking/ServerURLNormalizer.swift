import Foundation

/// Helpers for turning messy user/discovery input into a usable base URL.
public enum ServerURLNormalizer {
    /// Normalises a user-entered host/URL into a canonical base `URL`.
    ///
    /// Rules:
    ///  * adds a scheme (`http://`) when none is present;
    ///  * defaults to port `8096` for scheme-less `http` hosts (Jellyfin default);
    ///  * strips trailing slashes;
    ///  * returns `nil` for input that can't form a valid host.
    ///
    /// Examples:
    ///  * `192.168.1.5`       → `http://192.168.1.5:8096`
    ///  * `jelly.example.com` → `http://jelly.example.com:8096`
    ///  * `https://m.tld/jf/` → `https://m.tld/jf`
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.contains("://")
        let withScheme = hadScheme ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // Apply the Jellyfin default port only when the user typed a bare host
        // over plain http with no explicit port.
        if !hadScheme, components.port == nil, components.scheme == "http" {
            components.port = 8096
        }

        // Strip trailing slash from the path for a canonical form.
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }

        return components.url
    }
}
