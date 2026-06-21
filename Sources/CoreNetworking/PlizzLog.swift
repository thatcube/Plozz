import Foundation
import OSLog

/// Centralised, secret-safe logging.
///
/// Plizz must **never** log tokens, Quick Connect secrets, or full
/// `Authorization` headers. Use these helpers everywhere instead of `print`.
public enum PlizzLog {
    public static let networking = Logger(subsystem: subsystem, category: "networking")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let app = Logger(subsystem: subsystem, category: "app")

    private static let subsystem = "com.plizz.app"

    /// Header names whose values must never be printed.
    static let sensitiveHeaders: Set<String> = [
        "authorization",
        "x-emby-authorization",
        "x-mediabrowser-token",
        "x-plex-token"
    ]

    /// Returns a copy of `headers` with sensitive values replaced by `<redacted>`.
    public static func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, pair in
            if sensitiveHeaders.contains(pair.key.lowercased()) {
                result[pair.key] = "<redacted>"
            } else {
                result[pair.key] = pair.value
            }
        }
    }

    /// Strips query items that commonly carry secrets (e.g. `?secret=`, `?api_key=`).
    public static func redact(url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let sensitiveQuery: Set<String> = ["secret", "api_key", "apikey", "x-plex-token", "token"]
        components.queryItems = components.queryItems?.map { item in
            sensitiveQuery.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "<redacted>")
                : item
        }
        return components.string ?? url.path
    }
}
