#if canImport(SwiftUI)
import CoreNetworking
import Foundation
import SwiftUI

/// Temporary diagnostic: measures how long the **main thread** is actually
/// blocked, so a "hiccup" can be reported as a number instead of a feeling.
///
/// Sentry already tells us a hang happened and that the main thread was inside
/// SwiftUI's layout engine — but its stack arrives truncated above our frames,
/// so it never names the screen. This fills that gap: it wakes on the main
/// actor at a fixed cadence and reports the *overshoot* whenever a tick lands
/// late, which is exactly the interval the main thread spent unable to run.
///
/// Opt-in via `PLZSTALL=1` so it costs nothing unless a diagnosis is underway.
/// Pair it with `PLZBOOT_STDOUT=1` and
/// `devicectl device process launch --console` to read the stalls live.
///
/// Deliberately timer-free: a `Task.sleep` loop on the main actor measures the
/// same thing without a RunLoop source, and a blocked main actor delays it in
/// exactly the way we want to observe.
@MainActor
public enum MainThreadStallProbe {
    /// Wake-up cadence. Short enough to catch a dropped frame or two, long
    /// enough that the probe itself is not the load being measured.
    private static let interval: Duration = .milliseconds(100)

    /// Only overshoots beyond this are worth a line. One frame at 60 Hz is
    /// ~16 ms; 150 ms is already a visible stutter rather than scheduling noise.
    private static let reportThreshold: Duration = .milliseconds(150)

    private static var running = false

    /// Whether `Self._printChanges()` probes in view bodies should run. Same
    /// opt-in switch as the stall probe, so a diagnosis session turns on both
    /// and a shipping run pays for neither.
    public static let printsChanges: Bool =
        ProcessInfo.processInfo.environment["PLZSTALL"] == "1"

    /// What the app believes is on screen, so a stall can be attributed without
    /// a symbolicated stack. Set by screens that opt in; free-form and
    /// developer-facing only.
    public static var context: String = "-"  // l10n:content — developer-facing diagnostic

    public static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["PLZSTALL"] == "1", !running else { return }
        running = true
        PlozzLog.boot("stall-probe armed (interval 100ms, report >150ms)")
        Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            var worst = Duration.zero
            while true {
                try? await Task.sleep(for: interval)
                let now = clock.now
                let overshoot = last.duration(to: now) - interval
                last = now
                guard overshoot >= reportThreshold else { continue }
                if overshoot > worst { worst = overshoot }
                PlozzLog.boot(
                    "STALL \(overshoot.milliseconds)ms (worst \(worst.milliseconds)ms) "
                        + "screen=\(context)"
                )
            }
        }
    }
}

private extension Duration {
    /// Whole milliseconds, for log lines.
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}

public extension View {
    /// Names the screen a main-thread stall should be attributed to. No-op
    /// unless the probe is armed.
    func plozzStallContext(_ name: String) -> some View {
        onAppear { MainThreadStallProbe.context = name }
    }
}
#endif
