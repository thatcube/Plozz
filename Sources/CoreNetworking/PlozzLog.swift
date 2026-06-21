import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Centralised, secret-safe logging.
///
/// Plozz must **never** log tokens, Quick Connect secrets, or full
/// `Authorization` headers. Use these helpers everywhere instead of `print`.
///
/// Backed by `OSLog` where available (Apple platforms) and a no-op elsewhere,
/// so non-Apple hosts (CI tooling, Linux) can still compile the logic modules.
public struct PlozzLogger: Sendable {
    #if canImport(OSLog)
    private let logger: Logger

    init(category: String) {
        self.logger = Logger(subsystem: PlozzLog.subsystem, category: category)
    }

    public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public func error(_ message: String) { logger.error("\(message, privacy: .public)") }
    #else
    init(category: String) {}
    public func debug(_ message: String) {}
    public func info(_ message: String) {}
    public func error(_ message: String) {}
    #endif
}

public enum PlozzLog {
    static let subsystem = "com.plozz.app"

    public static let networking = PlozzLogger(category: "networking")
    public static let auth = PlozzLogger(category: "auth")
    public static let discovery = PlozzLogger(category: "discovery")
    public static let playback = PlozzLogger(category: "playback")
    public static let app = PlozzLogger(category: "app")

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
