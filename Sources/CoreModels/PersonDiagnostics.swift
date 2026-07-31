import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Telemetry for person lookups — the credits ladder behind the in-player Cast
/// card and the full person page.
///
/// Its own channel rather than a line in `BrowseDiagnostics` because the
/// question it answers is a sequence: which rung produced the answer, and what
/// each one cost. A single "it was slow" line cannot say whether the time went
/// on the viewer's own server, on a second server being asked by name, or on
/// Wikipedia.
///
/// Opt-in via `PLZPERSON=1`, so it costs nothing in a normal run.
public enum PersonDiagnostics {
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZPERSON"] == "1"

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "person")
    #endif

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func emit(_ line: String) {
        guard isEnabled else { return }
        let stamped = "PLZPERSON \(clock.string(from: Date())) \(line)"
        #if canImport(OSLog)
        logger.notice("\(stamped, privacy: .public)")
        #endif
        try? FileHandle.standardOutput.write(contentsOf: Data((stamped + "\n").utf8))
    }
}
