import Foundation
import CoreNetworking

/// On-device telemetry for **music play-reporting** — the start/progress/pause/
/// stop lifecycle the audio player sends to Jellyfin/Plex so listening feeds the
/// server's play counts and "Recently Played" rail.
///
/// Every line is tagged `PLZPLAY` (a deliberately unique token, easy to grep) and
/// logged under subsystem `com.plozz.app`, category `playback`. Two ways to read it:
///  - **Console.app** — select the Apple TV, filter subsystem `com.plozz.app`,
///    search `PLZPLAY`.
///  - **Live stdout mirror** — when the process is launched with `PLZPLAY_STDOUT=1`
///    in its environment, each line is ALSO written to stdout, which
///    `xcrun devicectl device process launch --console` forwards off the device.
///    `os_log` alone only reaches the unified logging system, which a remote CLI
///    driver can't read on this macOS toolchain; stdout can. Opt-in (read once at
///    startup) so normal runs and unit tests stay silent — zero cost when unset.
///
/// Secret-safe: only item ids, titles and event names are logged — never tokens,
/// PINs or auth headers. Mirrors the reusable pattern in `FanoutDiagnostics`.
enum MusicReportDiagnostics {
    /// Read once at startup. When `PLZPLAY_STDOUT=1`, lines are echoed to stdout.
    private static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["PLZPLAY_STDOUT"] == "1"

    /// Emits one telemetry line (the `PLZPLAY ` prefix is added). Fire-and-forget:
    /// never blocks, throws, or feeds back into the reporting path.
    static func emit(_ line: String) {
        PlozzLog.playback.debug("PLZPLAY \(line)")
        if mirrorsStandardOut {
            // Unbuffered write so `devicectl --console` sees each line immediately.
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZPLAY " + line + "\n").utf8))
        }
    }
}
