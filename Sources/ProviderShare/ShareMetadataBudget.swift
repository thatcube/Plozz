import Foundation

/// Chooses how much background metadata work a device should attempt at once.
///
/// The alternative — a fixed constant — cannot be right on both an Apple TV HD
/// and an M4 iPad: a number small enough to be safe on the weakest supported
/// device wastes an order of magnitude of capacity on the strongest, and a
/// number tuned for the strongest overheats the weakest. So nothing here is
/// tuned to a device; the budget is derived from what the device reports about
/// itself, and then corrected by what it actually delivers.
///
/// Three inputs, in order of authority:
///
///  1. **Thermal state.** The only signal that says "you are already hurting
///     this device". Overrides everything else.
///  2. **Low Power Mode.** An explicit instruction from the user to do less.
///  3. **Core count.** A coarse proxy for capability when nothing is wrong yet.
///
/// The caller then feeds observed slice durations back through
/// `adjusted(after:)`, which is what makes this adaptive rather than merely
/// parameterised: a device that is slower than its core count suggests (a cold
/// cache, a saturated network, a busy foreground) is discovered, not assumed.
struct ShareMetadataBudget: Equatable, Sendable {
    /// Items attempted per slice.
    var itemsPerSlice: Int
    /// Wall-clock ceiling for one slice.
    var sliceDuration: Duration
    /// Idle gap between slices, so background work never monopolises a core.
    var delayBetweenSlices: Duration

    /// Never go below this: progress must remain perceptible even on the weakest
    /// device in the worst thermal state, or a large library would appear stuck.
    static let minimumItemsPerSlice = 4
    /// Never go above this regardless of hardware — past this point the limit is
    /// the metadata provider's rate limit and the share's I/O, not the CPU, and
    /// exceeding it buys nothing while risking throttling.
    static let maximumItemsPerSlice = 48

    /// Whether the device is currently asking for restraint (thermal pressure or
    /// Low Power Mode). When true the device's budget is a hard ceiling; when
    /// false, measured headroom may raise it.
    static func isConstrained(
        processInfo: ProcessInfoReading = RealProcessInfo()
    ) -> Bool {
        switch processInfo.thermalState {
        case .serious, .critical: return true
        default: return processInfo.isLowPowerModeEnabled
        }
    }

    /// The budget a device should start from.
    static func forCurrentDevice(
        processInfo: ProcessInfoReading = RealProcessInfo()
    ) -> ShareMetadataBudget {
        switch processInfo.thermalState {
        case .critical:
            // The device is in trouble. Stay alive, do almost nothing.
            return ShareMetadataBudget(
                itemsPerSlice: minimumItemsPerSlice,
                sliceDuration: .seconds(1),
                delayBetweenSlices: .seconds(5)
            )
        case .serious:
            return ShareMetadataBudget(
                itemsPerSlice: minimumItemsPerSlice,
                sliceDuration: .seconds(1),
                delayBetweenSlices: .seconds(2)
            )
        default:
            break
        }
        if processInfo.isLowPowerModeEnabled {
            return ShareMetadataBudget(
                itemsPerSlice: minimumItemsPerSlice,
                sliceDuration: .seconds(1),
                delayBetweenSlices: .seconds(2)
            )
        }
        // Nominal/fair: scale with cores. An Apple TV HD (2 cores) lands near the
        // floor; an M-series iPad (8+) lands near the ceiling.
        let cores = max(1, processInfo.activeProcessorCount)
        let items = min(maximumItemsPerSlice, max(minimumItemsPerSlice, cores * 4))
        return ShareMetadataBudget(
            itemsPerSlice: items,
            sliceDuration: .seconds(2),
            delayBetweenSlices: .milliseconds(300)
        )
    }

    /// Correct the budget using what the last slice actually cost.
    ///
    /// `itemsPerSlice` is a request, not a promise — the real cost of an item
    /// depends on network latency and on whether a sidecar has to be read. If a
    /// slice consistently overruns its wall-clock ceiling the device is telling
    /// us the request was too large, whatever its core count implied. Shrinking
    /// on overrun and growing slowly on comfortable completion converges on the
    /// device's true capacity without ever measuring the device directly.
    func adjusted(after observed: Duration, attempted: Int) -> ShareMetadataBudget {
        guard attempted > 0 else { return self }
        var next = self
        if observed > sliceDuration {
            // Overran: halve, but never below the floor.
            next.itemsPerSlice = max(
                Self.minimumItemsPerSlice,
                itemsPerSlice / 2
            )
        } else if observed < sliceDuration / 2, attempted >= itemsPerSlice {
            // Finished a FULL slice in under half the budget: there is headroom.
            // Grow by a quarter — deliberately slower than the shrink, so a device
            // that is genuinely near its limit settles instead of oscillating.
            next.itemsPerSlice = min(
                Self.maximumItemsPerSlice,
                max(itemsPerSlice + 1, itemsPerSlice * 5 / 4)
            )
        }
        return next
    }
}

/// The `ProcessInfo` facts the budget depends on, behind a seam so the policy is
/// testable without a device in a particular thermal state.
protocol ProcessInfoReading: Sendable {
    var thermalState: ProcessInfo.ThermalState { get }
    var isLowPowerModeEnabled: Bool { get }
    var activeProcessorCount: Int { get }
}

struct RealProcessInfo: ProcessInfoReading {
    var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var activeProcessorCount: Int { ProcessInfo.processInfo.activeProcessorCount }
}
