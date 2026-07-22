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
    private let category: String

    #if canImport(OSLog)
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: PlozzLog.subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        PlozzLog.record(.debug, category: category, message: message)
    }
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        PlozzLog.record(.info, category: category, message: message)
    }
    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        PlozzLog.record(.error, category: category, message: message)
    }
    #else
    init(category: String) { self.category = category }
    public func debug(_ message: String) { PlozzLog.record(.debug, category: category, message: message) }
    public func info(_ message: String) { PlozzLog.record(.info, category: category, message: message) }
    public func error(_ message: String) { PlozzLog.record(.error, category: category, message: message) }
    #endif
}

public enum PlozzLog {
    static let subsystem = "com.plozz.app"
    private static let mirrorsStandardOut =
        ProcessInfo.processInfo.environment["PLOZZ_LOG_STDOUT"] == "1"
    private static let standardOutLock = NSLock()

    public static let networking = PlozzLogger(category: "networking")
    public static let auth = PlozzLogger(category: "auth")
    public static let discovery = PlozzLogger(category: "discovery")
    public static let playback = PlozzLogger(category: "playback")
    public static let app = PlozzLogger(category: "app")
    public static let sync = PlozzLogger(category: "sync")

    /// Temporary startup-flow telemetry. Emits via `os_log` (category `app`) AND,
    /// when the process is launched with `PLZBOOT_STDOUT=1`, mirrors each line to
    /// stdout so `devicectl device process launch --console` can stream it live off
    /// the Apple TV (the unified log can't be streamed remotely on this toolchain).
    /// Tagged `PLZBOOT` for easy filtering.
    private static let bootMirrorsStdout: Bool =
        ProcessInfo.processInfo.environment["PLZBOOT_STDOUT"] == "1"

    public static func boot(_ message: String) {
        app.info("PLZBOOT \(message)")
        if bootMirrorsStdout {
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZBOOT " + message + "\n").utf8))
        }
    }

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

    // MARK: - Recent-log ring buffer

    /// Severity of a captured log line.
    public enum Level: String, Sendable {
        case debug, info, error
    }

    /// One captured log line. Holds exactly what was passed to `os_log` — which
    /// is already secret-safe because every call site redacts via
    /// `redact(headers:)` / `redact(url:)`. Nothing extra is stored, so the
    /// buffer inherits the same "never logs tokens" guarantee.
    public struct LogEntry: Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    /// Fixed-capacity, lock-guarded ring of the most recent log lines. Lets the
    /// app attach a short window of recent activity to a user bug report without
    /// a backend. `OSLogStore` can't read this back reliably on tvOS (current
    /// process only), so we keep our own copy. Capped so memory stays bounded.
    private final class RingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [LogEntry] = []
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            entries.reserveCapacity(capacity)
        }

        func append(_ entry: LogEntry) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }

        func snapshot() -> [LogEntry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    private static let ring = RingBuffer(capacity: 500)

    static func record(_ level: Level, category: String, message: String) {
        ring.append(LogEntry(id: UUID(), date: Date(), level: level, category: category, message: message))
        guard mirrorsStandardOut else { return }
        standardOutLock.lock()
        defer { standardOutLock.unlock() }
        try? FileHandle.standardOutput.write(
            contentsOf: Data(("PLZLOG [\(level.rawValue)] \(category): \(message)\n").utf8)
        )
    }

    /// The most recent captured log entries, oldest→newest, capped to `limit`.
    public static func recentEntries(limit: Int = 200) -> [LogEntry] {
        let all = ring.snapshot()
        guard limit < all.count else { return all }
        return Array(all.suffix(limit))
    }

    /// The recent log window rendered as plain text (one line per entry),
    /// suitable for pasting into a bug report. Already redacted at source.
    public static func recentLogText(limit: Int = 100) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return recentEntries(limit: limit)
            .map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.category): \($0.message)" }
            .joined(separator: "\n")
    }
}
