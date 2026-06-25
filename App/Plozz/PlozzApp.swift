import SwiftUI
import AppShell
import CoreModels

/// Plozz — an open-source tvOS Jellyfin client.
@main
struct PlozzApp: App {
    init() {
        #if DEBUG
        Self.redirectStandardError()
        #endif
        DLog.installCrashHandler()
        DLog.startMainPing()
        // Give artwork a real on-disk cache so backdrops, posters and logos load
        // instantly on revisit instead of being re-fetched every time (the
        // default shared URLCache is only a few MB — far too small for 4K
        // backdrops). AsyncImage and our URLSession-based loader both read
        // through URLCache.shared, so this keeps recently seen art warm the way a
        // dedicated player like Infuse does.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB in memory
            diskCapacity: 512 * 1024 * 1024,    // 512 MB on disk
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }

    #if DEBUG
    /// Mirrors the process's stderr/stdout into a file inside the app's Caches
    /// directory so crash reasons that the OS only writes to stderr — e.g.
    /// SwiftUI/AttributeGraph `precondition failure` messages emitted right
    /// before `abort()` — survive an on-device crash. The `.ips` crash report
    /// never includes that reason string, but it lands here and can be pulled
    /// afterwards with `xcrun devicectl device copy from --domain-type
    /// appDataContainer --bundle-identifier com.thatcube.Plozz`. Debug-only.
    private static func redirectStandardError() {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("plozz-stderr.log")
        // Append so successive launches accumulate; line-buffer so each line is
        // flushed on its newline (an abort can't lose the last buffered line).
        guard freopen(url.path, "a+", stderr) != nil else { return }
        setvbuf(stderr, nil, _IOLBF, 0)
        dup2(fileno(stderr), fileno(stdout))
        let marker = "\n===== Plozz launch \(ISO8601DateFormatter().string(from: Date())) =====\n"
        if let data = marker.data(using: .utf8) { FileHandle.standardError.write(data) }
    }
    #endif
}
