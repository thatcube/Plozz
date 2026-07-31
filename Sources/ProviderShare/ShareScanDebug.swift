import Foundation

/// Developer-only knobs for exercising the share scanner on a real device.
///
/// Scanning is deliberately hard to provoke in normal use: a walk only spawns
/// when the catalog is queried, and two independent 600-second gates then
/// suppress it — the coordinator's spawn coalesce and the scanner's staleness
/// check. That is right for a shipping app and useless for verifying incremental
/// behaviour, where the interesting measurement is the *second* pass over a
/// settled catalog. Without these, proving a change means waiting ten minutes
/// per data point and hoping the app is foregrounded on a screen that queries.
///
/// Every value is read once from the environment and is inert unless explicitly
/// set, so a shipped build behaves exactly as it does today. Matches the
/// `PLZXMEM` / `PLZBOOT_STDOUT` convention already used for on-device
/// diagnostics.
///
/// Usage (tvOS, via devicectl):
/// ```
/// xcrun devicectl device process launch --device <id> --console \
///   --environment-variables '{"PLZBOOT_STDOUT":"1","PLZSCAN_INTERVAL":"0"}' \
///   com.thatcube.Plozz
/// ```
///
/// Registering a share ends in `ensureScanning`, so opening the interval gate is
/// enough to get a pass at launch and another whenever the catalog is read.
enum ShareScanDebug {
    /// Overrides **both** 600-second gates, in seconds. `0` means "never
    /// throttle", which is what back-to-back measurement passes need.
    static let scanInterval: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["PLZSCAN_INTERVAL"],
              let value = TimeInterval(raw), value >= 0
        else { return nil }
        return value
    }()

    /// Forces every pass deep (`1`) or shallow (`0`), instead of letting the
    /// daily cadence decide.
    ///
    /// The two differ in what they are allowed to skip, so comparing them is the
    /// whole point of a measurement run — and waiting a day for the cadence to
    /// flip is not a test.
    static let forceDeep: Bool? = {
        switch ProcessInfo.processInfo.environment["PLZSCAN_DEEP"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }()

    /// No "scan on launch" knob: registering a share already ends in
    /// `ensureScanning`, so opening the interval gate is sufficient to get a
    /// pass at launch. A second trigger would be a duplicate path that could
    /// drift from the real one — and the real one is what needs proving.

    /// Whether any knob is set, so callers can log the fact once. A run whose
    /// numbers came from an overridden interval must be identifiable as such
    /// later.
    static var isActive: Bool {
        scanInterval != nil || forceDeep != nil
    }

    static var summary: String {
        var parts: [String] = []
        if let scanInterval { parts.append("interval=\(scanInterval)s") }
        if let forceDeep { parts.append("deep=\(forceDeep)") }
        return parts.isEmpty ? "off" : parts.joined(separator: " ")
    }
}
