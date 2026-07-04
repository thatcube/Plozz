import Foundation

/// Helpers for turning messy user/discovery input into a usable base URL.
public enum ServerURLNormalizer {
    /// Normalises a user-entered host/URL into a canonical base `URL`.
    ///
    /// Rules:
    ///  * adds a scheme (`http://`) when none is present;
    ///  * defaults to `defaultPort` for scheme-less `http` hosts with no explicit
    ///    port (e.g. Jellyfin's `8096`, Overseerr/Jellyseerr's `5055`);
    ///  * strips trailing slashes;
    ///  * returns `nil` for input that can't form a valid host.
    ///
    /// Examples (`defaultPort: 8096`):
    ///  * `192.168.1.5`       → `http://192.168.1.5:8096`
    ///  * `jelly.example.com` → `http://jelly.example.com:8096`
    ///  * `https://m.tld/jf/` → `https://m.tld/jf`
    public static func normalize(_ raw: String, defaultPort: Int? = 8096) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.contains("://")
        // Self-hosted media servers overwhelmingly run plain HTTP on the local
        // network (no TLS cert for a LAN IP), so a scheme-less host defaults to
        // `http`, not `https` — matching how every server-add flow in this app
        // behaves and avoiding a silent TLS-handshake failure against a bare IP.
        let withScheme = hadScheme ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // Apply the service's default port only when the user typed a bare host
        // over plain http with no explicit port.
        if !hadScheme, components.port == nil, components.scheme == "http", let defaultPort {
            components.port = defaultPort
        }

        // Strip trailing slash from the path for a canonical form.
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }

        return components.url
    }
}
