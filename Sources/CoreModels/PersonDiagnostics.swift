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
    /// Opt-in via `PLZPERSON=1`, OR whenever a previous run left the file sink
    /// in place — see `isEnabled`.
    public static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["PLZPERSON"] == "1" { return true }
        // A latch, so tracing survives a relaunch.
        //
        // The stdout stream dies with the process, and a `--console` launch to
        // restore it terminates the app — which loses whatever the tester was
        // half-way through reproducing. Once switched on, this keeps recording
        // to a file across launches until the marker is deleted.
        return FileManager.default.fileExists(atPath: latchURL?.path ?? "")
    }()

    /// Arms the latch for the NEXT launch as soon as tracing is asked for, so a
    /// single `PLZPERSON=1` run keeps recording afterwards without another
    /// `--console` launch (which would terminate the app mid-repro).
    public static func armLatchIfTracing() {
        guard ProcessInfo.processInfo.environment["PLZPERSON"] == "1" else { return }
        startPersistentTrace()
    }

    private static var latchURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("plzperson.on")
    }

    /// Where the durable trace is written. Pull it with:
    /// `xcrun devicectl device copy from --domain-type appDataContainer
    ///  --domain-identifier com.thatcube.Plozz --source Library/Caches/plzperson.log`
    private static let fileSink = PersonDiagnosticsFileSink(enabled: isEnabled)

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
        let data = Data((stamped + "\n").utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)
        fileSink.write(data)
    }

    /// Turns the latch on, so tracing continues across relaunches.
    public static func startPersistentTrace() {
        guard let latchURL else { return }
        FileManager.default.createFile(atPath: latchURL.path, contents: nil)
    }
}

/// Appends the trace to a file in the app container so it outlives the process.
///
/// Appends rather than truncates, deliberately: a trace is usually wanted
/// *after* something went wrong, and truncating on launch throws away the run
/// that mattered the moment the app is opened again.
private final class PersonDiagnosticsFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(enabled: Bool) {
        guard enabled,
              let caches = FileManager.default
                  .urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        let url = caches.appendingPathComponent("plzperson.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    func write(_ data: Data) {
        lock.withLock { try? handle?.write(contentsOf: data) }
    }
}
