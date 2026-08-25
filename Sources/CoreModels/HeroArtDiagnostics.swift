import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Telemetry for hero artwork selection — which pictures a title actually has,
/// which one each of the two hero screens ends up drawing, and whether they are
/// the same image.
///
/// Its own channel because the question is a chain, not a value. A title's wide
/// art passes through the provider that collected it, the planner that ranked it,
/// the placement ladder on the item, an artwork router that may answer with
/// something else entirely, and finally whichever URL the image layer managed to
/// load. "Both heroes look the same" can be produced at any one of those, and
/// reasoning about the code cannot distinguish them — only a trace can.
///
/// Opt-in via `PLZHEROART=1`, so it costs nothing in a normal run.
public enum HeroArtDiagnostics {
    /// Opt-in via `PLZHEROART=1`, OR whenever a previous run left the file sink in
    /// place — see ``PersonDiagnostics`` for why the latch exists.
    ///
    /// `PLZHEROART=0` is an explicit OFF that also clears the latch, so a device
    /// left tracing can be put back to normal by one launch rather than by
    /// reinstalling the app.
    public static let isEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["PLZHEROART"] {
        case "1": return true
        case "0":
            if let latchURL { try? FileManager.default.removeItem(at: latchURL) }
            return false
        default:
            return FileManager.default.fileExists(atPath: latchURL?.path ?? "")
        }
    }()

    /// Arms the latch for the NEXT launch, so a single `PLZHEROART=1` run keeps
    /// recording without a `--console` relaunch (which would kill the app
    /// mid-repro).
    public static func armLatchIfTracing() {
        guard ProcessInfo.processInfo.environment["PLZHEROART"] == "1" else { return }
        startPersistentTrace()
    }

    private static var latchURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("plzheroart.on")
    }

    /// Where the durable trace is written. Pull it with:
    /// `xcrun devicectl device copy from --domain-type appDataContainer
    ///  --domain-identifier com.thatcube.Plozz --source Library/Caches/plzheroart.log`
    private static let fileSink = HeroArtDiagnosticsFileSink(enabled: isEnabled)

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "heroart")
    #endif

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Titles already traced for a given stage, so a SwiftUI body that re-runs on
    /// every focus change cannot bury the trace in duplicates.
    private static let seen = HeroArtDiagnosticsSeen()

    public static func emit(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        write(line())
    }

    /// Emits at most once per `stage` + `key`, for call sites that run per frame.
    ///
    /// Both the key and the line are lazy. A SwiftUI body that interpolates an item
    /// id and a URL to form its key would otherwise pay for that string on every
    /// pass, tracing or not — which is a production cost for a debugging feature,
    /// and exactly the kind of thing that has no business shipping.
    public static func emitOnce(
        stage: String,
        key: @autoclosure () -> String,
        _ line: () -> String
    ) {
        guard isEnabled, seen.insert("\(stage)|\(key())") else { return }
        write(line())
    }

    /// Stamps and hands the line to the sink. Never called unless tracing is on.
    private static func write(_ line: String) {
        let stamped = "PLZHEROART \(clock.string(from: Date())) \(line)"
        #if canImport(OSLog)
        logger.notice("\(stamped, privacy: .public)")
        #endif
        fileSink.write(Data((stamped + "\n").utf8))
    }

    /// A URL shortened to the part that distinguishes two pictures of the same
    /// title — the tail of the path plus the identifying query. A full 3840px
    /// Jellyfin/Plex URL is mostly boilerplate that makes two different images look
    /// identical at a glance, which is precisely the confusion this trace exists to
    /// settle.
    public static func brief(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let path = parts.path.split(separator: "/").suffix(3).joined(separator: "/")
        let interesting = ["tag", "index", "url", "maxWidth"]
        let query = (parts.queryItems ?? [])
            .filter { interesting.contains($0.name) }
            // Plex hands its real image path through as the `url` parameter, so
            // trimming this hard made two genuinely different Plex pictures print
            // identically — the trace disguising the very thing it was added to
            // measure.
            .map { "\($0.name)=\(($0.value ?? "").suffix(40))" }
            .joined(separator: "&")
        return query.isEmpty ? path : "\(path)?\(query)"
    }

    public static func brief(_ reference: ArtworkReference?) -> String {
        guard let reference else { return "nil" }
        switch reference {
        case .remote(let url):
            return brief(url)
        case .networkFile(let file):
            // `String(describing:)` printed the whole struct and truncated to
            // nothing useful, hiding which local file was chosen.
            return "file:\(file.catalogArtworkID.suffix(24))"
        }
    }

    /// Turns the latch on, so tracing continues across relaunches.
    public static func startPersistentTrace() {
        guard let latchURL else { return }
        FileManager.default.createFile(atPath: latchURL.path, contents: nil)
    }
}

/// Appends the trace to a file in the app container so it outlives the process.
///
/// Writes on its own serial queue. The trace is emitted from provider mapping and
/// from SwiftUI bodies on the main thread, and a synchronous `write` there is a
/// syscall per line — thousands of them during a library load, which is enough to
/// be felt as lag. Ordering still holds because the queue is serial.
private final class HeroArtDiagnosticsFileSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.plozz.app.heroart-trace", qos: .utility)
    private var handle: FileHandle?

    init(enabled: Bool) {
        guard enabled,
              let caches = FileManager.default
                  .urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        let url = caches.appendingPathComponent("plzheroart.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    func write(_ data: Data) {
        guard handle != nil else { return }
        queue.async { [weak self] in
            try? self?.handle?.write(contentsOf: data)
        }
    }
}

/// Bounded de-duplication for per-frame call sites.
private final class HeroArtDiagnosticsSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()

    /// Returns true the first time a key is offered. Clears wholesale past a cap so
    /// a long browse cannot grow this without bound; repeating a line after that is
    /// far better than leaking.
    func insert(_ key: String) -> Bool {
        lock.withLock {
            if keys.count > 2_000 { keys.removeAll(keepingCapacity: true) }
            return keys.insert(key).inserted
        }
    }
}
