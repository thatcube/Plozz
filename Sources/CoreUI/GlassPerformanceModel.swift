#if canImport(SwiftUI)
import CoreModels
import Foundation
import Observation

/// The live glass budget for this device and whatever is playing right now.
///
/// Owned by the app root and observed by it, so a change to either signal
/// re-resolves `\.plozzReduceTransparency` for the whole tree at once. The
/// player writes to it; nothing reads it directly except the root.
@MainActor
@Observable
public final class GlassPerformanceModel {
    public private(set) var budget: GlassPerformanceBudget

    /// How many players currently consider their content demanding.
    ///
    /// A count rather than a flag. Playback can overlap — a new item loading
    /// while the previous one tears down — and with a flag the departing player
    /// clears a suspension the arriving one just set, restoring glass over
    /// exactly the content that asked for it to go.
    private var demandingSources = 0

    public init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        budget = .forHardware(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Suspends glass for as long as the returned token is held.
    ///
    /// Balanced by `endDemandingPlayback`, and safe to call for content that is
    /// NOT demanding — it simply does nothing, so callers need no conditional
    /// and cannot leak a suspension by forgetting one.
    public func beginDemandingPlayback() {
        demandingSources += 1
        refresh()
    }

    public func endDemandingPlayback() {
        guard demandingSources > 0 else { return }
        demandingSources -= 1
        refresh()
    }

    /// Clears every suspension. For a player tearing down on a path that cannot
    /// guarantee its balance — the alternative to a leak here is glass that
    /// never comes back until the app is relaunched.
    public func resetPlaybackDemand() {
        guard demandingSources != 0 else { return }
        demandingSources = 0
        refresh()
    }

    private func refresh() {
        budget.contentIsDemanding = demandingSources > 0
    }
}
#endif
