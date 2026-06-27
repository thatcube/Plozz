import Foundation
import os

/// Single logging entry point for the local-remux module. Lines go to `os_log`
/// (Console / `log stream --predicate 'subsystem == "com.thatcube.Plozz"'`) so the
/// localhost origin's request/response trail and the C core's mux diagnostics are
/// inspectable without a separate tool. Deliberately self-contained: no CoreModels
/// file-log dependency, so the module stays a leaf the coordinator can reason about.
enum RemuxLog {
    static let log = Logger(subsystem: "com.thatcube.Plozz", category: "LocalRemux")

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        log.debug("\(text, privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        log.info("\(text, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        log.error("\(text, privacy: .public)")
    }

    /// Strips the query string (X-Plex-Token / api_key) so a self-authenticating
    /// source URL can be logged without leaking the secret, while still showing the
    /// host/path we chose.
    static func redact(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.lastPathComponent
        }
        let hadQuery = !(comps.queryItems?.isEmpty ?? true)
        comps.query = nil
        let base = comps.string ?? url.path
        return hadQuery ? base + "?<redacted>" : base
    }
}
