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

    /// How many external metadata lookups may be in flight at once.
    ///
    /// External work is latency-bound, not CPU-bound: one lookup is a handful of
    /// bytes and an HTTP round trip. Resolving them one at a time makes
    /// throughput the reciprocal of the providers' latency — measured on device
    /// at roughly one item per two-second slice, which is a library that never
    /// finishes. Overlapping them converts that latency into parallelism without
    /// materially more work for the device. Kept deliberately modest so the
    /// providers see a polite request rate.
    var externalConcurrency: Int
    /// How many external lookups one slice may attempt.
    ///
    /// Deliberately NOT ``itemsPerSlice``. That number is adapted from how long
    /// this device's disk-and-share work takes, which is the right governor for
    /// the device lane and the wrong one for the network lane: a slow share would
    /// otherwise throttle internet requests it has nothing to do with. External
    /// work is bounded by ``externalConcurrency`` and by being polite to the
    /// providers, so it gets a flat allowance instead of an adapted one.
    var externalItemsPerSlice: Int
    /// Wall-clock ceiling for the external portion of a slice. Separate from
    /// ``sliceDuration``, which is a CPU-fairness window for disk and share work:
    /// applying that window to network I/O just truncates the slice after the
    /// first round trip and pads the rest of the time with idle gaps.
    var externalSliceDuration: Duration

    init(
        itemsPerSlice: Int,
        sliceDuration: Duration,
        delayBetweenSlices: Duration,
        externalConcurrency: Int = 6,
        externalItemsPerSlice: Int = 48,
        externalSliceDuration: Duration = .seconds(15)
    ) {
        self.itemsPerSlice = itemsPerSlice
        self.sliceDuration = sliceDuration
        self.delayBetweenSlices = delayBetweenSlices
        self.externalConcurrency = externalConcurrency
        self.externalItemsPerSlice = externalItemsPerSlice
        self.externalSliceDuration = externalSliceDuration
    }

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
                delayBetweenSlices: .seconds(5),
                externalConcurrency: 1,
                externalItemsPerSlice: minimumItemsPerSlice,
                externalSliceDuration: .seconds(2)
            )
        case .serious:
            return ShareMetadataBudget(
                itemsPerSlice: minimumItemsPerSlice,
                sliceDuration: .seconds(1),
                delayBetweenSlices: .seconds(2),
                externalConcurrency: 2,
                externalItemsPerSlice: minimumItemsPerSlice * 2,
                externalSliceDuration: .seconds(4)
            )
        default:
            break
        }
        if processInfo.isLowPowerModeEnabled {
            return ShareMetadataBudget(
                itemsPerSlice: minimumItemsPerSlice,
                sliceDuration: .seconds(1),
                delayBetweenSlices: .seconds(2),
                externalConcurrency: 2,
                externalItemsPerSlice: minimumItemsPerSlice * 2,
                externalSliceDuration: .seconds(4)
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
    /// Correct the budget using what the last slice's **device-bound** work cost.
    ///
    /// `itemsPerSlice` is a request, not a promise — the real cost of an item
    /// depends on whether a sidecar has to be read and how fast the share
    /// answers. If a slice consistently overruns its wall-clock ceiling the
    /// device is telling us the request was too large, whatever its core count
    /// implied. Shrinking on overrun and growing slowly on comfortable
    /// completion converges on the device's true capacity without ever
    /// measuring the device directly.
    ///
    /// **Only device-bound work may be measured this way.** An external metadata
    /// lookup is an internet round trip: its duration is the provider's latency,
    /// not this device's capacity. Feeding that back drives the budget to the
    /// floor on a perfectly healthy device — measured in the field as
    /// `items=6 device=32 constrained=false thermal=nominal`, i.e. the control
    /// loop, not the hardware, was the throttle. The caller therefore passes the
    /// local/artwork portion only, and passes `nil` when none ran.
    ///
    /// `saturated` says the measured work used the whole allowance it was given;
    /// growing on a slice that simply ran out of items would read idleness as
    /// headroom.
    func adjusted(after observed: Duration, saturated: Bool) -> ShareMetadataBudget {
        var next = self
        if observed > sliceDuration {
            // Overran: halve, but never below the floor.
            next.itemsPerSlice = max(
                Self.minimumItemsPerSlice,
                itemsPerSlice / 2
            )
        } else if observed < sliceDuration / 2, saturated {
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

/// What one slice's **device-bound** work actually cost, so the budget adapts to
/// this device instead of to the metadata providers' latency.
struct ShareMetadataCapacitySample: Sendable, Equatable {
    /// Wall-clock spent on local sidecar + artwork work (disk and share I/O).
    var elapsed: Duration
    /// Whether that work used its whole item allowance. A slice that ran out of
    /// items early is not evidence of headroom.
    var saturated: Bool
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

#if DEBUG
extension ShareMetadataBudget {
    /// A fully-specified budget for tests, so a slice's shape is stated at the
    /// call site rather than inherited from whatever the host device reports.
    static func testing(
        items: Int,
        sliceDuration: Duration,
        delayBetweenSlices: Duration = .zero,
        externalConcurrency: Int = 1,
        externalItemsPerSlice: Int? = nil,
        externalSliceDuration: Duration? = nil
    ) -> ShareMetadataBudget {
        ShareMetadataBudget(
            itemsPerSlice: items,
            sliceDuration: sliceDuration,
            delayBetweenSlices: delayBetweenSlices,
            externalConcurrency: externalConcurrency,
            externalItemsPerSlice: externalItemsPerSlice ?? items,
            externalSliceDuration: externalSliceDuration ?? sliceDuration
        )
    }
}
#endif
