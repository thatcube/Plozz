#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Always-on, low-overhead diagnostics for audio playback / AirPlay route issues.
///
/// AirPlay route drops on this device can't be observed with live-streamed device
/// logs (no wireless `log stream` for tvOS in our setup), so instead we append
/// timestamped events to a plain-text file inside the app's Documents directory.
/// After reproducing the bug on the Apple TV the file is pulled to the Mac with:
///
/// ```
/// xcrun devicectl device copy from --device "Brando TV" --user mobile \
///   --domain-type appDataContainer --domain-identifier com.thatcube.Plozz \
///   --source Library/Caches/audio-diagnostics.log --destination ./audio-diagnostics.log
/// ```
///
/// NOTE: the file lives in Caches (NOT Documents) because tvOS forbids writing to
/// `.documentDirectory` — it fails at runtime (WWDC23 §10256). `--source` is
/// relative to the app data container root.
///
/// Events are cheap (a handful per skip), so a synchronous file append per event
/// is negligible and keeps ordering exact even if the app is force-killed after a
/// route break. An in-memory ring buffer is kept too so a future on-screen overlay
/// can render it without re-reading the file.
@MainActor
public final class AudioDiagnostics {
    public static let shared = AudioDiagnostics()

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let time: Date
        public let category: String
        public let message: String
    }

    public private(set) var entries: [Entry] = []
    private let maxEntries = 300

    private let fileURL: URL?
    private let stamp: DateFormatter

    private init() {
        stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss.SSS"
        stamp.locale = Locale(identifier: "en_US_POSIX")

        let docs = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        fileURL = docs?.appendingPathComponent("audio-diagnostics.log")

        // Keep the file from growing without bound across many launches: if it's
        // already large, start fresh. Otherwise append so a break that forces a
        // relaunch still leaves the pre-crash history behind.
        if let fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 512 * 1024 {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let launch = ISO8601DateFormatter().string(from: Date())
        log("session", "════════ launch \(launch) ════════")
    }

    /// Appends one event. `category` is a short tag (e.g. "route", "skip",
    /// "player") for quick scanning; `message` is free-form detail.
    public func log(_ category: String, _ message: String) {
        let now = Date()
        let entry = Entry(time: now, category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        append(line: "\(stamp.string(from: now)) [\(category)] \(message)")
    }

    private func append(line: String) {
        guard let fileURL else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // File doesn't exist yet (first write of a launch) — create it.
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    #if !os(macOS)
    /// One-line description of the current audio output route — the single most
    /// useful signal for AirPlay problems. Shows each output's port type (e.g.
    /// `AirPlay`) and name (e.g. the HomePod's name), so the log tells us exactly
    /// what we were connected to when a transition broke.
    public func currentRouteDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        if route.outputs.isEmpty { return "<no outputs>" }
        return route.outputs
            .map { "\($0.portType.rawValue):\"\($0.portName)\"" }
            .joined(separator: " + ")
    }
    #endif
}
#endif
