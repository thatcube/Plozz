import Foundation
import os

/// Single logging entry point for the local-remux module. Lines go to `os_log`
/// (Console / `log stream --predicate 'subsystem == "com.thatcube.Plozz"'`) so the
/// localhost origin's request/response trail and the C core's mux diagnostics are
/// inspectable without a separate tool. Deliberately self-contained: no CoreModels
/// file-log dependency, so the module stays a leaf the coordinator can reason about.
enum RemuxLog {
    static let log = Logger(subsystem: "com.thatcube.Plozz", category: "LocalRemux")

    /// When the process is launched with `REMUX_STDOUT=1`, every line is ALSO
    /// written to stdout with a `PLZREMUX ` prefix. `os_log` only reaches the
    /// unified logging system, which a network-paired Apple TV driver can't read
    /// on this macOS toolchain; stdout, however, is forwarded by `devicectl device
    /// process launch --console`. This lets the coordinator stream the remux-av /
    /// remux-tput markers live off the device. Opt-in (read once at startup) so
    /// normal runs and unit tests stay silent. Mirrors the PLZXFAN_STDOUT seam.
    static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["REMUX_STDOUT"] == "1"

    /// Emits one already-formatted line to stdout (prefixed `PLZREMUX `) when the
    /// mirror is enabled. No-op otherwise. Shared so other modules' remux markers
    /// (e.g. `remux-stall` from FeaturePlayback) can join the same stdout stream.
    static func mirror(_ message: String) {
        guard mirrorsStandardOut else { return }
        // Unbuffered write so `devicectl --console` sees each line immediately.
        try? FileHandle.standardOutput.write(contentsOf: Data(("PLZREMUX " + message + "\n").utf8))
    }

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        log.debug("\(text, privacy: .public)")
        mirror(text)
    }

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        log.info("\(text, privacy: .public)")
        mirror(text)
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        log.error("\(text, privacy: .public)")
        mirror(text)
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
